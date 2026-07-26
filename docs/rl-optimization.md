# Workflow Optimization: Design Specification

How the platform improves a user-authored multi-agent workflow by controlled experimentation,
without touching the weights of any underlying language model.

This document is written against Jac. Archetype and walker snippets are the intended
implementation shape, not pseudocode; all of them type-check.

---

## 1. Formulation

A workflow configuration is a point in a discrete configuration space. Training is a **search
over that space**, guided by measured task performance.

It is worth being precise about what kind of search, because the wrong framing leads to
building machinery that will not pay for itself:

> The optimizer is **hill-climbing with an archive, using bandit-selected mutation operators.**
> It is not a Markov decision process, and nothing here learns a state-conditioned policy.

There is no temporal credit assignment across optimization steps, no bootstrapping, and no
value function. Each candidate is evaluated independently against its parent, then accepted or
rejected. Consequently the implementation needs **no** replay buffer, no policy-gradient
estimator, and no value network. What it does need — and what most of this document is about —
is a reward signal strong enough to distinguish a real improvement from noise.

The RL vocabulary remains a useful description of the parts:

| Concept | In this system |
|---|---|
| Policy | The workflow configuration: agents, edges, prompts, tools, models, context rules, runtime params |
| Environment | The workflow runtime plus every external system its tools touch |
| Action | One typed mutation applied to the configuration |
| Observation | The execution trace |
| Reward | Change in scored task performance relative to the parent configuration |

### 1.1 The action space

The action space factors into three levels, and they are not the same size:

```
action  =  family  ×  target  ×  parameters
           (6)        (n_agents + n_edges)   (unbounded for prompts)
```

Six families against a five-agent workflow already gives ~30 family-target pairs before
parameters. **Most of the search difficulty is in target selection, not family selection.**
Section 13 selects families with a bandit; Section 10 selects targets from trace evidence.
Section 10 is the one doing the heavier lifting, and it is cheap because the traces are
already being collected.

---

## 2. Workflow IR and versioning

The workflow is a graph, and Jac stores graphs natively — so the IR *is* the graph, and
version lineage is edges rather than a side table.

```jac
node WorkflowVersion {
    has config_hash: str;
    has created_at: str;
    has label: str = "";
    has accepted: bool = False;
}

node AgentSpec {
    has agent_id: str;
    has role: str;
    has model: str;
    has prompt: str;
    has tools: list[str] = [];
    has max_tokens: int = 1024;
    has temperature: float = 0.0;
    has retries: int = 0;
    has mutable_prompt: bool = True;
    has removable: bool = True;
    has required: bool = False;
}

edge Entry: WorkflowVersion --> AgentSpec {
    has note: str = "";
}

edge FlowsTo: AgentSpec --> AgentSpec {
    has condition: str = "";
}
```

Edge endpoint types (`edge FlowsTo: AgentSpec --> AgentSpec`) are declared rather than left
bare so that every traversal infers `AgentSpec` without a per-read filter.

### 2.1 Versions are immutable and content-addressed

`config_hash` is a hash over the canonical serialization of the whole configuration. A
mutation never edits a `WorkflowVersion` in place — it creates a new one and links it:

```jac
edge DerivedFrom: WorkflowVersion --> WorkflowVersion {
    has mutation_kind: str;
    has target: str;
    has train_delta: float = 0.0;
    has train_se: float = 0.0;
    has val_delta: float = 0.0;
    has rationale: str = "";
}
```

This single decision pays for itself three times: it is the cache key (§16), it is the lineage
DAG that Section 20's explainability report reads directly, and it makes rollback a traversal
rather than a restore.

### 2.2 Static validation

Before any candidate executes:

- every edge references a live node;
- exactly one entry point, at least one terminal node;
- required inputs are satisfiable from the entry payload;
- every assigned tool is in the approved set (§19);
- retry counts are finite and bounded;
- cycles are absent, or explicitly marked and bounded.

### 2.3 Runtime caps are separate, and mandatory

Static validation is not sufficient. A topology mutation can produce a graph that passes every
static check and still burns the budget through conditional re-entry. Every execution
therefore carries hard caps enforced by the runtime, not the validator:

- max steps (node entries) per run;
- max wall-clock per run;
- max spend per run.

Any cap being hit ends the run and marks it failed — the candidate is not silently scored on a
truncated trace.

---

## 3. Training data

Three disjoint splits, from a dataset that should target **≥150 tasks** where the domain
allows it:

| Split | Size guide | Use |
|---|---|---|
| Train | ~50% | Scoring candidates within a round |
| Validation | ~30% | Gating promotion; rotated (§15) |
| Test | ~20% | Touched exactly once, at the end |

