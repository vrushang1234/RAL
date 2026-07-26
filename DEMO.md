# RAL — JacHacks SF 2026 Demo (4:00)

**Who:** Maya, support lead at a 12-person SaaS — still triages billing vs technical email by hand.
**Locked input (pair 1):** duplicate-charge billing email (dataset first row).
**Jac story:** canvas + `TaskWalker` + byLLM + `PromptRehydrator` — one language. Only non-Jac line is `rl_bridge.optimize`.

## Timing

| Beat | Clock | Say / do |
|---|---|---|
| Problem | 0:00–0:30 | Name Maya. Point at the canvas graph (Trigger → Router → Billing/Technical → Aggregator). |
| Before | 0:30–1:00 | **Run Once** on billing email. Split-screen: `engine/task_walker.jac` beside the console walker lines (~10 s). |
| Train | 1:00–3:00 | **Train**. Console: `[TaskWalker]`, Router chose…, `[RL] critic_score ▲`, `[PromptRehydrator] → vN`. Open Billing Agent → version badge. |
| After | 3:00–3:45 | **Run Once** again, same email. Contrast last output / prompt strength. |
| Close | 3:45–4:00 | “UI, graph, walkers, byLLM, mutation — all Jac. The only non-Jac lines are the RL black box.” |

## Where Jac runs (point here)

- Client UI: `client/*.jac` (AppShell, FlowCanvas, TrainingConsole)
- Engine: `engine/task_walker.jac`, `engine/llm.jac` (`by llm()`), `engine/rehydrate.jac`
- Endpoints: `endpoints.sv.jac` (`run_single`, `train_step`)
- Entry: `main.jac` → `jac start --dev main.jac`

## Insurance

1. **Mock flip (<1 min):** in `rl_bridge.py` keep `from mock_rl import optimize as _impl`. Restart. Narrate: “offline mock still shows the loop.”
2. **Replay:** open best `runs/*.json` — walk `critic_score` + `prompt_mutations` if the network dies.
3. **Cold start:** `pkill -f "jac start"; jac start --dev main.jac < /dev/null` → http://localhost:8000 → Run Once.
   Measured cold start ≈ **8 s** to HTTP 200 (rehearse this number).

## Phase 5 note

Live teammate RL not integrated yet. Mock climbs score via “concise” markers so rehearsal still shows ▲. When `teammate_rl.py` lands: one import flip + restart.
