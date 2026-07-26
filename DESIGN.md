# Design Doc: Visual Multi-Agent Platform with RL Prompt Optimization

**Scope:** Full-stack Jac platform (client canvas + server engine + RL handshake)
**Timeline:** 6-hour hackathon build — JacHacks SF 2026
**Rubric alignment:** Use of Jac (40%) — walkers, graph traversal, byLLM, agentic flows,
**and** a Jac client UI. The product is Jac end-to-end.

**Jac share of codebase: ~90–95%** (everything except the teammate-owned RL black-box
body, which may be Python behind a single import). No React/TypeScript app, no FastAPI.

---

## 1. Executive Summary

A drag-and-drop, n8n-style platform to visually compose, execute, and automatically
optimize multi-agent workflows — built as a **Jac full-stack web-app**.

Workflows are defined by a **WorkflowDefinition** JSON document (§4.1). A Jac client
(JSX components + React Flow via npm) owns the canvas and persistent state. Jac
server walkers spawn the graph, traverse edges, execute agents via `by llm()`, and
rehydrate prompts after RL. One process: `jac start --dev main.jac`.

**Division of labor (by design — all Jac):**

| Layer | Codespace | Responsibility |
|---|---|---|
| Canvas, Inspector, Training Console | Jac **client** (`.jac` + JSX; React Flow via npm) | View + persistent WorkflowDefinition state |
| Endpoints (`RunSingle`, `TrainStep`) | Jac **server** (`def:pub` / `walker:pub`) | Request lifecycle orchestration |
| Graph spawn, traversal, routing, data mapping, byLLM, trace, mutation | Jac **server** (nodes, walkers, `by llm()`) | All engine logic |
| RL optimizer | Black box (`optimize(payload) -> dict`) imported into Jac | Scoring + mutations |

Client reaches the server via `sv import` + `await` / `root spawn` — no hand-rolled HTTP
client, no Express, no FastAPI.

---

## 2. Locked Architectural Decisions

Settled before the build. Do not reopen during the 6 hours.

### D0 — Full-stack Jac (no separate frontend stack)
The project kind is a Jac **web-app**. Scaffold / run with:

```bash
jac create . --kind web-app   # if not already scaffolded
jac start --dev main.jac
```

- **Client:** plain `.jac` files with JSX (inferred client). Guides: `jac-cl-components`,
  `jac-cl-organization`, `jac-fullstack-patterns`, `jac-npm-packages`, `jac-cl-styling`.
- **Server:** default codespace — walkers, `def:pub` endpoints, byLLM. Guides:
  `jac-sv-endpoints`, `jac-walker-patterns`, `jac-by-llm`, `jac-node-edge-patterns`.
- **Canvas library:** `@xyflow/react` (React Flow) declared in `jac.toml` `[dependencies.npm]`
  and imported from client Jac. Hour 1 spike: prove one node + one edge renders and
  callbacks fire. If React Flow interop fails within ~30 min, fall back to a minimal
  custom SVG/HTML canvas **still in Jac client** — never a separate TS/React repo.
- **Entry:** `main.jac` registers server endpoints (plain `import from …`) and mounts
  `def:pub app() -> JsxElement`. Serve with `[serve] base_route_app = "app"`.
- **Validate:** `jac check .` after every edit; QA with `jac browse`.

This is the primary lever for the Use of Jac rubric: judges can open the repo and see
`.jac` from UI to walker.

### D1 — Prompts are node data, not semstrings (prompt-as-parameter)
byLLM assembles prompts from *static* code semantics, which cannot be mutated per-node
at runtime. The mutable prompt lives in node data (`prompt_config.system_prompt`, see D9)
and is passed to **one generic `by llm()` ability** as an argument. The only static
semstring in the system is the meta-instruction on `run_agent`.

```jac
"""Act according to the given role and follow the instructions
to transform the input into the required output."""
def run_agent(role_description: str, instructions: str, input_json: str) -> str by llm();
```

*Validation gate:* first 30 min of Hour 3 — call `run_agent` twice with different
`instructions`, confirm behavior changes. Fallback: direct LLM SDK call inside a regular
Jac function with the identical signature.

