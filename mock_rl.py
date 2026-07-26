def optimize(payload: dict) -> dict:
    """Mock RL: mutates first WorkerAgent prompt; score climbs with conciseness markers.

    Climbing scores let Phase 6 rehearsals show ▲ without live teammate RL.
    Phase 5: replace via rl_bridge.py import line.
    """
    mutations = []
    concise_hits = 0
    for state in payload["agent_states"]:
        prompt = state.get("current_sem_prompt") or ""
        concise_hits += prompt.lower().count("concise")
        if state["type"] == "WorkerAgent" and not mutations:
            mutations.append({
                "node_id": state["node_id"],
                "new_sem_prompt": prompt + " Be more concise and specific.",
            })
    # 0.35 → 0.53 → 0.71 → … capped so the demo arc is visible in ≤3 steps
    critic_score = min(0.35 + 0.18 * concise_hits, 0.92)
    return {
        "critic_score": round(critic_score, 2),
        "analysis_log": (
            f"[mock] concise_hits={concise_hits}; appended instruction to first worker."
        ),
        "prompt_mutations": mutations,
    }