Two properties matter beyond the split:

**Stratify** by task type and difficulty. Section 16 eliminates candidates using a short prefix
of the batch; if that prefix is all easy classification tasks, the elimination is meaningless.

**Fix the task ordering** once, at dataset creation, and store it. Every prefix used by
successive halving is then the same prefix for every candidate in every round, and prefix-level
results stay comparable and cacheable across rounds.

Each example carries an input, plus whichever of these apply: expected output, expected
intermediate values, a grading rubric, constraints, and required or prohibited behaviors.

---

## 4. Baseline evaluation

The original workflow is evaluated on train and validation before any mutation is proposed.

The critical requirement — and the thing the rest of the design depends on — is that the
baseline retains **per-task scores, not aggregates**:

```jac
obj TaskScore {
    has task_id: str;
    has quality: float;
    has cost_usd: float;
    has latency_ms: int;
    has failed: bool = False;
    has schema_ok: bool = True;
}
```

Aggregating first and diffing later discards the pairing, and the pairing is worth roughly a
2× reduction in the noise on every reward the optimizer will ever compute (§9). Store the
vector; aggregate only for display.

Baseline reporting should carry confidence intervals from the outset, so that later
comparisons are read against the right scale.

---

## 5. Execution and trace collection

A run is a walker traversal over the workflow graph. Trace spans are persisted as nodes hung
off a run root, which makes the whole execution history queryable with ordinary graph reads.

```jac
node RunRoot {
    has run_id: str;
    has config_hash: str;
    has task_id: str;
    has started_at: str;
}

node Span {
    has agent_id: str;
    has model: str;
    has output_text: str;
    has tools_available: list[str] = [];
    has tools_invoked: list[str] = [];
    has input_tokens: int = 0;
    has output_tokens: int = 0;
    has latency_ms: int = 0;
    has cost_usd: float = 0.0;
    has retry_count: int = 0;
    has error: str = "";
}

edge Recorded: RunRoot --> Span {
    has seq: int = 0;
}

walker ExecuteWorkflow {
    has task_id: str;
    has run: RunRoot;
    has step_cap: int = 32;
    has cost_cap_usd: float = 0.50;
    has steps: int = 0;
    has spent_usd: float = 0.0;
    has reports: list[RunRoot] = [];

    can start with WorkflowVersion entry {
        visit [here ->:Entry:->];
    }

    can run_agent with AgentSpec entry {
        if self.steps >= self.step_cap or self.spent_usd >= self.cost_cap_usd {
            disengage;
        }
        self.steps += 1;
        span = invoke_agent(here, self.task_id);
        self.spent_usd += span.cost_usd;
        self.run +>:Recorded(seq=self.steps):+> span;
        visit [here ->:FlowsTo:->];
    }

    can finish with WorkflowVersion exit {
        report self.run;
    }
}
```

The caps from §2.3 are enforced in `run_agent`, before the agent is invoked. `finish` is an
exit ability, so it fires after the full traversal completes — one report per run rather than
a scatter of per-node reports.

---

## 6. Determinism and variance control

Every source of run-to-run variance lands directly in the reward and reduces the number of
real improvements the optimizer can detect within its budget. Three controls, in descending
order of value:

### 6.1 Tool record and replay

External tools are the largest uncontrolled variance source. A web search returns different
results hour to hour; that difference is indistinguishable from a mutation effect.

Record every tool call and replay it during candidate evaluation:

```jac
node ToolCache {
    has cache_key: str;
    has tool_name: str;
    has result_json: str;
    has recorded_at: str;
}

def tool_cache_key(tool_name: str, normalized_args: str, dataset_epoch: str) -> str {
    return f"{tool_name}|{normalized_args}|{dataset_epoch}";
}
```

A cache miss — which is exactly what happens when a mutation changes *which* tool is called or
with what arguments — falls through to a live call and records the result. This one mechanism
cuts cost, cuts latency, and cuts variance simultaneously, which is why it belongs in the first
implementable version rather than in an optimization pass later.

`dataset_epoch` exists so the whole recorded environment can be deliberately refreshed without
silently mixing observations from different points in time.

### 6.2 Sampling control

Temperature 0 and pinned seeds for all evaluation runs. Where an agent's behavior genuinely
depends on sampling, evaluate it at n>1 and average — but treat that as an expensive exception,
not the default.

### 6.3 Latency is measured, not optimized directly

