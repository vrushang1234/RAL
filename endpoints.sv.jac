"""Public API: run_single + train_step + workflow library CRUD."""

import from uuid { uuid4 }
import from engine.builder { build_graph, BuiltGraph }
import from engine.task_walker { TaskWalker }
import from engine.nodes { FlowNode }
import from engine.rl { call_rl, log_run }
import from engine.rehydrate { PromptRehydrator }
import from engine.serialize { to_agent_states, to_updated_nodes }
import from engine.flow_grammar { validate_flow }
import from engine.workflow_library {
    list_workflows as _list_workflows,
    get_workflow as _get_workflow,
    save_workflow as _save_workflow,
    delete_workflow as _delete_workflow
}

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
