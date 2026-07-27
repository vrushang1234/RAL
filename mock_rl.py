# Kept as offline fallback. Live path: engine/rl.jac → rl.bridge.optimize_with_memory.
# Targets the WorkerAgent that EXECUTED (not the first listed twin).


def optimize(payload: dict) -> dict:
    mutations = []
    concise_hits = 0
    executed = set()
    for step in payload.get("execution_trace") or []:
        status = step.get("status") or ""
        nid = step.get("node_id") or ""
        if status not in ("SKIPPED",) and nid:
            executed.add(nid)

    for state in payload.get("agent_states") or []:
        prompt = state.get("current_sem_prompt") or ""
        concise_hits += prompt.lower().count("concise")
        if state.get("type") != "WorkerAgent":
            continue
        nid = state.get("node_id") or ""
        if nid in executed and not mutations:
            mutations.append({
                "node_id": nid,
                "new_sem_prompt": prompt + " Be more concise and specific.",
            })

    if not mutations:
        for state in payload.get("agent_states") or []:
            if state.get("type") == "WorkerAgent":
                prompt = state.get("current_sem_prompt") or ""
                mutations.append({
                    "node_id": state["node_id"],
                    "new_sem_prompt": prompt + " Be more concise and specific.",
                })
                break

    critic_score = min(0.35 + 0.18 * concise_hits, 0.92)
    return {
        "critic_score": round(critic_score, 2),
        "analysis_log": (
            f"[mock] concise_hits={concise_hits}; "
            f"targeted executed worker(s) among {sorted(executed)}."
        ),
        "prompt_mutations": mutations,
    }