Wall-clock latency is dominated by provider queueing at these batch sizes. Record it for
reporting, but score latency using a **critical-path token estimate** — the longest chain of
dependent agent calls, weighted by output tokens. That quantity is deterministic given the
configuration and responds correctly to the mutations that actually matter for latency
(parallelization, model swaps, prompt shortening, conditional skips).

---

## 7. Evaluators

### 7.1 Deterministic first

Whenever the task admits it: exact match, classification accuracy, JSON-schema validation, unit
tests, database-state assertions, numeric tolerance. These are free of judge drift and free of
gaming. Push as much of the dataset into this category as the domain allows.

### 7.2 Rubric scoring

```jac
obj RubricScore {
    has correctness: int;
    has completeness: int;
    has actionability: int;
    has grounding: int;
    has formatting: int;
    has rationale: str = "";
}

sem RubricScore.correctness   = "0-5. Factual accuracy measured only against the supplied expected facts.";
sem RubricScore.completeness  = "0-5. Whether every part of the task was addressed.";
sem RubricScore.actionability = "0-5. Whether a reader could act on this without further clarification.";
sem RubricScore.grounding     = "0-5. 5 means no claim beyond the supplied evidence; 0 means substantial invention.";
sem RubricScore.formatting    = "0-5. Conformance to the requested output shape.";
sem RubricScore.rationale     = "One sentence naming the single biggest deduction.";

def judge_output(task: str, output: str, expected_facts: str, rubric: str) -> RubricScore by llm(temperature=0.0);

sem judge_output = "Score one candidate output against the rubric. You are not told which system produced it; do not speculate about that.";
sem judge_output.task = "The original task given to the system under evaluation.";
sem judge_output.output = "The candidate output to score.";
sem judge_output.expected_facts = "Ground-truth facts. Treat anything absent here as unverified.";
sem judge_output.rubric = "The scoring rubric, one criterion per line.";
```

### 7.3 Judge hardening

**A judge-based reward is a reward-hacking surface, and this optimizer mutates prompts — which
is precisely the lever that games a judge.** Verbosity, confident phrasing, and hedging removal
all raise LLM judge scores without raising quality. Four defenses, all cheap:

1. **The judge is blind.** It never sees the workflow configuration, the mutation, or whether
   the output came from the incumbent or the candidate. The signature above enforces this by
   construction — there is no parameter through which that could leak.
2. **Position swap is mandatory** on pairwise comparisons. Position bias in LLM judges is
   large. Run both orders and treat disagreement as a tie.
3. **Calibration set.** Hold ~10 human-labeled examples out of the rubric path entirely and
   re-check judge–human agreement periodically. If agreement drifts, every reward computed
   since the last check is suspect.
4. **Pin the judge.** Model, prompt, and rubric version all enter the cache key (§16). A judge
   change invalidates cached scores rather than silently mixing scales.

```jac
enum Winner { LEFT, RIGHT, TIE }

def compare_outputs(task: str, left: str, right: str, expected_facts: str) -> Winner by llm(temperature=0.0);

sem compare_outputs = "Decide which of two outputs better answers the task. Judge content only; ignore length and confidence of tone.";
sem compare_outputs.task = "The original task.";
sem compare_outputs.left = "First candidate output.";
sem compare_outputs.right = "Second candidate output.";
sem compare_outputs.expected_facts = "Ground-truth facts available for the task.";
```

### 7.4 Human feedback

Optional per-execution labels (successful / partially successful / incorrect / unsafe / too
expensive / too slow), folded in as additional reward terms. Most valuable as calibration data
for §7.3 rather than as a primary signal, since it cannot be collected at the volume the search
loop consumes.

---

## 8. Reward and scoring

### 8.1 Normalization is baseline-relative

The original weighted form mixed a [0,1] quality score with dollars and seconds, which makes
the weights uninterpretable. Normalize every operational term against the **baseline** value:

```jac
def normalized_score(
    quality: float,
    cost_usd: float,
    latency_ms: int,
    failure_rate: float,
    base_cost: float,
    base_latency: float
) -> float {
    cost_ratio = cost_usd / base_cost if base_cost > 0.0 else 1.0;
    latency_ratio = latency_ms / base_latency if base_latency > 0.0 else 1.0;
    return 0.70 * quality - 0.05 * cost_ratio - 0.03 * latency_ratio - 0.15 * failure_rate;
}
```

Now the weights read directly: at these values, a 1-point quality gain is worth a 14× cost
ratio increase, and users can reason about the trade they are authorizing.

### 8.2 Prefer constraints over scalarization

For most real objectives the user does not want a weighted sum — they want

> maximize quality, subject to cost ≤ X and p95 latency ≤ Y.

