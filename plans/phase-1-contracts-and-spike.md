# Phase 1 (Hour 1) — Contracts, Environment, React Flow Spike

> Self-contained execution spec. Source of truth for architecture: [DESIGN.md](../DESIGN.md).
> Prior state: fresh `web-app` scaffold (guestbook demo) — `jac.toml` has `kind = "web-app"`,
> `[serve] base_route_app = "app"`. Do NOT re-scaffold.

## Context you must know (do not rediscover)

- Product: n8n-style visual multi-agent workflow builder with RL prompt optimization. 100% Jac
  full-stack (client JSX + server walkers), except `rl_bridge.py`/`mock_rl.py` (teammate's black box).
- Locked decisions D0–D12 are in DESIGN.md §2. Most load-bearing here:
  - **D3**: RL is a black box behind `optimize(payload: dict) -> dict` in `rl_bridge.py`.
  - **D9**: RL mutates `prompt_config.system_prompt`; the RL payload calls it `current_sem_prompt`.
- The WorkflowDefinition team schema (v1.0.0) is the canvas⇄server document. A copy exists at
  `/Users/hmahuvaw/Downloads/message.txt` — commit it into the repo this phase.

## Jac syntax rules (verified via `jac guide` — these override any older sketch)

1. byLLM import: `import from jaclang.byllm.lib { Model }`. LLM-visible descriptions use `sem`
   statements, NEVER docstrings. Project default model goes in `jac.toml` `[byllm.model]`.
2. npm packages: declared in `jac.toml` `[dependencies.npm]` or `jac install --npm <pkg>`;
   client imports use double-quoted package names, named imports only.
3. Client components: plain `.jac` with JSX; reactive state = `has` fields; must `await` all
   `sv import`ed server calls.
4. After every file: `jac check .` and follow the `-> run 'jac guide ...'` hints.

## Guides to load FIRST

```bash
jac guide jac-config
jac guide jac-python-interop
jac guide jac-npm-packages
jac guide jac-cl-components
```

---

## Task 1 — Commit the contract schemas

Create `schemas/workflow_definition.json`: copy **verbatim** from `/Users/hmahuvaw/Downloads/message.txt`.

Create `schemas/workflow_execution_payload.json` (Platform → RL, FROZEN):

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "WorkflowExecutionPayload",
  "type": "object",
  "required": ["workflow_run_id", "task_context", "agent_states", "execution_trace"],
  "properties": {
    "workflow_run_id": { "type": "string" },
    "task_context": {
      "type": "object",
      "required": ["initial_input", "expected_ground_truth", "actual_final_output"],
      "properties": {
        "initial_input": { "type": "string" },
        "expected_ground_truth": { "type": "string" },
        "actual_final_output": { "type": "string" }
      }
    },
    "agent_states": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["node_id", "agent_name", "type", "fixed_role_description",
                     "expected_input", "expected_output", "current_sem_prompt"],
        "properties": {
          "node_id": { "type": "string" },
          "agent_name": { "type": "string" },
          "type": { "type": "string", "enum": ["Trigger", "Router", "WorkerAgent", "Aggregator"] },
          "fixed_role_description": { "type": "string" },
          "expected_input": { "type": "string" },
          "expected_output": { "type": "string" },
          "current_sem_prompt": { "type": "string" }
        }
      }
    },
    "edges": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": { "source": { "type": "string" }, "target": { "type": "string" } }
      }
    },
    "execution_trace": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["step", "node_id", "status"],
        "properties": {
          "step": { "type": "integer" },
          "node_id": { "type": "string" },
          "status": { "type": "string", "enum": ["EXECUTED", "SKIPPED", "FAILED"] },
          "input_received": { "type": "string" },
          "output_generated": { "type": "string" },
          "error_message": { "type": "string" }
        }
      }
    }
  }
}
```

Create `schemas/rl_optimizer_response.json` (RL → Platform, FROZEN):

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "RLOptimizerResponse",
  "type": "object",
  "required": ["critic_score", "analysis_log", "prompt_mutations"],
  "properties": {
    "critic_score": { "type": "number", "minimum": 0.0, "maximum": 1.0 },
    "analysis_log": { "type": "string" },
    "prompt_mutations": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["node_id", "new_sem_prompt"],
        "properties": {
          "node_id": { "type": "string" },
          "new_sem_prompt": { "type": "string" }
        }
      }
    }
  }
}
```

## Task 2 — RL black box (mock inside)

Create `mock_rl.py` (complete, final):

