# Phase 3 (Hour 3) — Jac Engine: Graph, TaskWalker, byLLM, `run_single`

> Self-contained execution spec. Architecture: [DESIGN.md](../DESIGN.md).
> Prior state (Phases 1–2): schemas in `schemas/`, `rl_bridge.py` mock working, client shell in
> `client/` renders the triage demo workflow (`client/demo_workflow.jac` `DEMO_WORKFLOW`), and the
> client owns the WorkflowDefinition dict as source of truth (D2).

## Context you must know

- **D1 (prompt-as-parameter):** byLLM semstrings are static; the mutable prompt is node data
  (`prompt_config.system_prompt`) passed as an ARGUMENT to one generic `by llm()` function.
- **D2 (stateless):** the workflow graph lives only inside a request. CRITICAL JAC TRAP: nodes
  attached to `root` PERSIST across requests in the serve runtime. Therefore the workflow graph
  must NEVER touch `root` — spawn nodes standalone, interconnect with edges, spawn walkers
  directly on the entry node (`entry_node spawn TaskWalker(...)`).
- **D5:** Router activates exactly ONE outgoing `ROUTE_VALUE` edge. Non-visited nodes are recorded
  `SKIPPED` post-traversal.
- **D8:** LLM failure aborts the walk (`disengage`), node marked FAILED.
- **D10:** JSONPath subset — only `$` and `$.dotted.path`.
- **D11:** tools/skills/TOOL_LOOP/per-node models: parsed, never executed.
- **D12:** aggregator `required_upstream_node_ids` = intersection with actually-activated nodes.

## Jac syntax rules (verified via `jac guide` — non-negotiable)

1. byLLM: `import from jaclang.byllm.lib { Model }`; descriptions via `sem`, NEVER docstrings
   (W0060). `by llm(...)` REPLACES the body — never write both. Typed obj returns auto-retry
   malformed output (`max_output_retries` default 3).
2. Walker: state via `has`; `visit [-->]` (statement, not method); edge objects via
   `[edge here -->]`; typed-edge traversal `[here ->:FlowEdge:->]` with predicate
   `[here ->:FlowEdge:route_value == x:->]`; `skip;` = early return of current ability;
   `disengage;` = halt walker. Read results off walker `has` fields after
   `w = node spawn Walker(...)`.
3. Typed edges: `edge FlowEdge: FlowNode --> FlowNode { has ...; }` — declaring endpoint types
   makes traversals infer `FlowNode`. Create with `+>:FlowEdge(field=val):+>` — constructor
   parens ONLY (the `+>:E:field=val:+>` colon form silently drops values).
4. `++>` returns the connected node. `root` is a value, `Root` is the type.
5. `def:pub` endpoint functions: every name MUST be in `main.jac`'s plain
   `import from ... { ... }` list or callers get 405. Return dicts auto-serialize.
6. Python interop: `import json;` works directly. Untyped Python returns are `any` → cast
   `x as dict` before typed use (E1001).
7. `jac check .` after every file; follow `-> run 'jac guide ...'` hints in errors.

## Guides to load FIRST (in this order)

```bash
jac guide jac-core-cheatsheet
jac guide jac-types
jac guide jac-has-fields
jac guide jac-node-edge-patterns
jac guide jac-walker-patterns
jac guide jac-by-llm
jac guide jac-sv-endpoints
```

---

## Step 1 — D1 validation gate (DO THIS FIRST, ~15 min budget)

Create `scripts/validate_d1.jac`:

```jac
import from jaclang.byllm.lib { Model }

glob llm: Model = Model(model_name="gpt-4o-mini");

def run_agent(role_description: str, instructions: str, input_json: str) -> str by llm();
sem run_agent = "Act according to the given role and follow the instructions to transform the input.";
sem run_agent.role_description = "The agent's fixed role. Always stay within this role.";
sem run_agent.instructions = "The task instructions to follow exactly.";
sem run_agent.input_json = "The input data to transform (JSON or plain text).";

with entry {
    a = run_agent("You are a helpful assistant.", "Respond in French.", "Hello, how are you?");
    b = run_agent("You are a helpful assistant.", "Respond in ALL UPPERCASE.", "Hello, how are you?");
    print("A:", a);
    print("B:", b);
}
```

