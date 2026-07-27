"""SRE Incident Response demo: nested routers (severity → service) + diagnosis chain. Weak prompts intentional."""

glob:pub SRE_WORKFLOW: dict = {
    "schema_version": "1.0.0",
    "workflow_id": "wf_sre_incident",
    "workflow_name": "SRE Incident Response",
    "workflow_version": 1,
    "configuration_hash": None,
    "status": "DRAFT",
    "description": "Classify an alert by severity, sub-route critical alerts by failing service, chain diagnosis into a remediation plan, and aggregate an incident report.",
    "entry_node_id": "trigger_alert",
    "output_node_id": "aggregator_incident",
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
            "node_id": "trigger_alert",
            "node_name": "Alert Webhook",
            "type": "Trigger",
            "enabled": True,
            "fixed_role_description": "Accepts the raw monitoring alert as workflow input.",
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
            "node_id": "router_severity",
            "node_name": "Severity Router",
            "type": "Router",
            "enabled": True,
            "fixed_role_description": "You classify production alerts by severity.",
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
                "prompt_id": "p_sev_router",
                "prompt_version": 1,
                "system_prompt": "Pick sev1 for full outages, sev2 for degraded service, sev3 for low-risk warnings.",
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
            "node_id": "router_service",
            "node_name": "Service Router",
            "type": "Router",
            "enabled": True,
            "fixed_role_description": "You identify which service tier is failing in a sev1 alert.",
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
                "prompt_id": "p_svc_router",
                "prompt_version": 1,
                "system_prompt": "Decide if the failing tier is the database or the api.",
                "user_prompt_template": "{{alert}}",
                "output_instructions": "Return the selected route.",
                "variables": ["alert"]
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
            "ui": {"position": {"x": 620, "y": 80}, "width": 280, "height": 200, "collapsed": False}
        },
        {
            "node_id": "worker_db_diag",
            "node_name": "DB Diagnoser",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You are a database reliability engineer diagnosing a production database failure.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_db_diag",
                "prompt_version": 1,
                "system_prompt": "Diagnose.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the diagnosis.",
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
            "ui": {"position": {"x": 920, "y": 0}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_api_diag",
            "node_name": "API Diagnoser",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You are a backend engineer diagnosing a production API failure.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_api_diag",
                "prompt_version": 1,
                "system_prompt": "Diagnose.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the diagnosis.",
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
            "ui": {"position": {"x": 920, "y": 260}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_oncall",
            "node_name": "On-Call Responder",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You are the on-call engineer triaging a degraded-service alert.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_oncall",
                "prompt_version": 1,
                "system_prompt": "Triage.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the triage notes.",
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
            "ui": {"position": {"x": 620, "y": 380}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_remediation",
            "node_name": "Remediation Planner",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You turn a diagnosis into a concrete remediation plan for the incident.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_remediation",
                "prompt_version": 1,
                "system_prompt": "Plan.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the remediation plan.",
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
            "ui": {"position": {"x": 1240, "y": 180}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_ticket",
            "node_name": "Ticket Filer",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You file a well-formed backlog ticket for a low-severity warning.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_ticket",
                "prompt_version": 1,
                "system_prompt": "File it.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the ticket.",
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
            "ui": {"position": {"x": 620, "y": 640}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "aggregator_incident",
            "node_name": "Incident Report",
            "type": "Aggregator",
            "enabled": True,
            "fixed_role_description": "You produce the final incident report for stakeholders.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"output": {"type": "string"}},
                "required": ["output"]
            },
            "prompt_config": {
                "prompt_id": "p_incident_agg",
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
                    "required_upstream_node_ids": ["worker_remediation", "worker_ticket"],
                    "custom_instructions": None
                }
            },
            "ui": {"position": {"x": 1560, "y": 320}, "width": 300, "height": 220, "collapsed": False}
        }
    ],
    "edges": [
        {
            "edge_id": "sre_e1",
            "source_node_id": "trigger_alert",
            "target_node_id": "router_severity",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$.input", "target": "$.workflow_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "sre_e2",
            "source_node_id": "router_severity",
            "target_node_id": "router_service",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "sev1"},
            "data_mapping": {"source": "$", "target": "$.alert"},
            "ui": {"label": "sev1"}
        },
        {
            "edge_id": "sre_e3",
            "source_node_id": "router_severity",
            "target_node_id": "worker_oncall",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "sev2"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "sev2"}
        },
        {
            "edge_id": "sre_e4",
            "source_node_id": "router_severity",
            "target_node_id": "worker_ticket",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "sev3"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "sev3"}
        },
        {
            "edge_id": "sre_e5",
            "source_node_id": "router_service",
            "target_node_id": "worker_db_diag",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "database"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "database"}
        },
        {
            "edge_id": "sre_e6",
            "source_node_id": "router_service",
            "target_node_id": "worker_api_diag",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "api"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "api"}
        },
        {
            "edge_id": "sre_e7",
            "source_node_id": "worker_db_diag",
            "target_node_id": "worker_remediation",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "sre_e8",
            "source_node_id": "worker_api_diag",
            "target_node_id": "worker_remediation",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "sre_e9",
            "source_node_id": "worker_oncall",
            "target_node_id": "worker_remediation",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "sre_e10",
            "source_node_id": "worker_remediation",
            "target_node_id": "aggregator_incident",
            "condition": {"type": "ON_SUCCESS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.upstream_outputs.worker_remediation"},
            "ui": {"label": None}
        },
        {
            "edge_id": "sre_e11",
            "source_node_id": "worker_ticket",
            "target_node_id": "aggregator_incident",
            "condition": {"type": "ON_SUCCESS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.upstream_outputs.worker_ticket"},
            "ui": {"label": None}
        }
    ],
    "metadata": {
        "created_at": "2026-07-26T00:00:00Z",
        "updated_at": "2026-07-26T00:00:00Z",
        "created_by": "demo",
        "tags": ["demo", "sre", "incident-response"]
    }
};

