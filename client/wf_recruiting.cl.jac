"""Recruiting pipeline demo: role router → screener → skills chain → decision router (Worker→Router). Weak prompts intentional."""

glob:pub RECRUITING_WORKFLOW: dict = {
    "schema_version": "1.0.0",
    "workflow_id": "wf_recruiting",
    "workflow_name": "Recruiting Pipeline",
    "workflow_version": 1,
    "configuration_hash": None,
    "status": "DRAFT",
    "description": "Route an application by role, screen it, assess skills, then a decision router picks advance vs reject before the hiring packet is assembled.",
    "entry_node_id": "trigger_application",
    "output_node_id": "aggregator_packet",
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
            "node_id": "trigger_application",
            "node_name": "Application Intake",
            "type": "Trigger",
            "enabled": True,
            "fixed_role_description": "Accepts the raw job application as workflow input.",
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
            "ui": {"position": {"x": 60, "y": 280}, "width": 280, "height": 160, "collapsed": False}
        },
        {
            "node_id": "router_role",
            "node_name": "Role Router",
            "type": "Router",
            "enabled": True,
            "fixed_role_description": "You classify inbound job applications by role family.",
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
                "prompt_id": "p_role_router",
                "prompt_version": 1,
                "system_prompt": "Decide if this application is for an engineering or sales role.",
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
            "ui": {"position": {"x": 340, "y": 280}, "width": 280, "height": 200, "collapsed": False}
        },
        {
            "node_id": "worker_eng_screen",
            "node_name": "Engineering Screener",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You are an engineering recruiter screening a software candidate's application.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_eng_screen",
                "prompt_version": 1,
                "system_prompt": "Screen it.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the screening summary.",
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
            "ui": {"position": {"x": 620, "y": 120}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_sales_screen",
            "node_name": "Sales Screener",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You are a sales recruiter screening a go-to-market candidate's application.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_sales_screen",
                "prompt_version": 1,
                "system_prompt": "Screen it.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the screening summary.",
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
            "ui": {"position": {"x": 620, "y": 440}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_skills",
            "node_name": "Skills Assessor",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You assess the candidate's skills against the role bar and state a clear hire signal.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_skills",
                "prompt_version": 1,
                "system_prompt": "Assess.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the skills assessment with a clear recommendation.",
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
            "ui": {"position": {"x": 940, "y": 280}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "router_decision",
            "node_name": "Decision Router",
            "type": "Router",
            "enabled": True,
            "fixed_role_description": "You decide whether the candidate advances based on the skills assessment.",
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
                "prompt_id": "p_decision_router",
                "prompt_version": 1,
                "system_prompt": "Advance strong candidates; reject weak ones.",
                "user_prompt_template": "{{assessment}}",
                "output_instructions": "Return the selected route.",
                "variables": ["assessment"]
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
            "ui": {"position": {"x": 1260, "y": 280}, "width": 280, "height": 200, "collapsed": False}
        },
        {
            "node_id": "worker_interview_plan",
            "node_name": "Interview Plan Writer",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You design the onsite interview loop for an advancing candidate.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_interview_plan",
                "prompt_version": 1,
                "system_prompt": "Plan it.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the interview plan.",
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
            "ui": {"position": {"x": 1560, "y": 120}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_rejection",
            "node_name": "Rejection Writer",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You write a respectful, constructive rejection note for the candidate.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_rejection",
                "prompt_version": 1,
                "system_prompt": "Write it.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the rejection note.",
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
            "ui": {"position": {"x": 1560, "y": 440}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "aggregator_packet",
            "node_name": "Hiring Packet",
            "type": "Aggregator",
            "enabled": True,
            "fixed_role_description": "You assemble the final hiring packet summarizing the pipeline outcome.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"output": {"type": "string"}},
                "required": ["output"]
            },
            "prompt_config": {
                "prompt_id": "p_packet_agg",
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
                    "required_upstream_node_ids": ["worker_interview_plan", "worker_rejection"],
                    "custom_instructions": None
                }
            },
            "ui": {"position": {"x": 1880, "y": 280}, "width": 300, "height": 220, "collapsed": False}
        }
    ],
    "edges": [
        {
            "edge_id": "rec_e1",
            "source_node_id": "trigger_application",
            "target_node_id": "router_role",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$.input", "target": "$.workflow_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "rec_e2",
            "source_node_id": "router_role",
            "target_node_id": "worker_eng_screen",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "engineering"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "engineering"}
        },
        {
            "edge_id": "rec_e3",
            "source_node_id": "router_role",
            "target_node_id": "worker_sales_screen",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "sales"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "sales"}
        },
        {
            "edge_id": "rec_e4",
            "source_node_id": "worker_eng_screen",
            "target_node_id": "worker_skills",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "rec_e5",
            "source_node_id": "worker_sales_screen",
            "target_node_id": "worker_skills",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "rec_e6",
            "source_node_id": "worker_skills",
            "target_node_id": "router_decision",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.assessment"},
            "ui": {"label": None}
        },
        {
            "edge_id": "rec_e7",
            "source_node_id": "router_decision",
            "target_node_id": "worker_interview_plan",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "advance"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "advance"}
        },
        {
            "edge_id": "rec_e8",
            "source_node_id": "router_decision",
            "target_node_id": "worker_rejection",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "reject"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "reject"}
        },
        {
            "edge_id": "rec_e9",
            "source_node_id": "worker_interview_plan",
            "target_node_id": "aggregator_packet",
            "condition": {"type": "ON_SUCCESS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.upstream_outputs.worker_interview_plan"},
            "ui": {"label": None}
        },
        {
            "edge_id": "rec_e10",
            "source_node_id": "worker_rejection",
            "target_node_id": "aggregator_packet",
            "condition": {"type": "ON_SUCCESS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.upstream_outputs.worker_rejection"},
            "ui": {"label": None}
        }
    ],
    "metadata": {
        "created_at": "2026-07-26T00:00:00Z",
        "updated_at": "2026-07-26T00:00:00Z",
        "created_by": "demo",
        "tags": ["demo", "recruiting", "hiring"]
    }
};

