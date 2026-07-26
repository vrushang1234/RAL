"""byLLM helpers: prompt-as-parameter agent + structured router (D1)."""

import from jaclang.byllm.lib { Model }
import os;

glob llm: Model = Model(model_name="gemini/gemini-2.5-flash");

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

def has_llm_key -> bool {
    key = os.getenv("GOOGLE_API_KEY") or "";
    return len(key) > 0;
}

def heuristic_route(input_json: str, options: list[str]) -> RouteChoice {
    text = input_json.lower();
    billing_hit = "bill" in text or "charge" in text or "refund" in text or "payment" in text or "invoice" in text;
    chosen = options[0] if options else "billing";
    if billing_hit and "billing" in options {
        chosen = "billing";
    } elif (not billing_hit) and "technical" in options {
        chosen = "technical";
    } elif len(options) > 0 {
        chosen = options[0];
    }
    reason = "Heuristic fallback (no GOOGLE_API_KEY): keyword triage.";
    return RouteChoice(route=chosen, reason=reason);
}

def heuristic_agent(role_description: str, instructions: str, input_json: str) -> str {
    return (
        "[heuristic] " + role_description
        + " | instructions: " + instructions
        + " | input: " + input_json
    );
}

def safe_run_agent(role_description: str, instructions: str, input_json: str) -> str {
    if not has_llm_key() {
        return heuristic_agent(role_description, instructions, input_json);
    }
    try {
        return run_agent(role_description, instructions, input_json);
    } except Exception as e {
        return heuristic_agent(role_description, instructions + " [llm error: " + str(e) + "]", input_json);
    }
}

def safe_run_router(instructions: str, input_json: str, options: list[str]) -> RouteChoice {
    if not has_llm_key() {
        return heuristic_route(input_json, options);
    }
    try {
        return run_router(instructions, input_json, options);
    } except Exception as e {
        choice = heuristic_route(input_json, options);
        choice.reason = choice.reason + " (llm error: " + str(e) + ")";
        return choice;
    }
}
