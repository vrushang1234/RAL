"""The workflow runtime - the environment the optimizer acts on.

Spec: docs/rl-optimization.md sections 2.3, 5, 6.3, and the confidence
definition from section 22.

A run is a walker traversal over the workflow graph. Caps are enforced HERE,
before each agent invocation, and are deliberately redundant with the static
validation in `ir.jac`: a topology mutation can produce a graph that passes
every static check and still burn the budget through conditional re-entry.
"""

import from rl.ir { AgentSpec, WorkflowVersion, Entry, FlowsTo }
import from rl.trace { RunRoot, Span, TraceStore, add_span, record_run, spans_of }
import from rl.simulate {
    SimTask, AgentOutcome, model_spec, sim_task, role_kind,
    classify_outcome, support_outcome, review_outcome, worker_outcome
}


obj ExecConfig {
    has epoch: str = "e1";
    has step_cap: int = 32;
    has cost_cap_usd: float = 0.50;
    has ms_per_output_token: float = 8.0;
    has confidence_threshold: float = 0.72;
    has run_prefix: str = "run";
}


"""State carried between agents during one run.

`confidence` is computed from the trace, never self-reported by a model - see
`update_confidence`. Conditional routing depends on it, so a poorly calibrated
value would silently corrupt every topology mutation that uses one.
"""
obj RunContext {
    has task_id: str;
    has task_input: str;
    has category: str = "general";
    has difficulty: str = "medium";
    has expected_output: str = "";
    has carried: str = "";
    has quality: float = 0.0;
    has confidence: float = 1.0;
    has doc_coverage: float = 0.0;
    has tool_error: bool = False;
    has schema_ok: bool = True;
    has agents_run: int = 0;
}


"""Confidence as a deterministic function of the trace (section 22).

Combines retrieval coverage, tool-error presence, and schema completeness.
Self-reported model confidence is not calibrated well enough to gate routing
on, and every conditional-reviewer mutation depends on this number being
meaningful.
"""
def update_confidence(ctx: RunContext) -> float {
    score = 0.35 + 0.45 * ctx.doc_coverage + 0.20 * ctx.quality;
    if ctx.tool_error {
        score -= 0.30;
    }
    if not ctx.schema_ok {
        score -= 0.25;
    }
    ctx.confidence = max(min(score, 1.0), 0.0);
    return ctx.confidence;
}


"""Evaluate an edge condition against run state.

The vocabulary is deliberately tiny and typed - the optimizer may only emit
conditions from this set, so a topology mutation cannot smuggle in arbitrary
code. Empty condition means unconditional.
"""
def edge_allows(cond: str, ctx: RunContext, cfg: ExecConfig) -> bool {
    c = cond.strip();
    if c == "" {
        return True;
    }
    if c == "always" {
        return True;
    }
    if c == "never" {
        return False;
    }
    if c == "low_confidence" {
        return ctx.confidence < cfg.confidence_threshold;
    }
    if c == "doc_coverage_miss" {
        return ctx.doc_coverage < 0.5;
    }
    if c == "tool_error" {
        return ctx.tool_error;
    }
    if c == "schema_invalid" {
        return not ctx.schema_ok;
    }
    # An unrecognized condition must not silently disable a path.
    return True;
}


def known_conditions -> list[str] {
    return ["", "always", "never", "low_confidence", "doc_coverage_miss", "tool_error", "schema_invalid"];
}


