"""Serialize BuiltGraph into RL payload agent_states / client updated_nodes."""

import json;
import from .builder { BuiltGraph }
import from .nodes { FlowNode }

def to_agent_states(g: BuiltGraph) -> list {
    states: list = [];
    for (nid, fn_any) in g.nodes_by_id.items() {
        fn = fn_any as FlowNode;
        prompt = "";
        if "system_prompt" in fn.prompt_config {
            prompt = str(fn.prompt_config["system_prompt"]);
        }
        states = states + [{
            "node_id": fn.node_id,
            "agent_name": fn.node_name,
            "type": fn.kind,
            "fixed_role_description": fn.fixed_role_description,
            "expected_input": json.dumps(fn.expected_input_schema),
            "expected_output": json.dumps(fn.expected_output_schema),
            "current_sem_prompt": prompt
        }];
    }
    return states;
}

def to_updated_nodes(g: BuiltGraph) -> list {
    updated: list = [];
    for (nid, fn_any) in g.nodes_by_id.items() {
        fn = fn_any as FlowNode;
        if fn.prompt_config {
            updated = updated + [{
                "node_id": fn.node_id,
                "prompt_config": fn.prompt_config
            }];
        }
    }
    return updated;
}
