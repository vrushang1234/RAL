# Phase 2 (Hour 2) — Client Shell: Canvas, Inspector, Console Chrome

> Self-contained execution spec. Architecture: [DESIGN.md](../DESIGN.md).
> Prior state (Phase 1): schemas committed in `schemas/`, `rl_bridge.py`/`mock_rl.py` working,
> `@xyflow/react` proven in `client/CanvasSpike.jac` (or SVG fallback with the same
> `nodes`/`edges` list contract), `[byllm.model] default_model = "gemini/gemini-2.0-flash"` in `jac.toml`.

## Context you must know

- The client owns the **WorkflowDefinition** dict (shape: `schemas/workflow_definition.json`) as
  the single source of truth (decision D2). The server never persists it.
- Node types: `Trigger | Router | WorkerAgent | Aggregator`. Trigger has `prompt_config: null`.
- Prompts live at `node["prompt_config"]["system_prompt"]`; version at `["prompt_version"]`.
- This phase is **UI + state only** — no server calls yet (those land in Phases 3–4).

## Jac client rules (verified via `jac guide`)

1. One **stateful shell** component owns all state; children get props + `Callable` callbacks
   (`jac-cl-organization`). Handler bodies may live in a `.impl.jac` annex.
2. `has` fields in a component = React state. Reassignment triggers re-render.
3. npm imports: `import from "@xyflow/react" { ReactFlow, Handle, Position, ... }`.
4. Lambdas for inline handlers: `onClick={lambda (e: MouseEvent) { ... }}`.
5. List rendering: `{[<Comp key={x} .../> for x in items]}`; use `len(x)`, never `.length`.
6. `jac check .` after every file.

## Guides to load FIRST

```bash
jac guide jac-cl-organization
jac guide jac-cl-components
jac guide jac-cl-styling
```

---

## Task 1 — `client/demo_workflow.jac` (seed data)

`glob DEMO_WORKFLOW: dict = { ... };` — a complete WorkflowDefinition conforming to
`schemas/workflow_definition.json`. Scenario: **support email triage** (the demo story).

Exact structure:

- `schema_version: "1.0.0"`, `workflow_id: "wf_demo_triage"`, `workflow_name: "Support Email Triage"`,
  `workflow_version: 1`, `status: "DRAFT"`, `entry_node_id: "trigger_1"`, `output_node_id: "aggregator_1"`.
- `input_schema`/`output_schema`: as in the team schema (single `input`/`output` string).
- `global_config`: copy defaults from the team schema.
- `tool_catalog: []`, `skill_catalog: []` (D11: declared, not executed).
- `nodes` (5): each with `enabled: true`, empty `skill_bindings`/`tool_bindings`,
  `runtime_config` defaults from the team schema, and `ui.position` laid out left→right:
  - `trigger_1` — type `Trigger`, `prompt_config: null`,
    `type_config.trigger = {"trigger_type": "MANUAL", "config": {}}`, position `{x:60,y:220}`.
  - `router_1` — type `Router`, position `{x:340,y:220}`,
    `fixed_role_description: "You classify inbound support emails."`,
    `prompt_config`: `{"prompt_id":"p_router","prompt_version":1,`
    `"system_prompt":"Decide if this email is about billing or technical issues.",`
    `"user_prompt_template":"{{workflow_input}}","output_instructions":"Return the selected route.",`
    `"variables":["workflow_input"]}`,
    `type_config.router = {"routing_mode":"LLM","route_output_key":"route","default_target_node_id":null}`,
    `expected_output_schema` requiring `route` (+optional `reason`).
  - `worker_billing` — type `WorkerAgent`, position `{x:640,y:100}`,
    `fixed_role_description: "You are a billing support specialist."`,
    **deliberately weak** `system_prompt: "Reply to the email."` (`prompt_version: 1`),
    `type_config.worker = {"execution_mode":"TOOL_LOOP","max_iterations":5}` (parsed, ignored — D11).
  - `worker_technical` — type `WorkerAgent`, position `{x:640,y:340}`,
    `fixed_role_description: "You are a technical support engineer."`,
    weak `system_prompt: "Answer the question."`.
  - `aggregator_1` — type `Aggregator`, position `{x:940,y:220}`,
    `fixed_role_description: "You produce the final customer-ready reply."`,
    weak `system_prompt: "Combine into a reply."`,
    `type_config.aggregator = {"strategy":"SUMMARIZE",`
    `"required_upstream_node_ids":["worker_billing","worker_technical"],"custom_instructions":null}`
    (D12: interpreted as intersection-with-activated at runtime).