The constrained form is both closer to intent and immune to the pathology where a large cost
saving purchases a quality loss the user would never have approved. Offer the scalarized form
for the "balanced" objective, and constraints for everything else.

Presets: **max quality** (loose constraints), **min cost** (quality floor binding, minimize
cost), **min latency** (quality floor binding, minimize critical-path estimate), **balanced**
(scalarized), **custom** (user-supplied weights and constraints).

### 8.3 The quality floor, and its discontinuity

A hard floor is correct and necessary:

```
quality < quality_floor  =>  reject, regardless of every other term
```

Be aware of what it creates: a candidate at `floor + ε` with modestly lower cost dominates a
candidate at `floor − ε` with dramatically lower cost, discontinuously. That is usually the
desired safety behavior, but it means the floor is a **deliberate product decision**, not a
default to be filled in arbitrarily. Surface it in the UI as such.

---

## 9. Paired evaluation and the significance gate

**This is the central correction to the original design, and the thing most likely to decide
whether the loop works at all.**

Computing reward as the difference of two aggregated batch means is dominated by noise at any
batch size the budget permits.

### 9.1 The arithmetic

Per-task quality scores in this setting typically have σ ≈ 0.3. For a difference of independent
batch means, the standard error is `σ·√(2/n)`:

| n | Unpaired SE | Paired SE (ρ = 0.8) |
|---|---|---|
| 5 | 0.190 | 0.085 |
| 20 | 0.095 | 0.042 |
| 40 | 0.067 | 0.030 |

A candidate reported at `reward: +0.09` on a 5-task batch is **half a standard error** — a coin
flip. Accepting on `reward > 0` accepts a true-null mutation about 50% of the time.

### 9.2 Diff per task, then aggregate

Because every candidate is evaluated on the *same* tasks, the comparison is naturally paired.
Task difficulty — the dominant variance component — cancels:

```jac
obj PairedResult {
    has n: int;
    has mean_delta: float;
    has se: float;
}

def paired_delta(base: list[TaskScore], cand: list[TaskScore]) -> PairedResult {
    baseline: dict[str, float] = {};
    for s in base {
        baseline[s.task_id] = s.quality;
    }

    deltas: list[float] = [];
    for s in cand {
        if s.task_id in baseline {
            deltas.append(s.quality - baseline[s.task_id]);
        }
    }

    n = len(deltas);
    if n < 2 {
        return PairedResult(n=n, mean_delta=0.0, se=0.0);
    }

    mean = sum(deltas) / n;
    variance = sum([(d - mean) ** 2 for d in deltas]) / (n - 1);
    return PairedResult(n=n, mean_delta=mean, se=math.sqrt(variance / n));
}
```

This costs nothing extra — the same runs, the same judge calls, a different order of
operations. It is purely a consequence of having retained per-task scores in §4.

### 9.3 The gate

Acceptance is gated on effect size relative to its own standard error, plus an absolute floor
so that statistically-detectable-but-meaningless changes do not accumulate:

```jac
def passes_gate(r: PairedResult, k: float, floor: float) -> bool {
    if r.n < 2 {
        return False;
    }
    if r.mean_delta < floor {
        return False;
    }
    return r.mean_delta > k * r.se;
}
```

Defaults: `k = 1.5`, `floor = 0.02`. At n = 20 paired, `k·SE ≈ 0.063` — so the loop can detect
roughly a 6-quality-point improvement and no better. **That is the honest resolution of the
instrument**, and it should be stated in the UI. A user expecting the optimizer to find 1%
improvements on 20 tasks needs to know it cannot.

The way to buy resolution is more tasks per comparison, and the way to afford those is §6.1 and
§16 — not a looser gate.

---

## 10. Credit assignment and mutation targeting

Traces already localize failure. Using them to pick *targets* is the highest-value use of the
data being collected, and it addresses the largest factor in the action space (§1.1).

```jac
obj AgentStats {
    has agent_id: str;
    has invocations: int = 0;
    has failures: int = 0;
    has cost_share: float = 0.0;
    has edit_rate: float = 0.0;
    has tool_useful_rate: float = 0.0;
}

def rank_targets(stats: list[AgentStats]) -> list[str] {
    scored = [(s.cost_share + s.failures / max(s.invocations, 1), s.agent_id) for s in stats];
    scored.sort(reverse=True);
    return [aid for (_w, aid) in scored];
}
```

Signals that come free from the trace store:

- **Tool utility**: invocation rate vs. rate at which the tool's result appears in the final
  output. A tool called in 38% of runs that changes the answer in 4% is a removal candidate.
- **Reviewer edit rate**: a reviewer that modifies 4% of outputs is a conditionalization
  candidate, not a removal candidate — §22 shows why the distinction matters.
