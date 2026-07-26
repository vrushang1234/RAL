# Phase 4 (Hour 4) — `train_step`, Mock RL Loop, Payload Logging

> Self-contained execution spec. Architecture: [DESIGN.md](../DESIGN.md).
> Prior state (Phases 1–3): `run_single` works end-to-end from the UI; engine lives in `engine/`
> (`build_graph`, `TaskWalker`, `PromptRehydrator`, `to_agent_states`, `to_updated_nodes`);
> `rl_bridge.py` wraps `mock_rl.optimize`; client shell (`client/AppShell.jac`) owns `workflow`,
> `logs`, `running` and has an `apply_updated_nodes(updated: list)` callback stub.

## Context you must know

- **D2 lifecycle** for `train_step`: HYDRATE → EXECUTE → EVALUATE (RL) → MUTATE → SERIALIZE, all
  inside one request; graph discarded after. The client applies `updated_nodes` to its
  WorkflowDefinition, so the NEXT request naturally carries mutated prompts.
- **D3**: RL responses can be slow (10–30 s) and can fail — failures must surface as console log
  entries, never crash the endpoint. Every payload/response pair is logged to `runs/` (debugging +
  demo replay insurance).
- **D6**: the CLIENT drives the training loop (epochs × dataset pairs); no SSE/WebSockets.
- **D9**: mutations write `prompt_config.system_prompt` and bump `prompt_version`.
- Mock behavior (from Phase 1's `mock_rl.py`): appends " Be more concise and specific." to the
  first WorkerAgent's prompt, score 0.42 — designed so the loop visibly mutates state.

## Jac syntax rules (verified)

1. Python interop: `import from rl_bridge { optimize }` works directly (`.py` beside `.jac`).
   Untyped Python returns are `any` → narrow with `response as dict` before typed use (E1001).
2. `import from uuid { uuid4 }`, `import json;`, `import os;`, `import from datetime { datetime }`
   all work (stdlib fully stubbed).
3. Every new `def:pub` MUST be added to `main.jac`'s import list (else 405).
4. Server-module changes need a FULL restart: `pkill -f "jac start"` then
   `jac start --dev main.jac < /dev/null`.
5. Client: `await` every `sv import`ed call; reassignment of `has` state triggers re-render.

## Guides to refresh

```bash
jac guide jac-python-interop
jac guide jac-fullstack-patterns
```

---

## Task 1 — `engine/rl.jac`

```jac
import json;
import os;
import from datetime { datetime }
import from rl_bridge { optimize }

def call_rl(payload: dict) -> dict {
    return optimize(payload) as dict;
}

def log_run(payload: dict, response: dict) -> None {
    os.makedirs("runs", exist_ok=True);
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S%f");
    with open(os.path.join("runs", stamp + ".json"), "w") as f {
        f.write(json.dumps({"payload": payload, "response": response}, indent=2));
    }
}
```

(If `with open(...)` isn't supported syntax per `jac guide jac-core-cheatsheet`, use
`f = open(...); f.write(...); f.close();` — check the guide, don't guess.)

## Task 2 — `engine/endpoints.jac`: add `train_step`

```jac
import from uuid { uuid4 }
import from .rl { call_rl, log_run }
import from .rehydrate { PromptRehydrator }
import from .serialize { to_agent_states, to_updated_nodes }

def:pub train_step(workflow: dict, initial_input: str, expected_ground_truth: str) -> dict {
    # 1. HYDRATE + EXECUTE (identical to run_single, including the SKIPPED diff)
    g = build_graph(workflow);
    w = g.entry_node spawn TaskWalker(initial_input=initial_input,
                                      all_node_ids=list(g.nodes_by_id.keys()));
    trace = ...;  # w.execution_trace + SKIPPED diff (factor a shared helper out of run_single:
                  # def execute_workflow(workflow: dict, input_text: str) -> (BuiltGraph, TaskWalker, list))

    # 2. BUILD PAYLOAD (schemas/workflow_execution_payload.json)
    payload = {
        "workflow_run_id": str(uuid4()),
        "task_context": {
            "initial_input": initial_input,
            "expected_ground_truth": expected_ground_truth,
            "actual_final_output": w.final_output
        },
        "agent_states": to_agent_states(g),
        "edges": [{"source": e["source_node_id"], "target": e["target_node_id"]}
                  for e in workflow["edges"]],
        "execution_trace": trace
    };

    # 3. EVALUATE — RL failures return, never raise
    try {
        response = call_rl(payload);
    } except Exception as e {
        return {"error": "RL engine failed: " + str(e), "execution_trace": trace,
                "critic_score": 0.0, "analysis_log": "", "prompt_mutations": [],
                "updated_nodes": [], "failed": True};
    }
    log_run(payload, response);

    # 4. MUTATE — walker first (rubric story), then defensive completeness loop
    muts = {m["node_id"]: m["new_sem_prompt"] for m in response["prompt_mutations"]};
    r = g.entry_node spawn PromptRehydrator(mutations=muts);
    for (nid, new_prompt) in muts.items() {
        if nid not in r.applied {
            fn = g.nodes_by_id[nid];
            fn.prompt_config["system_prompt"] = new_prompt;
            fn.prompt_config["prompt_version"] = fn.prompt_config.get("prompt_version", 1) + 1;
        }
    }

    # 5. SERIALIZE
    return {"critic_score": response["critic_score"],
            "analysis_log": response["analysis_log"],
            "prompt_mutations": response["prompt_mutations"],
            "updated_nodes": to_updated_nodes(g),
            "execution_trace": trace,
            "failed": w.failed};
}
```

Refactor note: extract the shared HYDRATE+EXECUTE+SKIPPED-diff block from `run_single` into a
helper `def _execute(...)` (underscore prefix keeps it OFF the API) so both endpoints stay small.

Register in `main.jac`: `import from engine.endpoints { run_single, train_step }`. Full server
restart afterwards.

## Task 3 — Client training loop (`client/TrainingConsole.jac`)

```jac
sv import from engine.endpoints { run_single, train_step }

async def start_training() {
    set_running(True);
    for pair in dataset {
        append_log("info", "=== pair: " + pair["initial_input"][:60] + "… ===");
        for epoch in range(3) {
            if not is_running() { set_running(False); return; }
            append_log("info", f"[train_step] epoch {epoch + 1} running…");
            result = await train_step(workflow=current_workflow(),
                                      initial_input=pair["initial_input"],
                                      expected_ground_truth=pair["expected_ground_truth"]);
            if "error" in result and result["error"] {
                append_log("error", result["error"]);
                continue;
            }
            append_log("score", f"critic_score = {result['critic_score']}");
            append_log("info", result["analysis_log"]);
            for m in result["prompt_mutations"] {
                append_log("mutation", "[PromptRehydrator] " + m["node_id"] + " → new prompt applied");
            }
            apply_updated_nodes(result["updated_nodes"]);   # AppShell writes prompt_configs back
            if result["critic_score"] >= 0.9 {
                append_log("score", "target score reached — stopping pair");
                break;
            }
        }
    }
    set_running(False);
}
```

Loop-state subtlety: the loop must read the LATEST `workflow` each iteration (after
`apply_updated_nodes`), not a closure-captured stale copy — hence `current_workflow()` as a
callback prop from AppShell (or lift `start_training` into AppShell itself, which owns the state;
prefer lifting if prop-threading gets awkward).

Stop button: sets the shared `running` flag false; the loop checks it before each step.

Wire `Run Once` (from Phase 3) and `Train`/`Stop` to their handlers; disable buttons while running.

## Task 4 — Inspector version-bump verification

No new code — verify behavior: after one Train click, open the mutated worker's Inspector and
confirm the textarea shows the appended " Be more concise and specific." and the badge reads `v2`.
If the badge still says `v1`, the bug is in `apply_updated_nodes` (must replace the whole
`prompt_config` dict of the matching node AND reassign `workflow` for re-render).

---

## Phase gate (all must pass before Phase 5)

- [ ] Train (mock): score/analysis/mutation lines stream into the console per step
- [ ] Mutated prompt visible in Inspector with `v2` WITHOUT page refresh
- [ ] `runs/` contains one JSON file per train step with full payload + response
- [ ] Next Run Once uses the mutated prompt (check `input_received`/behavior in trace)
- [ ] Stop button interrupts mid-loop; buttons disabled while running
- [ ] RL failure path tested once (temporarily raise in `mock_rl.py` → red console line, no crash)
- [ ] `jac check .` green; `context.md` updated: phase 4 complete
