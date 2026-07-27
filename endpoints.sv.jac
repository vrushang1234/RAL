"""Public API: run_single + train_step + eval_cell + workflow library CRUD."""

import json;
import from uuid { uuid4 }
import from engine.builder { build_graph, BuiltGraph }
import from engine.task_walker { TaskWalker }
import from engine.nodes { FlowNode }
import from engine.rl { call_rl, log_run, log_eval_report as _log_eval_report }
import from engine.rehydrate { PromptRehydrator }
import from engine.serialize { to_agent_states, to_updated_nodes }
import from engine.flow_grammar { validate_flow }
import from engine.workflow_library {
    list_workflows as _list_workflows,
    get_workflow as _get_workflow,
    save_workflow as _save_workflow,
    delete_workflow as _delete_workflow
}
import from rl.bridge { read_trace, critic_score }

obj ExecResult {
    has graph: BuiltGraph;
    has walker: TaskWalker;
    has trace: list = [];
}

def _execute(workflow: dict, input_text: str) -> ExecResult {
    g: BuiltGraph = build_graph(workflow);
    id_list: list = [];
    for nid in g.nodes_by_id.keys() {
        id_list = id_list + [str(nid)];
    }
    w = g.entry_node spawn TaskWalker(
        initial_input=input_text,
        all_node_ids=id_list,
        nodes_by_id=g.nodes_by_id
    );
    trace: list = w.execution_trace;
    for nid in id_list {
        if nid not in w.visited_ids {
            trace = trace + [{
                "step": len(trace) + 1,
                "node_id": nid,
                "status": "SKIPPED",
                "input_received": "",
                "output_generated": "",
                "error_message": ""
            }];
        }
    }
    return ExecResult(graph=g, walker=w, trace=trace);
}

def:pub run_single(workflow: dict, input_text: str) -> dict {
    v = validate_flow(workflow);
    if not v["ok"] {
        return {
            "final_output": "",
            "execution_trace": [],
            "failed": True,
            "visited_ids": [],
            "error": "invalid flow: " + str(v["errors"])
        };
    }
    ex: ExecResult = _execute(workflow, input_text);
    return {
        "final_output": ex.walker.final_output,
        "execution_trace": ex.trace,
        "failed": ex.walker.failed,
        "visited_ids": ex.walker.visited_ids,
        "error": ""
    };
}

def:pub train_step(workflow: dict, initial_input: str, expected_ground_truth: str) -> dict {
    v = validate_flow(workflow);
    if not v["ok"] {
        return {
            "error": "invalid flow: " + str(v["errors"]),
            "execution_trace": [],
            "critic_score": 0.0,
            "analysis_log": "",
            "prompt_mutations": [],
            "updated_nodes": [],
            "failed": True
        };
    }
    ex: ExecResult = _execute(workflow, initial_input);
    g = ex.graph;
    w = ex.walker;
    trace = ex.trace;

    edge_list: list = [];
    for e in (workflow["edges"] as list) {
        edge_list = edge_list + [{
            "source": str(e["source_node_id"]),
            "target": str(e["target_node_id"])
        }];
    }

    payload: dict = {
        "workflow_run_id": str(uuid4()),
        "task_context": {
            "initial_input": initial_input,
            "expected_ground_truth": expected_ground_truth,
            "actual_final_output": w.final_output
        },
        "agent_states": to_agent_states(g),
        "edges": edge_list,
        "execution_trace": trace
    };

    response: dict = {};
    try {
        response = call_rl(payload);
    } except Exception as err {
        return {
            "error": "RL engine failed: " + str(err),
            "execution_trace": trace,
            "critic_score": 0.0,
            "analysis_log": "",
            "prompt_mutations": [],
            "updated_nodes": [],
            "failed": True
        };
    }
    log_run(payload, response);

    muts: dict = {};
    raw_muts: list = response["prompt_mutations"] as list if response["prompt_mutations"] else [];
    for m in raw_muts {
        md = m as dict;
        muts[str(md["node_id"])] = str(md["new_sem_prompt"]);
    }

    r = g.entry_node spawn PromptRehydrator(mutations=muts);
    for (nid, new_prompt) in muts.items() {
        if nid not in r.applied {
            if nid in g.nodes_by_id {
                fn = g.nodes_by_id[nid] as FlowNode;
                pc: dict = fn.prompt_config;
                ver = 1;
                if "prompt_version" in pc {
                    ver = int(pc["prompt_version"]) + 1;
                }
                fn.prompt_config = {
                    "prompt_id": pc["prompt_id"] if "prompt_id" in pc else "",
                    "prompt_version": ver,
                    "system_prompt": str(new_prompt),
                    "user_prompt_template": pc["user_prompt_template"] if "user_prompt_template" in pc else "",
                    "output_instructions": pc["output_instructions"] if "output_instructions" in pc else "",
                    "variables": pc["variables"] if "variables" in pc else []
                };
            }
        }
    }

    return {
        "error": "",
        "critic_score": response["critic_score"],
        "analysis_log": str(response["analysis_log"]) if response["analysis_log"] else "",
        "prompt_mutations": raw_muts,
        "updated_nodes": to_updated_nodes(g),
        "execution_trace": trace,
        "failed": w.failed
    };
}