- **Cost share**: an agent consuming 19% of spend for a task a smaller model handles is a
  model-swap candidate.
- **Error localization**: the judge's `rationale` field, aggregated, points at the agent whose
  span introduced the defect.

Per-agent reward attribution and counterfactual ablation are the more rigorous versions of this
and are deliberately out of scope for the first implementation — the heuristics above are
sufficient to bias targeting, which is all they are being asked to do.

---

## 11. Mutation catalog

Typed mutations, not free-form rewriting by a model. Each mutation declares its target,
parameters, preconditions, validation rules, and a human-readable rationale.

```jac
enum MutationFamily { PROMPT, TOOL, MODEL, RUNTIME, CONTEXT, TOPOLOGY }

obj Mutation {
    has family: MutationFamily;
    has kind: str;
    has target: str;
    has rationale: str = "";
    has before: str = "";
    has after: str = "";
}
```

| Family | Representative kinds |
|---|---|
| `RUNTIME` | change max_tokens, temperature, retry count, timeout, reviewer threshold |
| `MODEL` | swap model for one agent; add a fallback model |
| `TOOL` | add / remove / move a tool; edit a tool description or use-condition |
| `PROMPT` | rewrite one prompt section (role, procedure, constraints, output format, verification) |
| `CONTEXT` | change what is forwarded between agents; summarize vs. full trace; filter tool results |
| `TOPOLOGY` | add / remove / merge / bypass an agent; add a conditional branch, parallel path, fallback route, or aggregation rule |

Preconditions enforce §19: a mutation targeting a node with `mutable_prompt = False` is never
generated, and one targeting `removable = False` cannot be a removal.

---

## 12. Proposal generation

Rule-based proposals handle the cases the trace statistics make obvious — unused tool, oversized
model on a trivially-scoped agent, reviewer that never edits, token budget far above observed
output length, retries on non-retryable errors.

Semantic proposals use a model, targeted by §10:

```jac
def propose_prompt_edit(role: str, current_prompt: str, failure_summary: str) -> str by llm(temperature=0.7);

sem propose_prompt_edit = "Rewrite one section of an agent's instructions to fix the described failure. Change as little as possible and preserve the required output format verbatim.";
sem propose_prompt_edit.role = "The agent's role in the workflow.";
sem propose_prompt_edit.current_prompt = "The agent's current instructions.";
sem propose_prompt_edit.failure_summary = "What went wrong, summarized from execution traces.";
```

### 12.1 The schema gate

A prompt mutation can break the agent's output format while leaving its reasoning intact. If
that reaches the scorer, it registers as a large quality regression — and that regression is
then attributed to the `PROMPT` family, corrupting the bandit statistics in §13 with a signal
that has nothing to do with prompt quality.

Gate on format *before* scoring, and reject rather than score:

```jac
def schema_gate(scores: list[TaskScore]) -> bool {
    for s in scores {
        if not s.schema_ok {
            return False;
        }
    }
    return True;
}
```

A candidate failing the gate is discarded and **does not produce a bandit reward at all**.

---

## 13. Mutation family selection

A bandit over the six families, with honest expectations:

> Across a realistic run the bandit receives roughly 20–50 pulls spread over 6 arms, against a
> high-variance reward. **It will not converge.** It is a principled exploration schedule, not
> a learned policy, and should not be described to users as the system "learning what works."

```jac
node BanditArm {
    has family: MutationFamily;
    has pulls: int = 0;
    has window: list[float] = [];
    has unlocked: bool = False;
}

def arm_value(arm: BanditArm) -> float {
    if len(arm.window) == 0 {
        return 0.0;
    }
    return sum(arm.window) / len(arm.window);
}

def ucb(arm: BanditArm, total_pulls: int, c: float) -> float {
    if arm.pulls == 0 {
        return 1000000.0;
    }
    return arm_value(arm) + c * math.sqrt(math.log(max(total_pulls, 2)) / arm.pulls);
}

def record_pull(arm: BanditArm, reward: float, window_size: int) {
    arm.pulls += 1;
    arm.window.append(reward);
    if len(arm.window) > window_size {
        arm.window.pop(0);
    }
}
```

Three design points:

- **Sliding window, not a running mean.** The problem is non-stationary: model swaps pay off
  early and are exhausted quickly, while prompt and topology changes matter later. A lifetime
  average cannot track that.
- **Reward is the post-validation reward** (§15), not the train-batch delta. Rewarding the arm
  for candidates that later fail validation teaches it to propose overfitting mutations.
