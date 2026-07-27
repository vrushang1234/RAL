"""Investment research memo demo: asset-class router → analyst → risk → compliance chain. Weak prompts intentional."""

glob:pub RESEARCH_WORKFLOW: dict = {
    "schema_version": "1.0.0",
    "workflow_id": "wf_research_memo",
    "workflow_name": "Investment Research Memo",
    "workflow_version": 1,
    "configuration_hash": None,
    "status": "DRAFT",
    "description": "Route a research request by asset class to an analyst, then chain every path through a risk assessor and a compliance reviewer before the memo is assembled.",
    "entry_node_id": "trigger_request",
    "output_node_id": "aggregator_memo",
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
            "node_id": "trigger_request",
            "node_name": "Research Request",
            "type": "Trigger",
            "enabled": True,
            "fixed_role_description": "Accepts the raw research request as workflow input.",
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
            "ui": {"position": {"x": 60, "y": 300}, "width": 280, "height": 160, "collapsed": False}
        },
        {
            "node_id": "router_asset",
            "node_name": "Asset-Class Router",
            "type": "Router",
            "enabled": True,
            "fixed_role_description": "You classify research requests by asset class.",
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
                "prompt_id": "p_asset_router",
                "prompt_version": 1,
                "system_prompt": "Decide if this request is about equity, macro, or crypto.",
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
            "ui": {"position": {"x": 340, "y": 300}, "width": 280, "height": 200, "collapsed": False}
        },
        {
            "node_id": "worker_equity",
            "node_name": "Equity Analyst",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You are an equity analyst producing fundamental analysis of a company or sector.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_equity",
                "prompt_version": 1,
                "system_prompt": "Analyze.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the analysis.",
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
            "ui": {"position": {"x": 620, "y": 60}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_macro",
            "node_name": "Macro Analyst",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You are a macro analyst covering rates, inflation, currencies, and central-bank policy.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_macro",
                "prompt_version": 1,
                "system_prompt": "Analyze.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the analysis.",
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
            "ui": {"position": {"x": 620, "y": 320}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_crypto",
            "node_name": "Crypto Analyst",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You are a digital-assets analyst covering tokens, protocols, and on-chain activity.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_crypto",
                "prompt_version": 1,
                "system_prompt": "Analyze.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the analysis.",
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
            "ui": {"position": {"x": 620, "y": 580}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_risk",
            "node_name": "Risk Assessor",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You stress-test the analyst's thesis and enumerate downside risks and position sizing limits.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_risk",
                "prompt_version": 1,
                "system_prompt": "Assess risk.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the risk assessment.",
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
            "ui": {"position": {"x": 940, "y": 300}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "worker_compliance",
            "node_name": "Compliance Reviewer",
            "type": "WorkerAgent",
            "enabled": True,
            "fixed_role_description": "You review the analysis for regulatory issues, required disclaimers, and restricted-list conflicts.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {"type": "object", "additionalProperties": True},
            "prompt_config": {
                "prompt_id": "p_compliance",
                "prompt_version": 1,
                "system_prompt": "Review.",
                "user_prompt_template": "{{node_input}}",
                "output_instructions": "Write the compliance review.",
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
            "ui": {"position": {"x": 1260, "y": 300}, "width": 300, "height": 240, "collapsed": False}
        },
        {
            "node_id": "aggregator_memo",
            "node_name": "Memo Assembler",
            "type": "Aggregator",
            "enabled": True,
            "fixed_role_description": "You assemble the final investment memo from the analysis, risk assessment, and compliance review.",
            "expected_input_schema": {"type": "object", "additionalProperties": True},
            "expected_output_schema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"output": {"type": "string"}},
                "required": ["output"]
            },
            "prompt_config": {
                "prompt_id": "p_memo_agg",
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
                    "required_upstream_node_ids": ["worker_compliance"],
                    "custom_instructions": None
                }
            },
            "ui": {"position": {"x": 1580, "y": 300}, "width": 300, "height": 220, "collapsed": False}
        }
    ],
    "edges": [
        {
            "edge_id": "res_e1",
            "source_node_id": "trigger_request",
            "target_node_id": "router_asset",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$.input", "target": "$.workflow_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "res_e2",
            "source_node_id": "router_asset",
            "target_node_id": "worker_equity",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "equity"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "equity"}
        },
        {
            "edge_id": "res_e3",
            "source_node_id": "router_asset",
            "target_node_id": "worker_macro",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "macro"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "macro"}
        },
        {
            "edge_id": "res_e4",
            "source_node_id": "router_asset",
            "target_node_id": "worker_crypto",
            "condition": {"type": "ROUTE_VALUE", "expression": None, "route_value": "crypto"},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": "crypto"}
        },
        {
            "edge_id": "res_e5",
            "source_node_id": "worker_equity",
            "target_node_id": "worker_risk",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "res_e6",
            "source_node_id": "worker_macro",
            "target_node_id": "worker_risk",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "res_e7",
            "source_node_id": "worker_crypto",
            "target_node_id": "worker_risk",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "res_e8",
            "source_node_id": "worker_risk",
            "target_node_id": "worker_compliance",
            "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.node_input"},
            "ui": {"label": None}
        },
        {
            "edge_id": "res_e9",
            "source_node_id": "worker_compliance",
            "target_node_id": "aggregator_memo",
            "condition": {"type": "ON_SUCCESS", "expression": None, "route_value": None},
            "data_mapping": {"source": "$", "target": "$.upstream_outputs.worker_compliance"},
            "ui": {"label": None}
        }
    ],
    "metadata": {
        "created_at": "2026-07-26T00:00:00Z",
        "updated_at": "2026-07-26T00:00:00Z",
        "created_by": "demo",
        "tags": ["demo", "research", "finance"]
    }
};