def:pub list_workflows() -> dict {
    return {"items": _list_workflows()};
}

def:pub get_workflow(workflow_id: str) -> dict {
    return _get_workflow(workflow_id);
}

def:pub save_workflow(workflow: dict) -> dict {
    return _save_workflow(workflow);
}

def:pub delete_workflow(workflow_id: str) -> dict {
    return _delete_workflow(workflow_id);
}

def:pub validate_workflow(workflow: dict) -> dict {
    return validate_flow(workflow);
}

def _route_from_trace(trace: list) -> str {
    for row_any in trace {
        row = row_any as dict;
        if str(row["status"]) != "EXECUTED" {
            continue;
        }
        out = str(row["output_generated"]) if row["output_generated"] else "";
        if not out {
            continue;
        }
        try {
            parsed: dict = json.loads(out) as dict;
            if parsed["route"] {
                return str(parsed["route"]);
            }
        } except Exception {
            continue;
        }
    }
    return "";
}

def _worker_hit(trace: list, expected_worker_id: str) -> bool {
    for row_any in trace {
        row = row_any as dict;
        if str(row["node_id"]) == expected_worker_id and str(row["status"]) == "EXECUTED" {
            return True;
        }
    }
    return False;
}

def _prompt_versions(workflow: dict) -> dict {
    out: dict = {};
    for n_any in (workflow["nodes"] as list) {
        n = n_any as dict;
        pc: any = n["prompt_config"] if n["prompt_config"] else None;
        ver = 0;
        if pc and pc["prompt_version"] {
            ver = int(pc["prompt_version"]);
        }
        out[str(n["node_id"])] = ver;
    }
    return out;
}

"""Score one matrix cell without mutating prompts (baseline / after passes)."""
def:pub eval_cell(
    workflow: dict,
    initial_input: str,
    expected_ground_truth: str,
    expected_route: str,
    expected_worker_id: str
) -> dict {
    v = validate_flow(workflow);
    if not v["ok"] {
        return {
            "error": "invalid flow: " + str(v["errors"]),
            "critic_score": 0.0,
            "final_output": "",
            "execution_trace": [],
            "route": "",
            "route_ok": False,
            "worker_hit": False,
            "prompt_versions": {},
            "failed": True
        };
    }
    ex: ExecResult = _execute(workflow, initial_input);
    facts = read_trace(ex.trace);
    score = critic_score(ex.walker.final_output, expected_ground_truth, facts);
    route = _route_from_trace(ex.trace);
    route_ok = route == expected_route and expected_route != "";
    hit = _worker_hit(ex.trace, expected_worker_id);
    return {
        "error": "",
        "critic_score": round(score, 4),
        "final_output": ex.walker.final_output,
        "execution_trace": ex.trace,
        "route": route,
        "route_ok": route_ok,
        "worker_hit": hit,
        "prompt_versions": _prompt_versions(workflow),
        "failed": ex.walker.failed
    };
}

def:pub log_eval_report(eval_report: dict) -> dict {
    return _log_eval_report(eval_report);
}