`jac run scripts/validate_d1.jac`. PASS = outputs follow their respective instructions.
FAIL = fall back per DESIGN D1: implement `run_agent` as a plain Jac function calling the OpenAI
SDK via Python interop (same signature) and continue immediately — the rest of the phase is
unchanged either way.

## Step 2 — `engine/llm.jac`

```jac
import from jaclang.byllm.lib { Model }

glob llm: Model = Model(model_name="gpt-4o-mini");

obj RouteChoice {
    has route: str;
    has reason: str;
}
sem RouteChoice.route = "Exactly one of the provided option names, verbatim.";
sem RouteChoice.reason = "One short sentence explaining the choice.";

def run_agent(role_description: str, instructions: str, input_json: str) -> str by llm();
sem run_agent = "Act according to the given role and follow the instructions to transform the input.";
sem run_agent.role_description = "The agent's fixed role. Always stay within this role.";
sem run_agent.instructions = "The task instructions to follow exactly.";
sem run_agent.input_json = "The input data to transform (JSON or plain text).";

def run_router(instructions: str, input_json: str, options: list[str]) -> RouteChoice by llm();
sem run_router = "Choose exactly one route from options that best fits the input.";
sem run_router.instructions = "Guidance on how to classify.";
sem run_router.input_json = "The input to classify.";
sem run_router.options = "The allowed route names. The answer MUST be one of these.";
```

Structured `RouteChoice` return means NO JSON parsing of router output — byLLM validates/retries.

## Step 3 — `engine/nodes.jac`

```jac
node FlowNode {
    has node_id: str;
    has node_name: str;
    has kind: str;                       # "Trigger" | "Router" | "WorkerAgent" | "Aggregator"
    has fixed_role_description: str = "";
    has prompt_config: dict = {};        # {} where the schema has null (Trigger)
    has expected_input_schema: dict = {};
    has expected_output_schema: dict = {};
    has type_config: dict = {};
    has enabled: bool = True;
}

edge FlowEdge: FlowNode --> FlowNode {
    has edge_id: str = "";
    has condition_type: str = "ALWAYS";  # "ALWAYS" | "ROUTE_VALUE" | "ON_SUCCESS"
    has route_value: str = "";
    has mapping_source: str = "$";
    has mapping_target: str = "$";
}
```

Design note: ONE node archetype with a `kind` discriminator (not four subtypes) — all behavior is
data-driven, so the walker dispatches with if/elif and GraphBuilder stays a simple loop.

## Step 4 — `engine/jsonpath.jac` (D10 subset)

```jac
def path_get(data: dict, path: str) -> any {
    # "$"        -> data
    # "$.a.b.c"  -> data["a"]["b"]["c"]; missing key at any hop -> {}
}

def path_set(data: dict, path: str, value: any) -> dict {
    # "$"        -> value must be a dict; return it
    # "$.a.b"    -> ensure data["a"] exists as dict, set data["a"]["b"] = value; return data
}
```

Implementation: strip leading `"$"`, split remainder on `"."` ignoring empties, loop the key
chain. ~20 lines. Unit-sanity in a `with entry` block of a scratch script, then delete the script.

## Step 5 — `engine/builder.jac`

```jac
import from .nodes { FlowNode, FlowEdge }

obj BuiltGraph {
    has entry_node: FlowNode;
    has nodes_by_id: dict = {};          # node_id -> FlowNode
    has output_node_id: str = "";
}

def build_graph(workflow: dict) -> BuiltGraph {
    # nodes_by_id = {}
    # for n in workflow["nodes"]:
    #     pc = n["prompt_config"] if n["prompt_config"] else {}
    #     fn = FlowNode(node_id=n["node_id"], node_name=n["node_name"], kind=n["type"],
    #                   fixed_role_description=n["fixed_role_description"],
    #                   prompt_config=pc,
    #                   expected_input_schema=n["expected_input_schema"],
    #                   expected_output_schema=n["expected_output_schema"],
    #                   type_config=n["type_config"], enabled=n["enabled"]);
    #     nodes_by_id[n["node_id"]] = fn;        # NOTE: never `root ++> fn` (D2!)
    # for e in workflow["edges"]:
    #     src = nodes_by_id[e["source_node_id"]]; tgt = nodes_by_id[e["target_node_id"]];
    #     rv = e["condition"]["route_value"] if e["condition"]["route_value"] else "";
    #     src +>:FlowEdge(edge_id=e["edge_id"], condition_type=e["condition"]["type"],
    #                     route_value=rv, mapping_source=e["data_mapping"]["source"],
    #                     mapping_target=e["data_mapping"]["target"]):+> tgt;
    # return BuiltGraph(entry_node=nodes_by_id[workflow["entry_node_id"]],
    #                   nodes_by_id=nodes_by_id, output_node_id=workflow["output_node_id"]);
}
```