- **`unlocked` couples the bandit to the phase schedule** (§18): selection runs over unlocked
  arms only.

---

## 14. Search loop and archive

A single incumbent carried forward is a greedy hill-climber, and it stalls before it reaches
the structural changes that matter most.

The failure is visible in §22: removing the reviewer scores negative, and the change that
works — making the reviewer conditional — is a *different and larger* edit. Under
single-incumbent greedy search, the intermediate state is never occupied, so the productive
region is never reached.

### 14.1 Archive

```jac
node Archive {
    has capacity: int = 8;
}

edge Holds: Archive --> WorkflowVersion {
    has score: float = 0.0;
}

walker PruneArchive {
    has reports: list[int] = [];

    can prune with Archive entry {
        links = [edge here ->:Holds:->];
        if len(links) <= here.capacity {
            report len(links);
            disengage;
        }
        ranked = sorted(links, key=lambda (e: Holds) -> float { return e.score; }, reverse=True);
        for e in ranked[here.capacity:] {
            del e;
        }
        report here.capacity;
    }
}
```

- Retain the top-k configurations, not just the best one.
- The parent for round *t+1* is **sampled** from the archive, weighted by score, rather than
  always being the current best. This is what allows escape from a local optimum.
- Report the **Pareto frontier** at the end (highest quality / balanced / lowest cost / lowest
  latency operating points) — there is often no single best configuration, and presenting one
  hides a decision the user should make.

### 14.2 Compound mutations

Permit a small number of pre-declared mutation *pairs* as single actions, specifically for
topology: `remove_agent + adjust_downstream_prompt`, `merge_agents + merge_prompts`,
`add_conditional_branch + set_condition`. Without this, phase-5 changes are always evaluated in
the form that scores worst.

### 14.3 The round

1. Sample a parent from the archive.
2. Select a mutation family from the unlocked arms (§13, §18).
3. Rank targets from trace evidence (§10).
4. Generate ~6 candidates.
5. Validate statically (§2.2); discard invalid.
6. Stage A — elimination (§16.2).
7. Stage B — paired scoring on the shared batch (§9).
8. Schema gate (§12.1).
9. Promote the best gate-passing candidate to validation (§15).
10. On acceptance: create the new `WorkflowVersion`, link `DerivedFrom`, insert into archive.
11. Record the post-validation reward against the arm (§13).
12. Decrement budget; check stop conditions (§17).

Stop on: rounds exhausted, budget exhausted, target quality reached, or no accepted change for
`patience` consecutive rounds.

---

## 15. Validation and acceptance

A candidate that passes the train-batch gate is re-evaluated on validation. Acceptance requires
all of:

- validation delta positive under the same paired test, at a **stricter** threshold than train
  (`k = 2.0` vs. `k = 1.5`) — the candidate was selected as the best of ~6 on train, so its
  train delta is optimistically biased by selection;
- cost and latency constraints satisfied (§8.2);
- failure rate not materially increased;
- quality floor satisfied (§8.3);
- workflow still valid (§2.2) and within the approved search space (§19).

### 15.1 Validation erosion

Over 12 rounds with roughly one promotion each, the validation set is consumed a dozen times and
progressively stops being held out. Mitigations:

- **Rotate**: each round draws its validation subset from a different stratified partition.
- **Stricter threshold**, as above.
- **Accept that validation numbers are biased upward** and do not report them as the result.
  The honest number comes from §21.

---

## 16. Evaluation efficiency

### 16.1 Caching

Cache key: `config_hash + task_id + model_config + evaluator_version + dataset_epoch`. Because
versions are content-addressed (§2.1), an unchanged parent's scores are reused across rounds for
free — which is what makes the paired baseline in §9 cost nothing.

### 16.2 Successive halving, corrected

The original schedule ranked candidates on 2 tasks. Per §9.1, 2 tasks is far below the noise
floor; that stage cannot rank anything.

**The short stage eliminates broken candidates only.** It is a correctness filter, not a
quality filter:

| Stage | Tasks | Purpose | Eliminates on |
|---|---|---|---|
| A | 4 | Correctness filter | runtime errors, cap violations, schema failures |
| B | 20 | Paired scoring (§9) | the significance gate |
| C | 40 (validation) | Promotion (§15) | stricter gate + constraints |

No candidate is ever eliminated on quality at Stage A.

### 16.3 Other controls

- **Shared batches**: every candidate in a round sees the identical task set — a precondition
  for the pairing in §9, not merely a fairness nicety.
- **Low-variance execution**: §6.
- **Winner re-evaluation**: the finally-accepted configuration is re-run to confirm its
  improvement was not a sampling artifact.

---