```python
def optimize(payload: dict) -> dict:
    """Mock RL: mutates the first WorkerAgent prompt so the full loop is exercised."""
    mutations = []
    for state in payload["agent_states"]:
        if state["type"] == "WorkerAgent":
            mutations.append({
                "node_id": state["node_id"],
                "new_sem_prompt": state["current_sem_prompt"] + " Be more concise and specific.",
            })
            break
    return {
        "critic_score": 0.42,
        "analysis_log": "[mock] Appended conciseness instruction to first worker.",
        "prompt_mutations": mutations,
    }
```

Create `rl_bridge.py` (complete, final until Phase 5's one-line swap):

```python
from mock_rl import optimize as _impl   # Phase 5: from teammate_rl import optimize as _impl

REQUIRED_KEYS = {"critic_score", "analysis_log", "prompt_mutations"}


def optimize(payload: dict) -> dict:
    response = _impl(payload)
    missing = REQUIRED_KEYS - set(response)
    if missing:
        raise ValueError(f"RLOptimizerResponse missing keys: {missing}")
    return response
```

Smoke test (must print a valid response):

```bash
python3 -c "from rl_bridge import optimize; print(optimize({'agent_states':[{'node_id':'w1','type':'WorkerAgent','current_sem_prompt':'x'}]}))"
```

## Task 3 — Environment

1. Create `.env` with `OPENAI_API_KEY=<key>` (ask the user for the key if not present).
2. Ensure `.env` is listed in `.gitignore`.
3. Append to `jac.toml`:

```toml
[byllm.model]
default_model = "gpt-4o-mini"
```

## Task 4 — Teammate coordination (send, don't block)

Send the RL owner this message (verbatim intent):
- "Implement `optimize(payload: dict) -> dict` — input `schemas/workflow_execution_payload.json`,
  output `schemas/rl_optimizer_response.json`. Raise on failure, never return partial JSON."
- "Mutation target is `prompt_config.system_prompt` only (we map it to `current_sem_prompt` in the
  payload). We bump `prompt_version` on our side."
- "We both read `OPENAI_API_KEY`. Send your requirements.txt now."

## Task 5 — React Flow-in-Jac spike (the phase's real risk)

1. `jac install --npm @xyflow/react`
2. Create `client/CanvasSpike.jac`:

```jac
import "@xyflow/react/dist/style.css";
import from "@xyflow/react" { ReactFlow, Background, Controls, applyNodeChanges, applyEdgeChanges }

def:pub CanvasSpike() -> JsxElement {
    has nodes: list = [
        {"id": "a", "position": {"x": 100, "y": 100}, "data": {"label": "Trigger"}},
        {"id": "b", "position": {"x": 400, "y": 100}, "data": {"label": "Worker"}}
    ];
    has edges: list = [{"id": "e1", "source": "a", "target": "b"}];

    return <div style={{"width": "100vw", "height": "100vh"}}>
        <ReactFlow
            nodes={nodes}
            edges={edges}
            onNodesChange={lambda (changes: any) { nodes = applyNodeChanges(changes, nodes); }}
            onEdgesChange={lambda (changes: any) { edges = applyEdgeChanges(changes, edges); }}
            fitView
        >
            <Background />
            <Controls />
        </ReactFlow>
    </div>;
}
```

3. In `main.jac`'s `cl` block, temporarily render `<CanvasSpike/>` instead of the guestbook app
   (`import from .client.CanvasSpike { CanvasSpike }` inside the cl section).
4. Run and verify:

```bash
pkill -f "jac start"; jac start --dev main.jac < /dev/null &
jac browse open localhost:8000
jac browse snapshot
jac browse screenshot
```

Drag a node in the browser check; confirm no build errors (`JAC_CLIENT_00x` diagnostics mean a
missing dep / syntax error — set `JAC_DEBUG=1` for raw Vite output).

**Fallback (invoke only if broken after ~30 min):** replace ReactFlow with absolutely-positioned
`<div>` blocks + an SVG `<line>` layer in the SAME component contract (`nodes`/`edges` list shapes
unchanged) so Phase 2 is unaffected. Never leave Jac for a TS/React app.

---

## Phase gate (all must pass before Phase 2)

- [ ] `schemas/` contains all three JSON contracts
- [ ] `rl_bridge` smoke test prints a valid mock response
- [ ] `.env` + `[byllm.model]` configured; `.env` gitignored
- [ ] Teammate message sent
- [ ] Interactive 2-node canvas renders at localhost:8000; node drag updates Jac `has` state
- [ ] `jac check .` green
- [ ] `context.md` updated: phase 1 complete, spike outcome (ReactFlow vs SVG fallback)
