# Primary: unused when engine/rl.jac calls Jac rl.bridge directly.
# Fallback import retained for scripts that still `from rl_bridge import optimize`.
from mock_rl import optimize as _impl

REQUIRED_KEYS = {"critic_score", "analysis_log", "prompt_mutations"}


def optimize(payload: dict) -> dict:
    response = _impl(payload)
    missing = REQUIRED_KEYS - set(response)
    if missing:
        raise ValueError(f"RLOptimizerResponse missing keys: {missing}")
    return response