## 17. Budget model

Workflow execution is the dominant cost, and the budget should be explicit rather than implied.

### 17.1 Per-round arithmetic

With 6 candidates, ~3 agent calls per execution, and the schedule from §16.2:

```
Stage A    6 candidates ×  4 tasks =  24 executions
Stage B    4 survivors  × 20 tasks =  80 executions   (baseline cached)
Stage C    1 promoted   × 40 tasks =  40 executions
                                     ---
                                     144 executions / round

144 executions × 3 agent calls     = 432 agent LLM calls
144 executions × 1 judge call      = 144 judge LLM calls
                                     ---
                                     ~576 LLM calls / round

× 12 rounds                        ≈ 6,900 LLM calls / training run
```

At mixed model pricing and ~1.5k tokens per call this is roughly **$10–20 per training run**,
before tool costs — which §6.1 substantially removes on replay. This number should be shown to
the user before training starts, and it is the number to attack when the resolution in §9.3
proves insufficient.

### 17.2 Accounting

```jac
node TrainingRun {
    has objective: str;
    has max_rounds: int = 12;
    has budget_usd: float = 25.0;
    has spent_usd: float = 0.0;
    has round_no: int = 0;
    has stalled_rounds: int = 0;
}

def budget_remaining(run: TrainingRun) -> float {
    return run.budget_usd - run.spent_usd;
}

def should_stop(run: TrainingRun, patience: int) -> bool {
    if run.round_no >= run.max_rounds {
        return True;
    }
    if budget_remaining(run) <= 0.0 {
        return True;
    }
    return run.stalled_rounds >= patience;
}
```

The runtime decrements `spent_usd` per execution — never the optimizer, which would let an
uncounted retry escape accounting.

### 17.3 Exhaustion rule

If the budget runs out mid-round, **abandon the round entirely**. A candidate evaluated on a
truncated batch has a delta whose standard error is not what the gate assumes; accepting it
would let the least-validated change in the run be the last one applied.

---

## 18. Optimization phases

Phases order the search from low-risk to high-risk. They are implemented as **arm gating**:
entering a phase sets `unlocked = True` on that family's arm, and the bandit selects among
unlocked arms only. Earlier phases remain unlocked — later phases add to the action set rather
than replacing it.

| Phase | Family unlocked | Rationale |
|---|---|---|
| 1 | `RUNTIME` | Cheap to evaluate, cannot break the graph |
| 2 | `MODEL`, `TOOL` | Bounded blast radius, large cost effects |
| 3 | `PROMPT` | Semantic risk; one section at a time |
| 4 | `CONTEXT` | Affects several agents at once |
| 5 | `TOPOLOGY` | Structural; highest chance of breaking the workflow |

Advance when the current phase yields no accepted change for `patience` rounds, or on a fixed
round schedule — whichever the objective favors.

---

## 19. Safety and constraint enforcement

The optimizer operates strictly inside a user-approved search space. It must not be able to add
unauthorized tools, widen permissions, reach new data sources, disable required safety checks,
create unbounded retries, exceed budgets, route sensitive context to unauthorized agents, or
remove mandatory approval steps.

Enforcement is in three places:

1. **Precondition** — mutations violating node flags (`mutable_prompt`, `removable`,
   `required`) are never generated (§11).
2. **Validation** — every candidate is re-checked before execution, including
   `tools(candidate) ⊆ tools(approved)`.
3. **Runtime caps** — §2.3, enforced during execution regardless of what validation concluded.

The three are deliberately redundant. A constraint enforced only at generation time is one
proposal-generator bug away from being unenforced.

---

## 20. Explainability

The lineage DAG from §2.1 *is* the explanation. Each `DerivedFrom` edge already carries the
mutation kind, target, before/after values, train delta with its standard error, validation
delta, and rationale; the report is a traversal from the final configuration back to the
original.

Every stated change should carry its evidence and its uncertainty:

> **Changed the classifier from a large model to a smaller model.**
> Validation accuracy 0.98 → 0.98 (Δ = −0.002 ± 0.021, n = 40); classification cost −63%.
> Accepted under the *min cost* objective: quality within tolerance, constraint improved.

> **Made the reviewer conditional on confidence < 0.72.**
> The reviewer modified 7% of high-confidence responses across 240 baseline spans.
> Quality Δ = +0.01 ± 0.03; reviewer invocations −68%; latency −2.4 s.

Reporting `Δ ± SE` rather than a bare number is what keeps §9's honesty visible to the user at
the point where they decide whether to accept the change.

---

## 21. Final evaluation

The original and optimized configurations are evaluated on the **test set, touched exactly
once**.

