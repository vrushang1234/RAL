# Phase 5 (Hour 5) — Live RL Integration

> Self-contained execution spec. Architecture: [DESIGN.md](../DESIGN.md).
> Prior state (Phases 1–4): the ENTIRE loop works against `mock_rl.py` — Train mutates prompts,
> versions bump in the Inspector, `runs/` logs every payload/response pair. The only remaining
> integration is swapping the mock for the teammate's real `optimize()`.

## Context you must know

- **D3 contract**: teammate delivers `optimize(payload: dict) -> dict` — input
  `schemas/workflow_execution_payload.json`, output `schemas/rl_optimizer_response.json`,
  raises on failure. How it works inside (their own LLM calls, HTTP hop, whatever) is their
  concern — the platform only sees the function.
- `rl_bridge.py` already validates required response keys and is the ONLY file that changes.
- The demo needs `critic_score` to visibly climb across 2–3 steps on the triage dataset with the
  deliberately weak seed prompts.

## The swap (should be minutes, not the hour)

1. Drop the teammate's module (e.g. `teammate_rl.py` + any support files) into the repo root,
   next to `rl_bridge.py`.
2. Edit ONE line in `rl_bridge.py`:

```python
# from mock_rl import optimize as _impl        # instant fallback — keep this line commented
from teammate_rl import optimize as _impl
```

3. Merge their `requirements.txt`: `jac install <pkg>` per package (installs into the project's
   `.jac/venv`). If a dependency conflicts with the Jac stack and can't be resolved in ~10 min,
   switch to the HTTP fallback (below) instead of fighting it.
4. Confirm they read `GOOGLE_API_KEY` and use Gemini Flash (or add their env var name to `.env`).
5. **Full server restart** — server modules and Python imports do not hot-reload:
   `pkill -f "jac start"; jac start --dev main.jac < /dev/null`.

### HTTP fallback (only if in-process import is unworkable)

Teammate runs their code as a tiny server on port 8001; `rl_bridge.py` body becomes:

```python
import requests

def optimize(payload: dict) -> dict:
    resp = requests.post("http://localhost:8001/optimize", json=payload, timeout=120)
    resp.raise_for_status()
    response = resp.json()
    missing = REQUIRED_KEYS - set(response)
    if missing:
        raise ValueError(f"RLOptimizerResponse missing keys: {missing}")
    return response
```

Nothing else in the platform changes — that's the point of the black box.

## Integration debugging protocol (do NOT deviate)

- Debug ONLY with the logged `runs/*.json` files. A failing step's exact input payload is on
  disk — send the file to the teammate; do not live-debug their code in your tree.
- Platform-side symptoms and causes:
  - `RLOptimizerResponse missing keys` → their output drifted from the schema; show them
    `schemas/rl_optimizer_response.json`.
  - Endpoint returns the `"RL engine failed: …"` error dict → their code raised; the message
    carries their exception text. Check the console's red line first.
  - Mutations arrive but nothing changes on canvas → their `node_id`s don't match the workflow's
    (`trigger_1`, `router_1`, `worker_billing`, `worker_technical`, `aggregator_1` in the demo);
    compare against `agent_states[].node_id` in the logged payload.
  - Very slow steps → expected (their internal LLM calls); the console's "running…" line covers
    it. Only worry past ~90 s.
- If anything is unfixable near demo time: revert the one import line to the mock. The demo
  degrades gracefully (mock score is flat 0.42 — see Phase 6 for how to narrate that honestly)
  but NEVER breaks.

## Demo-tuning while integrating

- Run the full loop on BOTH dataset pairs; confirm the score trend is visible (weak seed prompts
  from Phase 2 should score low initially, then climb as mutations land).
- If their critic scores everything high immediately, weaken the seed prompts further in
  `client/demo_workflow.jac` (e.g. worker prompts to `"Reply."`) — the visible climb IS the demo.
- Note the typical per-step latency; Phase 6 uses it to time the 4-minute script.

---

## Phase gate (all must pass before Phase 6)

- [ ] Live `optimize()` integrated (in-process or HTTP); source noted in `context.md`
- [ ] 2–3 train steps on the demo dataset show a MOVING critic_score
- [ ] Mutations from the live RL land on canvas (Inspector shows new prompt + bumped version)
- [ ] Fallback flip to mock verified once and timed (<1 minute, one line + restart)
- [ ] `runs/` contains live payload/response pairs (demo replay insurance)
- [ ] `jac check .` green; `context.md` updated: phase 5 complete, per-step latency noted
