"""Candidate mutation proposal.

Spec: docs/rl-optimization.md section 12.

Two sources. Rule-based proposals handle everything the trace statistics make
obvious - an unused tool, an oversized model on a trivially-scoped agent, a
reviewer that never edits, a token budget far above observed output. These need
no model call and are targeted by `credit.jac`.

Semantic proposals use a model, but only for the thing a model is actually
better at: rewriting an instruction.

The schema gate below is small and load-bearing. A prompt mutation can break an
agent's output format while leaving its reasoning intact; if that reaches the
scorer it reads as a large quality regression, and that regression is then
attributed to the PROMPT family, corrupting the bandit with a signal that has
nothing to do with prompt quality.
"""

import from rl.ir { WorkflowVersion, AgentSpec, Constraints, workflow_agents, agent_by_id }
import from rl.mutate { Mutation, MutationFamily }
import from rl.credit {
    AgentStats, ToolStats, TargetScore,
    wasteful_tools, oversized_budgets, idle_reviewers, stats_for
}
import from rl.stats { TaskScore }


def propose_prompt_edit(role: str, current_prompt: str, failure_summary: str) -> str by llm(temperature=0.7);

sem propose_prompt_edit = "Rewrite one section of an agent's instructions to fix the described failure. Change as little as possible and preserve the required output format verbatim.";
sem propose_prompt_edit.role = "The agent's role in the workflow.";
sem propose_prompt_edit.current_prompt = "The agent's current instructions.";
sem propose_prompt_edit.failure_summary = "What went wrong, summarized from execution traces.";


"""Reject a candidate whose output format broke, BEFORE it is scored.

Returning False means the candidate is discarded outright and produces no
bandit reward at all - not a bad reward. That distinction is the whole point.
"""
def schema_gate(scores: list[TaskScore]) -> bool {
    for s in scores {
        if not s.schema_ok {
            return False;
        }
    }
    return True;
}


"""Approved models are ordered cheapest-first, so 'cheaper' is 'earlier'."""
def cheaper_model(current: str, approved: list[str]) -> str {
    if not (current in approved) {
        return "";
    }
    idx = approved.index(current);
    if idx <= 0 {
        return "";
    }
    return approved[idx - 1];
}


def target_ids(targets: list[TargetScore], limit: int) -> list[str] {
    return [t.agent_id for t in targets[:limit]];
}


"""Runtime proposals: token budgets and retries. Cheapest family to evaluate."""
def propose_runtime(
    wf: WorkflowVersion,
    stats: list[AgentStats],
    targets: list[TargetScore]
) -> list[Mutation] {
    out: list[Mutation] = [];

    for agent_id in oversized_budgets(wf, stats, 2.0) {
        st = stats_for(stats, agent_id);
        if st is not None {
            tightened = max(int(st.max_output_tokens * 1.5), 64);
            out.append(Mutation(
                family=MutationFamily.RUNTIME,
                kind="set_max_tokens",
                target=agent_id,
                int_value=tightened,
                rationale=f"observed output never exceeded {st.max_output_tokens} tokens"
            ));
        }
    }

    for agent_id in target_ids(targets, 2) {
        st = stats_for(stats, agent_id);
        if st is not None and st.failures > 0 {
            out.append(Mutation(
                family=MutationFamily.RUNTIME,
                kind="set_retries",
                target=agent_id,
                int_value=1,
                rationale=f"{st.failures} recoverable failures observed"
            ));
        }
    }

    return out;
}


"""Model proposals: swap an agent onto the next cheaper approved model."""
def propose_model(
    wf: WorkflowVersion,
    c: Constraints,
    targets: list[TargetScore]
) -> list[Mutation] {
    out: list[Mutation] = [];
    for agent_id in target_ids(targets, 3) {
        a = agent_by_id(wf, agent_id);
        if a is not None {
            downgrade = cheaper_model(a.model, c.approved_models);
            if downgrade != "" {
                out.append(Mutation(
                    family=MutationFamily.MODEL,
                    kind="set_model",
                    target=agent_id,
                    str_value=downgrade,
                    rationale=f"[{agent_id}] carries a large share of cost; test whether [{downgrade}] suffices"
                ));
            }
        }
    }
    return out;
}


"""Tool proposals: remove tools that are called often and rarely matter."""
def propose_tool(tools: list[ToolStats]) -> list[Mutation] {
    out: list[Mutation] = [];
    for t in wasteful_tools(tools, 2, 0.25) {
        out.append(Mutation(
            family=MutationFamily.TOOL,
            kind="remove_tool",
            target=t.agent_id,
            str_value=t.tool_name,
            rationale=f"[{t.tool_name}] invoked {t.invoke_rate:.0%} of the time, influenced the answer {t.useful_rate:.0%}"
        ));
    }
    return out;
}


