"""Demo WorkflowDefinition: support-email triage (Pattern B). Weak prompts intentional."""

glob:pub DEMO_WORKFLOW: dict = {
    "schema_version": "1.0.0",
    "workflow_id": "wf_demo_triage",
    "workflow_name": "Support Email Triage",
    "workflow_version": 1,
    "configuration_hash": None,
    "status": "DRAFT",
    "description": "Route inbound support email to billing or technical, then aggregate a reply.",
    "entry_node_id": "trigger_1",
    "output_node_id": "aggregator_1",
    "input_schema": {
        "type": "object",
        "additionalProperties": False,
        "properties": {"input": {"type": "string"}},
        "required": ["input"]
    },
    "output_schema": {
        "type": "object",
        "additionalProperties": False,
        "properties": {"output": {"type": "string"}},
        "required": ["output"]
    },
    "global_config": {
        "max_workflow_runtime_ms": 120000,
        "max_parallel_nodes": 4,
        "fail_fast": True,
        "context_config": {
            "mode": "SELECTIVE",
            "max_context_tokens": 16000,
            "include_upstream_outputs": True,
            "include_tool_outputs": True,
            "include_execution_history": False,
            "shared_memory_enabled": False
        },
        "observability_config": {
            "store_node_inputs": True,
            "store_node_outputs": True,
            "store_tool_inputs": True,
            "store_tool_outputs": True,
            "store_token_usage": True,
            "store_latency_metrics": True
        }
    },
    "tool_catalog": [],
    "skill_catalog": [],
    "nodes": [
        {
            "node_id": "trigger_1",
            "node_name": "Inbound Email",
            "type": "Trigger",
            "enabled": True,
            "fixed_role_description": "Accepts the raw support email as workflow input.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": None,
            "model_config": None,
            "skill_bindings": [],
            "tool_bindings": [],
            "runtime_config": {
                "timeout_ms": 30000,
                "max_retries": 0,
                "retry_backoff_ms": 0,
                "continue_on_failure": False
            },
            "type_config": {
                "trigger": {"trigger_type": "MANUAL", "config": {}},
                "router": None,
                "worker": None,
                "aggregator": None
            },
            "ui": {"position": {"x": 60, "y": 220}, "width": 280, "height": 160, "collapsed": False}
        },
        {
            "node_id": "router_1",
            "node_name": "Triage Router",
            "type": "Router",
            "enabled": True,
            "fixed_role_description": "You classify inbound support emails.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "route": {"type": "string"},
                    "reason": {"type": "string"}
                },
                "required": ["route"]
            },
            "prompt_config": {
                "prompt_id": "p_router",
                "prompt_version": 1,
                "system_prompt": "Decide if this email is about billing or technical issues.",
                "user_prompt_template": "{{workflow_input}}",
                "output_instructions": "Return the selected route.",
                "variables": ["workflow_input"]
            },
            "model_config": {
                "provider": "google",
                "model": "gemini-2.5-flash",
                "temperature": 0,
                "top_p": 1,
                "max_output_tokens": 300,
                "seed": None
            },
            "skill_bindings": [],
            "tool_bindings": [],
            "runtime_config": {
                "timeout_ms": 30000,
                "max_retries": 1,
                "retry_backoff_ms": 1000,
                "continue_on_failure": False
            },
            "type_config": {
                "trigger": None,
                "router": {
                    "routing_mode": "LLM",
                    "route_output_key": "route",
                    "default_target_node_id": None
                },
                "worker": None,
                "aggregator": None
            },
            "ui": {"position": {"x": 340, "y": 220}, "width": 280, "height": 200, "collapsed": False}
        },
        {
            "node_id": "worker_billing",
            "node_name": "Billing Agent",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You are a billing support specialist.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_billing",
                "prompt_version": 1,
                "system_prompt": "Reply.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the customer reply.",
                "variables": ["node_input"]
            },
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
                "max_retries": 2,
                "retry_backoff_ms": 1000,
                "continue_on_failure": False
            },
            "type_config": {
                "trigger": None,
                "router": None,
                "worker": {"execution_mode": "TOOL_LOOP", "max_iterations": 5},
                "aggregator": None
            },
            "ui": {"position": {"x": 640, "y": 100}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_technical",
            "node_name": "Technical Agent",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You are a technical support engineer.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_technical",
                "prompt_version": 1,
                "system_prompt": "Answer.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the customer reply.",
                "variables": ["node_input"]
            },
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
                "max_retries": 2,
                "retry_backoff_ms": 1000,
                "continue_on_failure": False
            },
            "type_config": {
                "trigger": None,
                "router": None,
                "worker": {"execution_mode": "TOOL_LOOP", "max_iterations": 5},
                "aggregator": None
            },
            "ui": {"position": {"x": 640, "y": 340}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "aggregator_1",
            "node_name": "Final Reply",
            "type": "Aggregator",
            "enabled": True,
            "fixed_role_description": "You produce the final customer-ready reply.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"output": {"type": "string"}},
                "required": ["output"]
            },
            "prompt_config": {
                "prompt_id": "p_aggregator",
                "prompt_version": 1,
                "system_prompt": "Combine.",
                "user_prompt_template": "{{upstream_outputs}}",
                "output_instructions": "Produce the final workflow output.",
                "variables": ["upstream_outputs"]
            },
            "model_config": {
                "provider": "google",
                "model": "gemini-2.5-flash",
                "temperature": 0.1,
                "top_p": 1,
                "max_output_tokens": 1200,
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
            "type_config": {
                "trigger": None,
                "router": None,
                "worker": None,
                "aggregator": {
                    "strategy": "SUMMARIZE",
                    "required_upstream_node_ids": ["worker_billing", "worker_technical"],
                    "custom_instructions": None
                }
            },
            "ui": {"position": {"x": 940, "y": 220}, "width": 300, "height": 220, "collapsed": False}
        }
    ],
    "edges": [
        {
            "edge_id": "e1",
            "source_node_id": "trigger_1",
            "target_node_id": "router_1",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$.input", "target": "$.workflow_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "e2",
            "source_node_id": "router_1",
            "target_node_id": "worker_billing",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "billing"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "billing"}
        },
        {
            "edge_id": "e3",
            "source_node_id": "router_1",
            "target_node_id": "worker_technical",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "technical"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "technical"}
        },
        {
            "edge_id": "e4a",
            "source_node_id": "worker_billing",
            "target_node_id": "aggregator_1",
            "condition": {"type": "ON_SUCCESS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.upstream_outputs.worker_billing"},
            "ui": {"label": None}
        },
        {
            "edge_id": "e4b",
            "source_node_id": "worker_technical",
            "target_node_id": "aggregator_1",
            "condition": {"type": "ON_SUCCESS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.upstream_outputs.worker_technical"},
            "ui": {"label": None}
        }
    ],
    "metadata": {
        "created_at": "2026-07-26T00:00:00Z",
        "updated_at": "2026-07-26T00:00:00Z",
        "created_by": "demo",
        "tags": ["demo", "triage"]
    }
};