- `edges` (4):
  - `e1` trigger→router, condition `{"type":"ALWAYS","expression":null,"route_value":null}`,
    `data_mapping {"source":"$.input","target":"$.workflow_input"}`.
  - `e2` router→worker_billing, condition `{"type":"ROUTE_VALUE","route_value":"billing"}`,
    mapping `{"source":"$","target":"$.node_input"}`, `ui.label: "billing"`.
  - `e3` router→worker_technical, condition `ROUTE_VALUE` `"technical"`, same mapping,
    `ui.label: "technical"`.
  - `e4a` worker_billing→aggregator_1 and `e4b` worker_technical→aggregator_1, condition
    `{"type":"ON_SUCCESS"}`, mapping `{"source":"$","target":"$.upstream_outputs.<worker id>"}`.
- `metadata`: any ISO timestamps, `created_by: "demo"`, `tags: []`.

Also export a default dataset:

```jac
glob DEMO_DATASET: list = [
    {"initial_input": "Hi, I was charged twice for my subscription this month. Please refund one charge.",
     "expected_ground_truth": "Apologetic reply confirming the duplicate charge will be refunded within 5-7 business days, with a reference number."},
    {"initial_input": "The app crashes every time I try to export a PDF on macOS.",
     "expected_ground_truth": "Reply acknowledging the crash, asking for the app version and macOS version, and suggesting reinstall as an interim fix."}
];
```

## Task 2 — `client/AppShell.jac` (the stateful shell)

```jac
import from .demo_workflow { DEMO_WORKFLOW, DEMO_DATASET }
import from .FlowCanvas { FlowCanvas }
import from .NodeInspector { NodeInspector }
import from .TrainingConsole { TrainingConsole }

def:pub AppShell() -> JsxElement {
    has workflow: dict = DEMO_WORKFLOW;
    has logs: list = [];               # [{"kind": "walker"|"score"|"mutation"|"error"|"info", "text": str}]
    has selected_node_id: str = "";    # "" = inspector closed
    has running: bool = False;
    has last_output: str = "";

    def append_log(kind: str, text: str) {
        logs = logs + [{"kind": kind, "text": text}];
    }

    def on_select_node(node_id: str) { selected_node_id = node_id; }
    def on_close_inspector() { selected_node_id = ""; }

    def on_update_prompt(node_id: str, new_prompt: str) {
        # copy workflow, find node by node_id, set prompt_config.system_prompt = new_prompt,
        # reassign workflow (reassignment triggers re-render)
    }

    def on_nodes_change(node_id: str, x: float, y: float) {
        # write ui.position back into the matching workflow node; reassign workflow
    }

    def apply_updated_nodes(updated: list) {
        # for each {node_id, prompt_config}: replace that node's prompt_config; reassign workflow
        # (used by TrainingConsole in Phase 4; implement now, cheap)
    }

    # layout: flex row; canvas 70%, right sidebar 30% = TrainingConsole;
    # NodeInspector rendered as a fixed overlay when selected_node_id != ""
    return <div style={{"display": "flex", "height": "100vh", "fontFamily": "system-ui"}}>
        <FlowCanvas workflow={workflow} on_select_node={on_select_node} on_nodes_change={on_nodes_change}/>
        <TrainingConsole workflow={workflow} dataset={DEMO_DATASET} logs={logs}
                         running={running} last_output={last_output}
                         append_log={append_log} apply_updated_nodes={apply_updated_nodes}/>
        {selected_node_id != "" and
            <NodeInspector workflow={workflow} node_id={selected_node_id}
                           on_update_prompt={on_update_prompt} on_close={on_close_inspector}/>}
    </div>;
}
```

(Props typed as `dict` / `list` / `str` / `Callable` per `jac-cl-components`.)

## Task 3 — `client/FlowCanvas.jac`

Derives React Flow arrays from the WorkflowDefinition on every render (no duplicate state):