### D2 — Stateless server graph; Jac client is the single source of truth
The Jac graph exists only inside a request. The WorkflowDefinition held in client
component state is the persistent state. Per-request lifecycle:

```text
1. HYDRATE    spawn Jac nodes + edges from the WorkflowDefinition
2. EXECUTE    TaskWalker runs from entry_node_id, collects execution_trace
3. EVALUATE   build WorkflowExecutionPayload → optimize() → RLOptimizerResponse
4. MUTATE     PromptRehydrator applies prompt_mutations to the in-memory graph
5. SERIALIZE  read updated node states off the graph into the response; discard graph
```

The client applies returned node states in one state update; the next request naturally
carries mutated prompts forward. Every request is reproducible from its payload alone.

### D3 — RL engine is a black box behind one function
Called from Jac server code; implementation may be Python (Jac Python interop) or Jac:

```jac
# From a server module — the ONLY place the platform touches RL
import from rl_bridge { optimize }

rl_response = optimize(workflow_payload);   # dict in → dict out
```

```python
# rl_bridge.py — teammate fills the body; platform never cares how
def optimize(payload: dict) -> dict:
    """In: WorkflowExecutionPayload (§4.2). Out: RLOptimizerResponse (§4.3)."""
```

- Validate the return shape in Jac (required keys / types) at the call site.
- `optimize()` raises on failure; never returns partial JSON.
- Body is `mock_rl.optimize` (§8) until Hour 5; mock and real are interchangeable —
  swapping back is demo insurance.
- Every `(payload, response)` pair dumped to timestamped JSON files (debugging, offline
  RL development, demo replay insurance).
- Expected slow (10–30 s): endpoint is a normal Jac server call; client shows
  "step running…" and surfaces failures into the Training Console.
- Shared `.env` / `OPENAI_API_KEY` for platform byLLM and RL LLM calls.
- Contracts frozen after Hour 1; changes additive + optional only.

### D4 — RL engine owns scoring; no Critic node
Node types are exactly `Trigger | Router | WorkerAgent | Aggregator`. The
`output_node_id` node's output becomes `task_context.actual_final_output`; the RL black
box compares it to `expected_ground_truth` and produces `critic_score`.

