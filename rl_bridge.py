# Phase 5 swap: comment mock, uncomment teammate (or HTTP fallback in phase-5 plan).
from mock_rl import optimize as _impl
# from teammate_rl import optimize as _impl

REQUIRED_KEYS = {"critic_score", "analysis_log", "prompt_mutations"}


def optimize(payload: dict) -> dict:
    response = _impl(payload)
    missing = REQUIRED_KEYS - set(response)
    if missing:
        raise ValueError(f"RLOptimizerResponse missing keys: {missing}")
    return response