```jac
import "@xyflow/react/dist/style.css";
import from "@xyflow/react" { ReactFlow, Background, Controls, applyNodeChanges }
import from .AgentNode { AgentNode }

def:pub FlowCanvas(workflow: dict, on_select_node: Callable, on_nodes_change: Callable) -> JsxElement {
    # rf_nodes = [{"id": n["node_id"], "position": n["ui"]["position"], "type": "agent",
    #              "data": {"label": n["node_name"], "kind": n["type"]}} for n in workflow["nodes"]]
    # rf_edges = [{"id": e["edge_id"], "source": e["source_node_id"], "target": e["target_node_id"],
    #              "label": (e["ui"]["label"] if e["ui"]["label"] else ""), "animated": e["condition"]["type"] == "ROUTE_VALUE"}
    #             for e in workflow["edges"]]
    # onNodeClick={lambda (ev: any, node: any) { on_select_node(node.id); }}
    # onNodesChange: for each position-type change with a position payload,
    #                call on_nodes_change(change.id, change.position.x, change.position.y)
    # nodeTypes: pass {"agent": AgentNode} — define it OUTSIDE the component body
    #            (module-level glob) so React Flow doesn't remount every render
}
```

## Task 4 — `client/AgentNode.jac`

```jac
import from "@xyflow/react" { Handle, Position }

glob KIND_ICONS: dict = {"Trigger": "⚡", "Router": "🔀", "WorkerAgent": "🤖", "Aggregator": "🧩"};

def:pub AgentNode(data: any) -> JsxElement {
    # card: icon + node_name; border color by kind; small type caption
    # <Handle type="target" position={Position.Left}/> (omit for Trigger)
    # <Handle type="source" position={Position.Right}/> (omit for Aggregator)
}
```

## Task 5 — `client/NodeInspector.jac`

Fixed-position right overlay (width ~420px). Content, looked up from
`workflow["nodes"]` by `node_id`:

- Header: `node_name` + type badge + close button (`on_close`).
- `fixed_role_description` — read-only, labeled "Role (guardrail — RL cannot change this)".
- If `prompt_config` is not null:
  - Textarea bound to `prompt_config["system_prompt"]`; on change call
    `on_update_prompt(node_id, value)`.
  - Version badge: `v{prompt_config["prompt_version"]}` — this ticking up during training is a
    demo beat.
- Read-only `<pre>` blocks: `expected_input_schema`, `expected_output_schema` (JSON.stringify via
  `json` interop or simple str()).

## Task 6 — `client/TrainingConsole.jac` (chrome only — loop lands in Phase 4)

- Dataset textarea prefilled with the JSON of `DEMO_DATASET` (editable).
- Buttons: `Run Once`, `Train`, `Stop` — this phase they only `append_log("info", ...)`
  placeholders; disable Train/Run while `running`.
- Log list: scrollable, monospace; color per `kind` (walker=default, score=green,
  mutation=amber, error=red).
- `last_output` display panel under the buttons.

## Task 7 — Rewire entry & delete the guestbook

- `main.jac`: `cl` block imports and renders `<AppShell/>`; remove `CanvasSpike` usage and the
  guestbook `Message/PostMessage/ListMessages` import (Phase 3 replaces the server import list).
- Delete `frontend.cl.jac`, `frontend.impl.jac`, `components/MessageCard.jac` (guestbook).
  Keep `endpoints.sv.jac` untouched until Phase 3 replaces the import (a registered-but-unused
  walker is harmless for one hour; an unregistered import is a compile error).
- `jac check .` then `pkill -f "jac start"; jac start --dev main.jac < /dev/null` and QA via
  `jac browse open localhost:8000` → `snapshot` → `screenshot`.

---

## Phase gate (all must pass before Phase 3)

- [ ] Triage graph (5 nodes, 4 edges, route labels) renders from `DEMO_WORKFLOW`
- [ ] Clicking a node opens the Inspector; editing the prompt updates `workflow` state
      (re-open Inspector → edited text persists)
- [ ] Dragging a node persists position into `workflow["nodes"][i]["ui"]["position"]`
- [ ] Console chrome renders: dataset textarea, three buttons, styled log list
- [ ] Guestbook client code deleted; `jac check .` green
- [ ] `context.md` updated: phase 2 complete