glob:pub DEMO_DATASET: list = [
    {
        "initial_input": "Hi, I was charged twice for my subscription this month. Please refund one charge.",
        "expected_ground_truth": "Apologetic reply confirming the duplicate charge will be refunded within 5-7 business days, with a reference number."
    },
    {
        "initial_input": "The app crashes every time I try to export a PDF on macOS.",
        "expected_ground_truth": "Reply acknowledging the crash, asking for the app version and macOS version, and suggesting reinstall as an interim fix."
    }
];

# Labeled eval matrix for the RL testbench dashboard (category × difficulty).
glob:pub EVAL_MATRIX: list = [
    {
        "task_id": "bill_easy",
        "category": "billing",
        "difficulty": "easy",
        "initial_input": "Hi, I was charged twice for my subscription this month. Please refund one charge.",
        "expected_ground_truth": "Apologetic reply confirming the duplicate charge will be refunded within 5-7 business days, with a reference number.",
        "expected_route": "billing",
        "expected_worker_id": "worker_billing"
    },
    {
        "task_id": "bill_hard",
        "category": "billing",
        "difficulty": "hard",
        "initial_input": "You billed my corporate card ending 4412 three times for Pro seats I already cancelled last quarter. I need a full refund plus a credit memo before month close.",
        "expected_ground_truth": "Apologetic reply confirming the duplicate Pro seat charges will be refunded, issuing a credit memo, and providing a reference number within 5-7 business days.",
        "expected_route": "billing",
        "expected_worker_id": "worker_billing"
    },
    {
        "task_id": "tech_easy",
        "category": "technical",
        "difficulty": "easy",
        "initial_input": "The app crashes every time I try to export a PDF on macOS.",
        "expected_ground_truth": "Reply acknowledging the crash, asking for the app version and macOS version, and suggesting reinstall as an interim fix.",
        "expected_route": "technical",
        "expected_worker_id": "worker_technical"
    },
    {
        "task_id": "tech_hard",
        "category": "technical",
        "difficulty": "hard",
        "initial_input": "Export to PDF hangs at 47% on macOS Sequoia with our SSO build; Activity Monitor shows a beachball and Console logs a Metal shader fault. Need a workaround before Friday's board deck.",
        "expected_ground_truth": "Reply acknowledging the hang and Metal shader fault, asking for app version and macOS build, and suggesting reinstall plus a non-Metal interim export workaround before Friday.",
        "expected_route": "technical",
        "expected_worker_id": "worker_technical"
    },
    {
        "task_id": "bill_medium",
        "category": "billing",
        "difficulty": "medium",
        "initial_input": "I upgraded to annual billing but still see monthly invoices. Can you confirm the plan and refund any overcharge?",
        "expected_ground_truth": "Apologetic reply confirming the annual plan, explaining the invoice mix-up, and confirming any overcharge will be refunded with a reference number.",
        "expected_route": "billing",
        "expected_worker_id": "worker_billing"
    },
    {
        "task_id": "tech_medium",
        "category": "technical",
        "difficulty": "medium",
        "initial_input": "Login works in Chrome but Safari keeps saying session expired after SSO. Happens on both laptop and iPad.",
        "expected_ground_truth": "Reply acknowledging the Safari SSO session issue, asking for browser versions, and suggesting clearing site data plus an interim Chrome workaround.",
        "expected_route": "technical",
        "expected_worker_id": "worker_technical"
    }
];