### D5 — Single-branch routing via `ROUTE_VALUE` edges
The Router emits `{route, reason}` (per its `expected_output_schema`). The walker follows
the single outgoing edge whose `condition.route_value` matches `route`
(`type_config.router.route_output_key` names the key). Exactly one branch activates per
run. Non-taken branches are recorded `SKIPPED` by a post-traversal diff in the walker's
exit logic. The `reason` field is streamed to the demo console ("Router chose billing
because…").

### D6 — Client-driven training loop; no streaming infrastructure
The Training Console (Jac client) loops
`for pair in dataset → for epoch → await train_step(...)` (or `root spawn TrainStep(...)`),
appending each response to console state. Stop condition: 3 epochs or
`critic_score >= 0.9`. Stop button falls out for free. Mutations applied to client
WorkflowDefinition state between iterations (D2). No SSE/WebSockets required for v1.

### D7 — Native Jac serve only (no FastAPI / Express)
Endpoints are Jac `def:pub` functions and/or `walker:pub` walkers, registered from
`main.jac`, reached from the client via `sv import`. There is no separate API framework.
Transport-agnostic walkers (plain data in / out) keep engine logic clean.

### D8 — Failure semantics
A failed LLM call **aborts the walk** (matches `fail_fast: true` /
`continue_on_failure: false` in the definition schema): node marked `FAILED` with
`error_message`, remaining nodes `SKIPPED`, payload still sent to the RL engine
(failure traces are training signal). Retries/timeouts in `runtime_config` are parsed
but not implemented in v1.

### D9 — RL mutation target: `prompt_config.system_prompt`
The WorkflowDefinition schema uses structured `prompt_config`. Boundary mapping
(RL contract unchanged):
- Building the RL payload: `agent_states[].current_sem_prompt := prompt_config.system_prompt`.
- Applying a mutation: `PromptRehydrator` writes `new_sem_prompt` into
  `prompt_config.system_prompt` and **increments `prompt_version`** (prompt evolution is
  visible in the Inspector — a demo beat).
- `user_prompt_template`, `output_instructions`, and `fixed_role_description` are
  guardrails: never sent as mutable state, never mutated.

### D10 — Minimal JSONPath data mapping
Edges carry `data_mapping: {source, target}`. v1 implements exactly two forms — `$`
(whole object) and `$.dotted.path` (get/set by key chain) — which covers every mapping
the schema uses (`$.input`, `$.workflow_input`, `$.node_input`,
`$.upstream_outputs.<id>`). The walker carries a `context: dict` (not a string); trace
entries serialize objects to strings for the RL payload, so the RL contract is untouched.

### D11 — Declared but deferred (parsed, stored, not executed in v1)
- `tool_catalog`, `skill_catalog`, `tool_bindings`, `skill_bindings`, and
  `execution_mode: "TOOL_LOOP"` — every worker executes as single-shot `run_agent`.
  Demo definitions use empty bindings so schema and behavior agree on stage.
  (byLLM tool support is the stretch goal if hours remain; the demo must not depend on it.)
- Per-node `model_config` — honored if byLLM makes per-node `Model` instances cheap,
  else one global fast model. All demo nodes use a fast model regardless (4-min clock).
- `max_parallel_nodes`, `context_config`, `observability_config`, `configuration_hash` —
  accepted in the schema, ignored by the sequential walker (only one branch runs anyway).

### D12 — Aggregator gating under routing
`type_config.aggregator.required_upstream_node_ids` is interpreted as
**"required = intersection with nodes actually activated this run."** Under D5
single-branch routing this collapses to the one worker that ran, so a routed workflow
can never deadlock waiting on a SKIPPED branch.

---

## 3. Graph Topologies

**Pattern A — Sequential:** `[Trigger] → [Worker A] → [Worker B]` — edge
`data_mapping` carries each node's output forward as the next node's input.

**Pattern B — Routed (the demo graph):**

```text
                    ┌─ROUTE_VALUE:"billing"──> [Worker A] ─ON_SUCCESS─┐
[Trigger] → [Router]┤                                                 ├──> [Aggregator]
                    └─ROUTE_VALUE:"technical"─> [Worker B] ─────────  ┘
                          (exactly one branch taken per run — D5)
```

---

## 4. Contracts

### 4.1 WorkflowDefinition (client ⇄ server) — team schema (v1.0.0)
The full document lives at `schemas/workflow_definition.json` (the version shared on
2026-07-26). Key fields the engine consumes in v1:

- `entry_node_id` / `output_node_id` — walker spawn point and final-output node.
- `nodes[]` — `node_id`, `node_name`, `type`, `enabled`, `fixed_role_description`,
  `expected_input_schema` / `expected_output_schema`, `prompt_config`
  (mutation target per D9), `type_config` (router route key, aggregator requirements),
  `ui` (React Flow positions — direct mapping).
- `edges[]` — `source_node_id`, `target_node_id`,
  `condition` (`ALWAYS` | `ROUTE_VALUE` | `ON_SUCCESS`), `data_mapping` (D10).
- Everything under D11 is parsed and preserved round-trip but not executed.

### 4.2 Platform → RL: `WorkflowExecutionPayload` (FROZEN)

```json
{
  "workflow_run_id": "uuid-per-request",
  "task_context": {
    "initial_input": "...",
    "expected_ground_truth": "...",
    "actual_final_output": "..."
  },
  "agent_states": [
    {
      "node_id": "...", "agent_name": "...",
      "type": "Trigger | Router | WorkerAgent | Aggregator",
      "fixed_role_description": "... (guardrail — never mutated)",
      "expected_input": "... (stringified schema)",
      "expected_output": "... (stringified schema)",
      "current_sem_prompt": "... (:= prompt_config.system_prompt, per D9)"
    }
  ],
  "edges": [{ "source": "...", "target": "..." }],
  "execution_trace": [
    {
      "step": 1, "node_id": "...",
      "status": "EXECUTED | SKIPPED | FAILED",
      "input_received": "... (JSON serialized to string)",
      "output_generated": "...",
      "error_message": "..."
    }
  ]
}
```

### 4.3 RL → Platform: `RLOptimizerResponse` (FROZEN)

```json
{
  "critic_score": 0.73,
  "analysis_log": "human-readable reasoning, streamed to the console",
  "prompt_mutations": [
    { "node_id": "...", "new_sem_prompt": "... (applied per D9)" }
  ]
}
```

Shapes validated in Jac at the `optimize()` call site.

---

## 5. Project Layout (all `.jac` except RL bridge)

```text
main.jac                 # entry: server imports + def:pub app()
engine/
  nodes.jac              # Trigger, Router, WorkerAgent, Aggregator
  llm.jac                # Model glob, run_agent / run_router by llm()
  builder.jac            # GraphBuilder from WorkflowDefinition
  task_walker.jac        # TaskWalker + JSONPath helpers (D10)
  rehydrate.jac          # PromptRehydrator
  serialize.jac          # StateSerializer → agent_states / updated_nodes
  endpoints.jac          # def:pub run_single, train_step
client/
  AppShell.jac           # stateful shell: WorkflowDefinition + console logs
  canvas/
    FlowCanvas.jac       # React Flow wrapper (@xyflow/react)
    AgentNode.jac        # minimal block view
  inspector/
    NodeInspector.jac    # settings modal
  training/
    TrainingConsole.jac  # dataset, train loop, walker-named logs
schemas/
  workflow_definition.json
rl_bridge.py             # optimize() — mock until Hour 5; only non-Jac surface
mock_rl.py               # Hour-4 mock body
```

Consult `jac guide jac-core-cheatsheet` and `jac guide jac-types` before writing Jac.
Every edit: `jac check .`.

### 5.1 Server engine sketch

```jac
import from byllm.llm { Model }
glob llm = Model(model_name="gpt-4o-mini");   # fast model — 4-minute demo clock

"""Act according to the given role and follow the instructions
to transform the input into the required output."""
def run_agent(role_description: str, instructions: str, input_json: str) -> str by llm();

"""Choose exactly one route name from the options that best fits the input.
Return JSON: {"route": ..., "reason": ...}."""
def run_router(instructions: str, input_json: str, options: list[str]) -> str by llm();

# Node archetypes mirror §4.1 (prompt_config as dict; system_prompt is mutable)

walker TaskWalker {
    has context: dict = {};
    has execution_trace: list = [];
    has step_counter: int = 0;
    # inbound data_mapping → run_agent/run_router → trace
    # Router: follow ROUTE_VALUE edge matching route_output_key
    # Aggregator: gate on activated ∩ required_upstream_node_ids (D12)
    # exit: SKIPPED diff; on LLM failure: FAILED + abort (D8)
}

walker PromptRehydrator {
    has mutations: dict;   # {node_id: new_sem_prompt}
    # write prompt_config.system_prompt, increment prompt_version (D9)
}
```

### 5.2 Client ↔ server wiring

```jac
# client module
sv import from engine.endpoints { run_single, train_step }

async def handle_train_step() {
    result = await train_step(workflow=workflow, initial_input=inp, expected_ground_truth=gt);
    # apply result.updated_nodes into WorkflowDefinition state; append console logs
}
```

Register every endpoint name in `main.jac`'s import list (missing name → 405).

---

## 6. API Surface (Jac endpoints)

Exposed as Jac `def:pub` (preferred when no graph visit is needed for the *handler*
itself — handlers may still spawn walkers internally) or `walker:pub`.

### `run_single`
Args: WorkflowDefinition + `input_text` → hydrate, execute, return the
`output_node_id` node's output + `execution_trace`. No RL, no mutation.

### `train_step`
Args: WorkflowDefinition + one dataset pair (`initial_input`, `expected_ground_truth`)
→ full D2 lifecycle.
**Returns:** `critic_score`, `analysis_log`, `prompt_mutations`,
`updated_nodes` (mutated `prompt_config`s; client applies to canvas state),
`execution_trace`.

---

## 7. Client UI (Jac + JSX)

- **FlowCanvas:** `@xyflow/react` imported in Jac. Minimal blocks — type icon,
  `node_name`, handles. Node `ui` positions round-trip through the WorkflowDefinition.
  Edge labels show route values.
- **NodeInspector:** `node_name`, `fixed_role_description` (read-only guardrail),
  `prompt_config.system_prompt` (editable; shows `prompt_version` — watch it climb
  during training), expected I/O schemas (read-only in v1).
- **TrainingConsole:** dataset upload, Train/Stop, log stream. **Entries name the Jac
  constructs doing the work** — `[TaskWalker] → WorkerAgent "billing_agent" EXECUTED`,
  `[TaskWalker] Router chose "billing": <reason>`, `[PromptRehydrator] node_3 → v2` —
  so judges watch Jac run live inside the product (rubric: "show where Jac runs").
- **Stateful shell:** one Jac client component owns WorkflowDefinition + logs; children
  receive props/callbacks (`jac-cl-organization`).

---

## 8. Mock RL (`mock_rl.py`)

The only intentional non-Jac module (teammate drop-in). A mock **function** (not a
static file): returns a plausible response that *changes* a system prompt (e.g. appends
"Be more concise."), so the full loop — rehydration → version bump → response → canvas
update — is genuinely exercised in Hour 4. Kept permanently as the fallback behind
`rl_bridge.optimize`. Prefer implementing the mock in Jac only if the teammate is also
delivering Jac; otherwise keep the Python bridge as the stable contract.

---

## 9. Demo Script (4 minutes, rubric-driven)

Scenario: **support email triage** — a support lead at a small SaaS company routes
billing vs. technical emails by hand today. (Named person, narrow problem.)

1. **0:00–0:30** — Who it's for, what breaks today. Show the canvas graph.
2. **0:30–1:00** — `run_single` on a sample email: mediocre output. Split-screen beat:
   the `.jac` `TaskWalker` next to the Jac client canvas executing it (~10 s).
3. **1:00–3:00** — Train. Console streams walker-named logs + router reasons;
   `critic_score` climbs over 2–3 steps; `prompt_version` ticks up in the Inspector.
4. **3:00–3:45** — `run_single` again, same email: improved output. Before/after.
5. **3:45–4:00** — Close: "UI, graph, walkers, byLLM, and prompt mutation are all Jac —
   one language, one process. The only non-Jac line is the RL black box we call."

**Insurance:** recorded payload logs (D3) allow replaying a known-good run if
network/APIs fail on stage. Seed the demo graph with **deliberately weak prompts** so
the score climb is visible.

---

## 10. Build Schedule

| Hour | Work | Gate / risk retired |
|---|---|---|
| 1 | Freeze §4.2/§4.3 + `optimize()` + D9 with RL owner; shared `.env`; ensure `web-app` scaffold + `jac.toml` npm deps (`@xyflow/react`); **React Flow-in-Jac spike**; commit WorkflowDefinition schema; **pick demo scenario** | Fullstack Jac skeleton + canvas risk retired |
| 2 | Jac client: FlowCanvas, AgentNode, edge DnD, NodeInspector bound to WorkflowDefinition | UI state model final (all `.jac`) |
| 3 | **First 30 min: validate D1.** GraphBuilder, TaskWalker (dict context, D10, routing, D12), PromptRehydrator, `run_single` / `train_step` endpoints wired in `main.jac` | Core engine + RPC work |
| 4 | Client training loop + `mock_rl` — mutation flows mock → rehydrator → version bump → client state; payload logging | Full loop proven end-to-end |
| 5 | Swap mock for teammate's `optimize()`; integration debug using logged payloads | Live RL integrated |
| 6 | Walker-named console polish, weak-prompt demo graph, run §9 script twice; `jac browse` smoke | Demo rehearsed |