## Step 6 — `engine/task_walker.jac` (the core)

```jac
import json;
import from .nodes { FlowNode, FlowEdge }
import from .llm { run_agent, run_router }
import from .jsonpath { path_get, path_set }

walker TaskWalker {
    has initial_input: str = "";
    has all_node_ids: list = [];
    has visited_ids: list = [];
    has execution_trace: list = [];       # entries per schemas/workflow_execution_payload.json
    has step_counter: int = 0;
    has failed: bool = False;
    has final_output: str = "";
    has node_inputs: dict = {};           # node_id -> input dict (filled by upstream before visit)
    has upstream_outputs: dict = {};      # worker node_id -> output str (aggregator input)

    can execute with FlowNode entry;
    can finish with FlowNode exit;        # only meaningful on the entry node; guard inside
}
```

`execute` ability logic (implement in `engine/task_walker.impl.jac` if the file grows):

1. Re-entry guard: `if here.node_id in self.visited_ids { skip; }` then append to `visited_ids`.
2. `input_received: dict = self.node_inputs.get(here.node_id, {"input": self.initial_input});`
3. Helper `def push(self_w: TaskWalker, from_node: FlowNode, only_route: str)` — for each outgoing
   edge object `e in [edge from_node -->]` (filtered: `ALWAYS`/`ON_SUCCESS` always pass; a
   `ROUTE_VALUE` edge passes only when `e.route_value == only_route`): build the target's input via
   `path_set(existing_target_input, e.mapping_target, path_get(current_payload, e.mapping_source))`,
   store into `self.node_inputs[target.node_id]`, and `visit` the target
   (`[from_node ->:FlowEdge:route_value == only_route:->]` for the routed case;
   plain `[from_node -->]` reads when unconditional). For `$.upstream_outputs.<id>` targets, merge
   into the target's accumulating input dict rather than overwrite.
4. Dispatch on `here.kind`:
   - **Trigger**: `payload = input_received;` trace EXECUTED (output = input); push unconditional.
   - **Router**: `options = [e.route_value for e in [edge here -->] if e.condition_type == "ROUTE_VALUE"];`
     try `choice = run_router(here.prompt_config["system_prompt"], json.dumps(input_received), options);`
     trace EXECUTED with `output_generated = json.dumps({"route": choice.route, "reason": choice.reason})`;
     push with `only_route = choice.route`.
   - **WorkerAgent**: try `out = run_agent(here.fixed_role_description,
     here.prompt_config["system_prompt"], json.dumps(input_received));`
     `self.upstream_outputs[here.node_id] = out;` trace EXECUTED; push unconditional
     (`ON_SUCCESS` edges).
   - **Aggregator**: D12 gate — `required = [r for r in here.type_config["aggregator"]["required_upstream_node_ids"] if r in self.visited_ids];`
     if any required id lacks an entry in `upstream_outputs` → `skip;` (it will be re-visited by
     the other branch; with single-branch routing this fires at most once). Else
     `out = run_agent(here.fixed_role_description, here.prompt_config["system_prompt"], json.dumps(self.upstream_outputs));`
     `self.final_output = out;` trace EXECUTED.
5. Failure handling (D8): each `run_agent`/`run_router` in try/except — on exception append trace
   `{"step": ..., "node_id": here.node_id, "status": "FAILED", "input_received": json.dumps(input_received),
   "output_generated": "", "error_message": str(e)}`, set `self.failed = True`, `disengage;`.
6. Trace entry shape for success:
   `{"step": self.step_counter, "node_id": here.node_id, "status": "EXECUTED",
   "input_received": json.dumps(input_received), "output_generated": out, "error_message": ""}`
   (increment `step_counter` first).