"""Run one agent in the simulated environment and produce a Span."""
def agent_step(spec: AgentSpec, ctx: RunContext, cfg: ExecConfig) -> Span {
    model = model_spec(spec.model);
    task = sim_task(ctx.task_id, ctx.category, ctx.difficulty);
    kind = role_kind(spec.role);

    outcome: AgentOutcome = worker_outcome(model, task, spec.max_tokens);
    if kind == "classifier" {
        outcome = classify_outcome(model, task, spec.max_tokens);
    } elif kind == "support" {
        outcome = support_outcome(model, task, spec.tools, spec.prompt, spec.max_tokens);
    } elif kind == "reviewer" {
        outcome = review_outcome(model, ctx.quality, spec.max_tokens);
    }

    span = Span(
        agent_id=spec.agent_id,
        model=spec.model,
        output_text=f"{spec.agent_id}:{ctx.task_id}",
        prompt_version=str(len(spec.prompt)),
        tools_available=spec.tools,
        tools_invoked=outcome.tools_invoked,
        tool_influenced_output=outcome.tool_influenced,
        input_tokens=outcome.input_tokens,
        output_tokens=outcome.output_tokens,
        latency_ms=outcome.output_tokens * cfg.ms_per_output_token,
        cost_usd=outcome.cost_usd
    );

    # A reviewer that changed nothing is the signal section 10 looks for.
    # `measures_edits` is what stops that signal being read as "this agent is
    # inert" for agents whose edits are never measured in the first place.
    if kind == "reviewer" {
        span.measures_edits = True;
        span.edited_upstream = outcome.quality > ctx.quality + 1e-9;
    }

    ctx.quality = outcome.quality;
    ctx.schema_ok = ctx.schema_ok and outcome.schema_ok;
    ctx.tool_error = ctx.tool_error or outcome.tool_error;
    if outcome.doc_coverage > ctx.doc_coverage {
        ctx.doc_coverage = outcome.doc_coverage;
    }
    ctx.agents_run += 1;
    update_confidence(ctx);
    return span;
}


walker ExecuteWorkflow {
    has ctx: RunContext;
    has cfg: ExecConfig;
    has run: RunRoot;
    has steps: int = 0;
    has reports: list[RunRoot] = [];

    can start with WorkflowVersion entry {
        visit [here ->:Entry:->];
    }

    can step with AgentSpec entry {
        # Caps are checked BEFORE invocation, so a run that trips one costs
        # nothing extra and is marked failed rather than scored on a
        # truncated trace.
        if self.steps >= self.cfg.step_cap {
            self.run.ok = False;
            self.run.stop_reason = "step_cap";
            disengage;
        }
        if self.run.total_cost_usd >= self.cfg.cost_cap_usd {
            self.run.ok = False;
            self.run.stop_reason = "cost_cap";
            disengage;
        }

        self.steps += 1;
        span = agent_step(here, self.ctx, self.cfg);
        add_span(self.run, span, self.steps);
        self.run.output_text = span.output_text;

        # Conditions are read from the edge's own fields and matched to targets
        # by `to_agent`, never by positional pairing against the node list.
        conds: dict[str, str] = {};
        for e in [edge here ->:FlowsTo:->] {
            conds[e.to_agent] = e.condition;
        }
        for b in [here ->:FlowsTo:->] {
            cond: str = conds[b.agent_id] if b.agent_id in conds else "";
            if edge_allows(cond, self.ctx, self.cfg) {
                visit b;
            }
        }
    }

    can finish with WorkflowVersion exit {
        self.run.schema_ok = self.ctx.schema_ok;
        self.run.final_quality = self.ctx.quality;
        self.run.critical_path_ms = 0.0;
        for s in spans_of(self.run) {
            self.run.critical_path_ms += s.output_tokens * self.cfg.ms_per_output_token;
        }
        # Deliberately no `report` here: `report` also writes the value to
        # stdout, which would flood any run of more than a few tasks. `execute`
        # returns the RunRoot directly instead.
    }
}


"""Execute one workflow against one task and return the completed run."""
def execute(
    wf: WorkflowVersion,
    store: TraceStore,
    ctx: RunContext,
    cfg: ExecConfig
) -> RunRoot {
    run = RunRoot(
        run_id=f"{cfg.run_prefix}-{wf.config_hash}-{ctx.task_id}",
        config_hash=wf.config_hash,
        task_id=ctx.task_id
    );
    record_run(store, run);
    _ = wf spawn ExecuteWorkflow(ctx=ctx, cfg=cfg, run=run);
    return run;
}