glob:pub RECRUITING_DATASET: list = [
    {
        "initial_input": "Application for Senior Backend Engineer: 9 years building distributed systems in Go and Rust at two unicorns, led a team of 6, open-source maintainer of a popular gRPC library. Wants remote.",
        "expected_ground_truth": "Hiring packet recommending ADVANCE: screening summary highlighting distributed-systems depth and leadership, a skills assessment rating the candidate above the senior bar, and an onsite loop covering system design, coding, and leadership."
    },
    {
        "initial_input": "Application for Enterprise Account Executive: 1 year as an SDR, no closing experience, missed quota twice, applying for a role requiring 5+ years closing 6-figure SaaS deals.",
        "expected_ground_truth": "Hiring packet recommending REJECT: screening summary noting the closing-experience gap against the 5-year requirement, a skills assessment below the bar, and a respectful rejection note encouraging reapplication after more closing experience."
    },
    {
        "initial_input": "Application for Enterprise Account Executive: 8 years SaaS sales, 130% average quota attainment over the last 4 years, closed three 7-figure logos, built the EMEA territory from zero.",
        "expected_ground_truth": "Hiring packet recommending ADVANCE: screening summary highlighting consistent overattainment and 7-figure closes, a skills assessment above the enterprise bar, and an interview loop covering deal walkthroughs and territory planning."
    }
];

# Labeled eval matrix for the RL testbench dashboard (category x difficulty).
# expected_route is the FIRST router's choice (role family); expected_worker_id checks the decision branch.
glob:pub RECRUITING_EVAL_MATRIX: list = [
    {
        "task_id": "eng_advance_easy",
        "category": "engineering",
        "difficulty": "easy",
        "initial_input": "Application for Senior Backend Engineer: 9 years of distributed systems in Go and Rust, led a team of 6, maintainer of a popular gRPC library. Strong references.",
        "expected_ground_truth": "Hiring packet recommending ADVANCE with a screening summary, an above-bar skills assessment, and an onsite interview plan covering system design and coding.",
        "expected_route": "engineering",
        "expected_worker_id": "worker_interview_plan"
    },
    {
        "task_id": "eng_reject_medium",
        "category": "engineering",
        "difficulty": "medium",
        "initial_input": "Application for Senior Backend Engineer: 2 years of WordPress plugin work, no team or systems experience, applying for a role requiring deep distributed-systems expertise.",
        "expected_ground_truth": "Hiring packet recommending REJECT with a screening summary noting the experience gap, a below-bar skills assessment, and a respectful rejection note with constructive guidance.",
        "expected_route": "engineering",
        "expected_worker_id": "worker_rejection"
    },
    {
        "task_id": "eng_advance_hard",
        "category": "engineering",
        "difficulty": "hard",
        "initial_input": "Application for Staff Platform Engineer: unconventional background — 6 years in HFT infra (C++, kernel bypass networking), no cloud experience, but designed exchange systems handling 2M msgs/sec; role needs Kubernetes at scale.",
        "expected_ground_truth": "Hiring packet recommending ADVANCE despite the cloud gap: screening summary weighing transferable low-latency systems depth, a skills assessment flagging Kubernetes ramp-up risk, and an interview loop that probes distributed-systems fundamentals plus infrastructure adaptability.",
        "expected_route": "engineering",
        "expected_worker_id": "worker_interview_plan"
    },
    {
        "task_id": "sales_advance_easy",
        "category": "sales",
        "difficulty": "easy",
        "initial_input": "Application for Enterprise Account Executive: 8 years SaaS sales, 130% average quota attainment for 4 straight years, closed three 7-figure logos, built EMEA from zero.",
        "expected_ground_truth": "Hiring packet recommending ADVANCE with a screening summary of overattainment and 7-figure closes, an above-bar skills assessment, and an interview loop with deal walkthroughs.",
        "expected_route": "sales",
        "expected_worker_id": "worker_interview_plan"
    },
    {
        "task_id": "sales_reject_easy",
        "category": "sales",
        "difficulty": "easy",
        "initial_input": "Application for Enterprise Account Executive: 1 year as an SDR, no closing experience, missed quota twice; role requires 5+ years closing 6-figure SaaS deals.",
        "expected_ground_truth": "Hiring packet recommending REJECT with a screening summary noting the closing-experience gap, a below-bar skills assessment, and a respectful rejection note encouraging reapplication later.",
        "expected_route": "sales",
        "expected_worker_id": "worker_rejection"
    },
    {
        "task_id": "sales_reject_hard",
        "category": "sales",
        "difficulty": "hard",
        "initial_input": "Application for Enterprise Account Executive: 12 years in sales but all transactional retail SMB deals under $5k, inflated title history, three sub-9-month stints in the last four years; role is complex 6-figure enterprise cycles.",
        "expected_ground_truth": "Hiring packet recommending REJECT: screening summary distinguishing transactional SMB experience from enterprise cycles, a skills assessment flagging tenure and deal-size mismatch, and a respectful rejection note.",
        "expected_route": "sales",
        "expected_worker_id": "worker_rejection"
    }
];