### 21.1 Report paired statistics

The test comparison is paired for the same reason §9 is. Report:

- **paired mean delta with a bootstrap confidence interval** for continuous scores;
- **McNemar's test** for binary task success — what matters is the discordant pairs, not the
  marginal rates.

### 21.2 Sample size is a first-class caveat

The original's illustrative result — 72% → 88% task success — is **not statistically
significant at typical dataset sizes**, and the report must not present it as though it were.
On 25 test tasks:

- Unpaired: SE of the difference ≈ 0.111, so a 16-point gain is ≈1.4σ (p ≈ 0.15).
- Paired: a net +4 flips lands at p ≈ 0.13–0.22 depending on the discordant split.

Either way it fails a conventional threshold. Pairing improves the estimate; it does not
manufacture significance that the sample size cannot support.

The consequence for the product: report the interval alongside the point estimate, and size the
test set deliberately. A confidence interval is also simply more credible than a bare
percentage.

### 21.3 The comparison table

| | Original | Optimized | Δ (95% CI) |
|---|---|---|---|
| Task success | | | |
| Quality | | | |
| Cost / task | | | |
| Latency (critical path) | | | |
| Tool-call failure rate | | | |
| Format compliance | | | |

Delivered alongside the optimized configuration, the full lineage diff (§20), and the Pareto
frontier from the archive (§14.1).

---

## 22. End-to-end example

Initial workflow: `Classifier → Support → Reviewer`.

Baseline over 40 tasks: quality 0.76 ± 0.05, $0.18/task, 12.4 s, classifier 99% accurate on an
expensive model, reviewer edits 4% of outputs, support agent calls web search before internal
docs.

| Round | Mutation | Result | Outcome |
|---|---|---|---|
| 1 | `MODEL`: classifier → smaller model | accuracy Δ = −0.002 ± 0.021; cost −19% | **accepted** |
| 2 | `PROMPT`: search internal docs before web | quality Δ = +0.06 ± 0.024; irrelevant tool calls −41% | **accepted** |
| 3 | `TOPOLOGY`: remove reviewer | quality Δ = −0.09 ± 0.031, below floor | **rejected** |
| 4 | `TOPOLOGY`+`RUNTIME`: reviewer conditional on confidence | quality Δ = +0.01 ± 0.030; reviewer calls −68%; latency −2.4 s | **accepted** |
| 5 | `TOOL`: remove web search | quality Δ = −0.07 ± 0.028 on recency-sensitive tasks | **rejected** |
| 6 | `TOOL`: web search conditional on doc-coverage miss | quality Δ = +0.03 ± 0.026; search calls −55% | **accepted** |

Two things this sequence demonstrates:

**Round 4 requires the compound mutation of §14.2.** Rounds 3 and 4 target the same component;
the difference between rejection and acceptance is that round 4 conditionalizes rather than
removes. A single-incumbent greedy search that only ever *removes* never finds it.

**"Confidence" must be defined.** LLM self-reported confidence is poorly calibrated and is not
a usable trigger. Define it as a deterministic quantity computed from the trace — a combination
of retrieval coverage (did documentation search return a scoring hit), tool-error presence, and
output schema completeness. Rounds 4 and 6 both depend on this, so it is a required piece of
runtime, not a detail.

Resulting configuration:

```
Small Classifier
      |
      v
Support Agent ──> Internal Documentation
      |
      └──> Web Search        [conditional: doc coverage miss]
      |
      v
Reviewer                     [conditional: confidence < 0.72]
      |
      v
Final Response
```

---

## 23. Summary

The workflow configuration is the object being optimized; the runtime is the environment;
typed mutations are the moves; execution traces are the observations; scored task performance
is the objective. The search is hill-climbing over an archive with bandit-selected operators —
not policy learning — and scoping the implementation to that is what keeps it buildable.

The loop:

1. Execute the current configuration and record traces.
2. Localize failures and inefficiencies from those traces.
3. Select a mutation family from the unlocked arms; select targets from trace evidence.
4. Generate typed candidate mutations.
5. Eliminate broken candidates cheaply; score survivors with **paired per-task deltas**.
6. Gate on effect size against its own standard error, never on sign alone.
7. Validate promotions against a rotated held-out set at a stricter threshold.
8. Accept, link into the lineage DAG, and update the arm on the post-validation reward.
9. Repeat within an explicit budget; report against a test set touched once.

The single property that determines whether any of this works is whether the reward can
distinguish a real improvement from noise at the batch sizes the budget allows. Sections 6, 9,
15, and 16 exist for that, and they are the parts to build first and weaken last.
