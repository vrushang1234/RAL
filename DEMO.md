# RAL — JacHacks SF 2026 Demo (4:00)

**Who:** Maya, support lead at a 12-person SaaS — still triages billing vs technical email by hand.
**Locked input (pair 1):** duplicate-charge billing email (dataset first row).
**Jac story:** canvas + `TaskWalker` + byLLM + `PromptRehydrator` + **Eval Dashboard** — one language. Live RL path is Jac `rl.bridge` (mock remains a fallback).

## Timing

| Beat | Clock | Say / do |
|---|---|---|
| Problem | 0:00–0:30 | Name Maya. Point at the canvas graph (Trigger → Router → Billing/Technical → Aggregator). |
| Before | 0:30–1:00 | Click **Eval** → **Train on Matrix** (or **Run Baseline**). Table fills Before as each cell scores. |
| Train | 1:00–2:30 | Train mutates prompts, then auto-scores **After**. Watch activity log + Δ in the table. |
| After | 2:30–3:30 | Headline: mean critic before → after and Δ. (Train already filled After; re-run **Run After** if needed.) Open Billing/Technical inspector → prompt version badges. |
| Close | 3:30–4:00 | “UI, graph, walkers, byLLM, mutation, eval matrix — Jac. RL adapter scores and targets from the trace.” |

## Where Jac runs (point here)

- Client UI: `client/*.jac` (AppShell, FlowCanvas, TrainingConsole, **EvalDashboard**)
- Engine: `engine/task_walker.jac`, `engine/llm.jac` (`by llm()`), `engine/rehydrate.jac`, `engine/rl.jac` → `rl/bridge.jac`
- Endpoints: `endpoints.sv.jac` (`run_single`, `train_step`, `eval_cell`, `log_eval_report`)
- Entry: `main.jac` → `./scripts/start-dev.sh` or `jac start --dev main.jac`

## Eval matrix (say this)

Six labeled cells: billing/technical × easy/medium/hard. Metrics: **critic score**, **Δ**, **route ✓**, **worker hit**, **prompt versions**, **mutations**.

## Insurance

1. **Offline mock:** if live bridge misbehaves, temporarily route `engine/rl.jac` back through `rl_bridge.optimize` / `mock_rl.py`. Narrate: “offline mock still shows the loop.”
2. **Replay:** open `runs/eval_*.json` and `runs/*.json` — walk mean critic + mutations if the network dies.
3. **Cold start:** `./scripts/start-dev.sh` → http://localhost:8000 → Eval → Run Baseline.