"""Prompt proposals.

The docs-first instruction is offered as a rule because the trace makes the
problem unambiguous; anything subtler goes to the model.
"""
def propose_prompt(
    wf: WorkflowVersion,
    tools: list[ToolStats],
    use_llm: bool
) -> list[Mutation] {
    out: list[Mutation] = [];

    for t in tools {
        if t.tool_name == "web_search" and t.invoke_rate > 0.5 and t.useful_rate < 0.3 {
            a = agent_by_id(wf, t.agent_id);
            if a is not None and a.mutable_prompt and "documentation before" not in a.prompt.lower() {
                out.append(Mutation(
                    family=MutationFamily.PROMPT,
                    kind="set_prompt",
                    target=t.agent_id,
                    str_value=a.prompt + " Search internal documentation before using external web search.",
                    rationale="web search runs before documentation and rarely changes the answer"
                ));
            }
        }
    }

    if use_llm {
        for a in workflow_agents(wf) {
            if a.mutable_prompt {
                revised = propose_prompt_edit(
                    a.role,
                    a.prompt,
                    "Outputs are inconsistent on harder tasks."
                );
                if revised != "" and revised != a.prompt {
                    out.append(Mutation(
                        family=MutationFamily.PROMPT,
                        kind="set_prompt",
                        target=a.agent_id,
                        str_value=revised,
                        rationale="model-proposed instruction revision"
                    ));
                }
            }
        }
    }

    return out;
}


"""Context proposals: forward summaries instead of full traces."""
def propose_context(wf: WorkflowVersion, targets: list[TargetScore]) -> list[Mutation] {
    out: list[Mutation] = [];
    for agent_id in target_ids(targets, 2) {
        a = agent_by_id(wf, agent_id);
        if a is not None and a.context_mode == "full" {
            out.append(Mutation(
                family=MutationFamily.CONTEXT,
                kind="set_context_mode",
                target=agent_id,
                str_value="summary",
                rationale="forward a summary rather than the full upstream trace"
            ));
        }
    }
    return out;
}


"""Topology proposals.

Note what is NOT proposed here: a bare `remove_agent` on a reviewer. Section 22
shows that removal scores negative while conditionalization scores positive, so
the useful move is `bypass_agent`, which keeps the node and gates its inbound
edges. Removal is reserved for agents that never influence anything.
"""
def propose_topology(
    wf: WorkflowVersion,
    stats: list[AgentStats]
) -> list[Mutation] {
    out: list[Mutation] = [];

    for agent_id in idle_reviewers(stats, 0.10) {
        a = agent_by_id(wf, agent_id);
        if a is not None and not a.required {
            st = stats_for(stats, agent_id);
            rate = st.edit_rate if st is not None else 0.0;
            out.append(Mutation(
                family=MutationFamily.TOPOLOGY,
                kind="bypass_agent",
                target=agent_id,
                str_value="low_confidence",
                rationale=f"[{agent_id}] modified only {rate:.0%} of outputs; invoke it only when confidence is low"
            ));
        }
    }

    for s in stats {
        a = agent_by_id(wf, s.agent_id);
        if a is not None and a.removable and not a.required {
            # `edit_measured > 0` is essential. Without it, every agent whose
            # edits are simply not instrumented reads as "never changes the
            # output", and the proposer deletes the agent doing the real work.
            if s.edit_measured > 0 and s.edit_rate == 0.0 and s.cost_share > 0.15 {
                out.append(Mutation(
                    family=MutationFamily.TOPOLOGY,
                    kind="remove_agent",
                    target=s.agent_id,
                    rationale=f"[{s.agent_id}] consumes {s.cost_share:.0%} of cost and never changes the output"
                ));
            }
        }
    }

    return out;
}


"""Generate candidates for one family, targeted by trace evidence (section 10)."""
def propose(
    wf: WorkflowVersion,
    family_key: str,
    c: Constraints,
    stats: list[AgentStats],
    tools: list[ToolStats],
    targets: list[TargetScore],
    use_llm: bool
) -> list[Mutation] {
    if family_key == "runtime" {
        return propose_runtime(wf, stats, targets);
    }
    if family_key == "model" {
        return propose_model(wf, c, targets);
    }
    if family_key == "tool" {
        return propose_tool(tools);
    }
    if family_key == "prompt" {
        return propose_prompt(wf, tools, use_llm);
    }
    if family_key == "context" {
        return propose_context(wf, targets);
    }
    if family_key == "topology" {
        return propose_topology(wf, stats);
    }
    return [];
}