7. `finish` exit ability: guard `if here.node_id == self.all_node_ids[0]`-style is fragile —
   instead run the SKIPPED diff when the walker's queue drains: put it in
   `can finish with FlowNode exit` on the ENTRY node only
   (`if here.node_id != self.entry_id { skip; }` with `has entry_id: str = "";` set at spawn), or
   simpler: do the diff in the endpoint AFTER spawn returns (recommended — walkers expose state on
   `has` fields; the endpoint appends SKIPPED entries for `all_node_ids - visited_ids`). Choose the
   endpoint-side diff; delete `finish` if unused.

## Step 7 — `engine/rehydrate.jac` + `engine/serialize.jac`

```jac
# rehydrate.jac
import from .nodes { FlowNode }

walker PromptRehydrator {
    has mutations: dict = {};            # node_id -> new_sem_prompt
    has applied: list = [];

    can apply with FlowNode entry {
        if here.node_id in self.applied { skip; }
        if here.node_id in self.mutations {
            here.prompt_config["system_prompt"] = self.mutations[here.node_id];
            here.prompt_config["prompt_version"] = here.prompt_config.get("prompt_version", 1) + 1;
            self.applied.append(here.node_id);
        }
        visit [-->];
    }
}
```

Caller responsibility (Phase 4): after spawning on entry, loop `nodes_by_id` and apply any
mutation the walker missed (defensive completeness — traversal reaches everything reachable, the
loop guarantees the rest).

```jac
# serialize.jac
import json;
import from .builder { BuiltGraph }

def to_agent_states(g: BuiltGraph) -> list {
    # per FlowNode: {"node_id", "agent_name": node_name, "type": kind, "fixed_role_description",
    #  "expected_input": json.dumps(expected_input_schema),
    #  "expected_output": json.dumps(expected_output_schema),
    #  "current_sem_prompt": prompt_config.get("system_prompt", "")}   # D9 mapping
}

def to_updated_nodes(g: BuiltGraph) -> list {
    # [{"node_id": id, "prompt_config": fn.prompt_config} for nodes with non-empty prompt_config]
}
```

## Step 8 — `engine/endpoints.jac` + `main.jac` wiring

```jac
import from .builder { build_graph }
import from .task_walker { TaskWalker }
import json;

def:pub run_single(workflow: dict, input_text: str) -> dict {
    g = build_graph(workflow);
    w = g.entry_node spawn TaskWalker(initial_input=input_text,
                                      all_node_ids=list(g.nodes_by_id.keys()));
    trace = w.execution_trace;
    for nid in g.nodes_by_id.keys() {
        if nid not in w.visited_ids {
            trace.append({"step": len(trace) + 1, "node_id": nid, "status": "SKIPPED",
                          "input_received": "", "output_generated": "", "error_message": ""});
        }
    }
    return {"final_output": w.final_output, "execution_trace": trace, "failed": w.failed};
}
```

`main.jac` server imports become: `import from engine.endpoints { run_single }` — REMOVE the
guestbook `import from endpoints { ... }` line and delete `endpoints.sv.jac`.

## Step 9 — Client wiring (`client/TrainingConsole.jac`)

```jac
sv import from engine.endpoints { run_single }

async def handle_run_once() {
    running = True;  append_log("info", "[run_single] starting…");
    result = await run_single(workflow=workflow, input_text=dataset[0]["initial_input"]);
    for t in result["execution_trace"] {
        # "[TaskWalker] → {node_name or node_id} {status}" (+ router reason when present)
        append_log("walker", ...);
    }
    last_output = result["final_output"];
    running = False;
}
```

(`running`/`last_output` live in AppShell — pass setter callbacks down, per Phase 2 shell design.)

---

## Phase gate (all must pass before Phase 4)

- [ ] `jac run scripts/validate_d1.jac` shows instruction-following (or documented SDK fallback)
- [ ] Run Once from the UI on the billing email → router picks `billing`, `worker_technical`
      shows SKIPPED in trace, aggregator output renders in the console
- [ ] Run Once on the technical email → routes `technical`
- [ ] Server restart between runs shows NO leftover graph state (proves detached-from-root)
- [ ] Guestbook `endpoints.sv.jac` deleted; `jac check .` green
- [ ] `context.md` updated: phase 3 complete, D1 result noted