glob:pub SRE_DATASET: list = [
    {
        "initial_input": "PagerDuty SEV ALERT: prod-postgres-primary unreachable for 4 minutes. Replication lag on standby at 90s. All checkout writes failing with connection timeouts.",
        "expected_ground_truth": "Incident report naming the Postgres primary outage as sev1/database, a diagnosis pointing to primary failure with replica lag risk, and a remediation plan: promote the standby, repoint the connection pool, verify checkout writes, then schedule a postmortem."
    },
    {
        "initial_input": "Grafana alert: p99 latency on /search rose from 300ms to 1.8s over the last 30 minutes. Error rate steady at 0.2%. Traffic normal.",
        "expected_ground_truth": "Incident report classifying a sev2 latency degradation, triage notes ruling out traffic spikes, and a remediation plan to inspect recent deploys and cache hit rates with a rollback option."
    },
    {
        "initial_input": "Monitoring notice: /var/log disk usage on staging-worker-3 reached 71% (warn threshold 70%). No user impact.",
        "expected_ground_truth": "Incident report classifying a sev3 warning and a backlog ticket with title, priority, affected host, and a log-rotation cleanup task; no paging."
    }
];

# Labeled eval matrix for the RL testbench dashboard (category x difficulty).
# expected_route is the FIRST router's choice (severity); expected_worker_id checks the deep path.
glob:pub SRE_EVAL_MATRIX: list = [
    {
        "task_id": "sev1_db_easy",
        "category": "sev1",
        "difficulty": "easy",
        "initial_input": "PagerDuty SEV ALERT: prod-postgres-primary unreachable for 4 minutes. All checkout writes failing with connection timeouts.",
        "expected_ground_truth": "Incident report naming the database outage as sev1, diagnosing primary failure, and a remediation plan to promote the standby and repoint the connection pool.",
        "expected_route": "sev1",
        "expected_worker_id": "worker_db_diag"
    },
    {
        "task_id": "sev1_db_hard",
        "category": "sev1",
        "difficulty": "hard",
        "initial_input": "Full outage: writes to orders table deadlocking since 02:10 UTC after the schema migration; WAL volume filling at 2GB/min; standby promotion blocked by unapplied WAL. Checkout, refunds, and inventory all down.",
        "expected_ground_truth": "Incident report classifying sev1/database, diagnosing the migration-induced deadlocks and WAL pressure, and a remediation plan: halt the migration, clear the deadlocked sessions, free WAL space, then promote or recover the standby before re-enabling checkout.",
        "expected_route": "sev1",
        "expected_worker_id": "worker_db_diag"
    },
    {
        "task_id": "sev1_api_medium",
        "category": "sev1",
        "difficulty": "medium",
        "initial_input": "Outage: api-gateway returning 502 for all requests since the 14:00 deploy of auth-service v2.3.1. Health checks failing on 8/8 pods. Database dashboards all green.",
        "expected_ground_truth": "Incident report classifying sev1/api, diagnosing the bad auth-service deploy behind the gateway 502s, and a remediation plan to roll back v2.3.1 and verify pod health checks recover.",
        "expected_route": "sev1",
        "expected_worker_id": "worker_api_diag"
    },
    {
        "task_id": "sev2_easy",
        "category": "sev2",
        "difficulty": "easy",
        "initial_input": "Grafana alert: p99 latency on /search rose from 300ms to 1.8s over the last 30 minutes. Error rate steady at 0.2%. Service degraded but serving.",
        "expected_ground_truth": "Incident report classifying a sev2 degradation, triage notes on the latency regression, and a remediation plan to check recent deploys and cache hit rates with a rollback option.",
        "expected_route": "sev2",
        "expected_worker_id": "worker_oncall"
    },
    {
        "task_id": "sev2_hard",
        "category": "sev2",
        "difficulty": "hard",
        "initial_input": "Degraded: intermittent 429s on the public API for ~5% of tenants after the rate-limiter config push; retries are masking most user impact but queue depth is climbing slowly. No hard outage.",
        "expected_ground_truth": "Incident report classifying sev2, triage notes tying the intermittent 429s to the rate-limiter config push, and a remediation plan to revert the config, drain the queue, and add a canary check before the next push.",
        "expected_route": "sev2",
        "expected_worker_id": "worker_oncall"
    },
    {
        "task_id": "sev3_easy",
        "category": "sev3",
        "difficulty": "easy",
        "initial_input": "Monitoring notice: /var/log disk usage on staging-worker-3 reached 71% (warn threshold 70%). No user impact.",
        "expected_ground_truth": "Incident report classifying a sev3 warning and a backlog ticket with title, priority, affected host, and a log-rotation cleanup task; no paging.",
        "expected_route": "sev3",
        "expected_worker_id": "worker_ticket"
    }
];
