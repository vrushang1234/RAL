"""Default node shells for canvas Add-* palette."""

def:pub make_node(kind: str, node_id: str, x: float, y: float) -> dict {
    name = kind;
    role = "";
    pc: any = None;
    tc: dict = {
        "trigger": None,
        "router": None,
        "worker": None,
        "aggregator": None
    };
    if kind == "Trigger" {
        name = "Inbound Email";
        role = "Accepts the raw support email as workflow input.";
        tc["trigger"] = {"trigger_type": "MANUAL", "config": {}};
    } elif kind == "Router" {
        name = "Triage Router";
        role = "You classify inbound support emails.";
        pc = {
            "prompt_id": "p_" + node_id,
            "prompt_version": 1,
            "system_prompt": "Decide if this email is about billing or technical issues.",
            "user_prompt_template": "{{workflow_input}}",
            "output_instructions": "Return the selected route.",
            "variables": ["workflow_input"]
        };
        tc["router"] = {
            "routing_mode": "LLM",
            "route_output_key": "route",
            "default_target_node_id": None
        };
    } elif kind == "WorkerAgent" {
        name = "Worker Agent";
        role = "You are a support specialist.";
        pc = {
            "prompt_id": "p_" + node_id,
            "prompt_version": 1,
            "system_prompt": "Reply.",
            "user_prompt_template": "{{node_input}}",
            "output_instructions": "Write the customer reply.",
            "variables": ["node_input"]
        };
        tc["worker"] = {"execution_mode": "TOOL_LOOP", "max_iterations": 5};
    } elif kind == "Aggregator" {
        name = "Final Reply";
        role = "You produce the final customer-ready reply.";
        pc = {
            "prompt_id": "p_" + node_id,
            "prompt_version": 1,
            "system_prompt": "Combine.",
            "user_prompt_template": "{{upstream_outputs}}",
            "output_instructions": "Produce the final workflow output.",
            "variables": ["upstream_outputs"]
        };
        tc["aggregator"] = {
            "strategy": "SUMMARIZE",
            "required_upstream_node_ids": [],
            "custom_instructions": None
        };
    }
    return {
        "node_id": node_id,
        "node_name": name,
        "type": kind,
        "enabled": True,
        "fixed_role_description": role,
        "expected_input_schema": {"type": "object", "additionalProperties": True},
        "expected_output_schema": {"type": "object", "additionalProperties": True},
        "prompt_config": pc,
        "model_config": {
            "provider": "google",
            "model": "gemini-2.5-flash",
            "temperature": 0.2,
            "top_p": 1,
            "max_output_tokens": 1500,
            "seed": None
        },
        "skill_bindings": [],
        "tool_bindings": [],
        "runtime_config": {
            "timeout_ms": 60000,
            "max_retries": 1,
            "retry_backoff_ms": 1000,
            "continue_on_failure": False
        },
        "type_config": tc,
        "ui": {"position": {"x": x, "y": y}, "width": 280, "height": 160, "collapsed": False}
    };
}

def:pub edge_allowed(src_kind: str, tgt_kind: str) -> bool {
    if src_kind == "Trigger" and tgt_kind == "Router" {
        return True;
    }
    if src_kind == "Router" and (tgt_kind == "WorkerAgent" or tgt_kind == "Router") {
        return True;
    }
    if src_kind == "WorkerAgent" and (
        tgt_kind == "WorkerAgent" or tgt_kind == "Router" or tgt_kind == "Aggregator"
    ) {
        return True;
    }
    return False;
}