glob:pub RESEARCH_DATASET: list = [
    {
        "initial_input": "Write a memo on whether we should initiate a position in a mid-cap semiconductor equipment maker trading at 14x forward earnings with 30% revenue growth and heavy China exposure.",
        "expected_ground_truth": "Investment memo with a fundamental equity analysis of valuation vs growth, a risk section covering China export-control exposure and cyclicality with a position-size limit, and a compliance note with required disclaimers."
    },
    {
        "initial_input": "Assess the impact of the central bank holding rates while balance-sheet runoff accelerates; how should our duration positioning change?",
        "expected_ground_truth": "Investment memo with a macro analysis of the rates-and-runoff mix, a risk assessment covering curve and liquidity scenarios with sizing limits, and a compliance review confirming no restricted instruments."
    },
    {
        "initial_input": "Evaluate a position in a top-10 layer-1 token ahead of its staking-yield change; on-chain activity is up 40% quarter over quarter.",
        "expected_ground_truth": "Investment memo with a crypto analysis of the staking-yield catalyst and on-chain trends, a risk section covering protocol, custody, and regulatory risks with strict sizing, and a compliance review flagging jurisdiction constraints."
    }
];

# Labeled eval matrix for the RL testbench dashboard (category x difficulty).
# expected_route is the asset-class router's choice; expected_worker_id checks the analyst path.
glob:pub RESEARCH_EVAL_MATRIX: list = [
    {
        "task_id": "equity_easy",
        "category": "equity",
        "difficulty": "easy",
        "initial_input": "Write a memo on initiating a position in a mid-cap semiconductor equipment maker trading at 14x forward earnings with 30% revenue growth.",
        "expected_ground_truth": "Investment memo with fundamental equity analysis, a risk section with a position-size limit, and a compliance note with required disclaimers.",
        "expected_route": "equity",
        "expected_worker_id": "worker_equity"
    },
    {
        "task_id": "equity_hard",
        "category": "equity",
        "difficulty": "hard",
        "initial_input": "Memo request: activist stake just disclosed in a dual-class media conglomerate mid-restructuring; sum-of-the-parts suggests 40% upside but the controlling family blocks board changes and a spin-off is taxable. Position or pass?",
        "expected_ground_truth": "Investment memo weighing sum-of-the-parts upside against governance blockage and tax leakage, a risk assessment covering activist-exit and structure risks with strict sizing, and a compliance review checking restricted-list and MNPI concerns.",
        "expected_route": "equity",
        "expected_worker_id": "worker_equity"
    },
    {
        "task_id": "macro_easy",
        "category": "macro",
        "difficulty": "easy",
        "initial_input": "Assess the impact of the central bank holding rates while balance-sheet runoff accelerates; how should duration positioning change?",
        "expected_ground_truth": "Investment memo with macro analysis of rates and runoff, a risk assessment of curve scenarios with sizing limits, and a compliance review.",
        "expected_route": "macro",
        "expected_worker_id": "worker_macro"
    },
    {
        "task_id": "macro_hard",
        "category": "macro",
        "difficulty": "hard",
        "initial_input": "Memo: an EM currency with a crawling peg faces 60% odds of a step devaluation per NDF pricing, while local rates pay 22% carry. Structure a carry trade with defined tail protection or recommend standing aside.",
        "expected_ground_truth": "Investment memo analyzing the carry-versus-devaluation tradeoff, a risk section quantifying tail loss and hedge cost with strict sizing and stop conditions, and a compliance review of EM instrument eligibility.",
        "expected_route": "macro",
        "expected_worker_id": "worker_macro"
    },
    {
        "task_id": "crypto_easy",
        "category": "crypto",
        "difficulty": "easy",
        "initial_input": "Evaluate a position in a top-10 layer-1 token ahead of its staking-yield change; on-chain activity is up 40% quarter over quarter.",
        "expected_ground_truth": "Investment memo with crypto analysis of the staking catalyst, a risk section covering protocol and custody risks with strict sizing, and a compliance review flagging jurisdiction constraints.",
        "expected_route": "crypto",
        "expected_worker_id": "worker_crypto"
    },
    {
        "task_id": "crypto_medium",
        "category": "crypto",
        "difficulty": "medium",
        "initial_input": "Evaluate providing liquidity to a blue-chip DEX pool where fees annualize at 19% but the pair has diverged 35% in 90 days; impermanent loss has eaten prior LP returns.",
        "expected_ground_truth": "Investment memo analyzing fee yield against impermanent-loss drag, a risk assessment with divergence scenarios and sizing limits, and a compliance review of DeFi counterparty and custody policy.",
        "expected_route": "crypto",
        "expected_worker_id": "worker_crypto"
    }
];
