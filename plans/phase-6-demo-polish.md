# Phase 6 (Hour 6) — Demo Polish & Rehearsal

> Self-contained execution spec. Architecture: [DESIGN.md](../DESIGN.md) (§9 demo script).
> Prior state (Phases 1–5): full product works with live RL; `runs/` holds recorded
> payload/response pairs; mock fallback is one commented line in `rl_bridge.py`.

## Context you must know (rubric — this hour is scored)

- **Use of Jac = 40%, double any other criterion.** Score-5 descriptor: "walkers, graph traversal,
  byLLM, agentic flows." Judges are told: "Be ready to show WHERE Jac runs — point to it in your
  repo or your demo."
- 4-minute demo, three required beats: (1) who it's for + what breaks today, (2) run the core
  workflow LIVE, (3) show where Jac runs inside the product.
- Real-World Use Case (20%): "Name one person, not a market." Ours: a support lead at a small
  SaaS company triaging billing vs technical emails by hand.
- Demo & Story (20%): score 1 is "a workflow that never runs" — the replay insurance exists so
  that can never happen.

## Task 1 — Console copy pass (make Jac visible)

Audit every log line the UI emits; each must name the Jac construct doing the work:

- Per trace step: `[TaskWalker] → WorkerAgent "worker_billing" EXECUTED`
- Router step adds the reason: `[TaskWalker] Router chose "billing": <RouteChoice.reason>`
- Skips: `[TaskWalker] worker_technical SKIPPED (route not taken)`
- Mutations: `[PromptRehydrator] worker_billing → v2`
- Scores: `[RL] critic_score = 0.71 ▲` (add ▲/▼ vs previous step — small state in the console)

Map `node_id → node_name` client-side from the workflow dict for friendlier lines.

## Task 2 — Seed-prompt tuning

- Confirm with the LIVE RL that scores start low (weak prompts) and climb across ≤3 steps on
  dataset pair 1. Adjust weakness in `client/demo_workflow.jac` until the arc is reliable.
- Lock the demo input: pair 1 (duplicate-charge billing email) — router says "billing" for an
  obviously legible reason on stage.

## Task 3 — Timing the 4 minutes (fill with Phase 5's measured latency)

| Beat | Time | Action |
|---|---|---|
| Problem | 0:00–0:30 | Who it's for; show the canvas graph while talking |
| Before | 0:30–1:00 | Run Once on the billing email → mediocre output; 10 s split-screen: `engine/task_walker.jac` beside the app |
| Train | 1:00–3:00 | Train → console streams walker lines, score climbs, Inspector shows v2/v3 on `worker_billing` |
| After | 3:00–3:45 | Run Once again, same email → visibly better output; point at before/after |
| Close | 3:45–4:00 | "UI, graph, walkers, byLLM, mutation — all Jac, one language, one process. The only non-Jac lines are the RL black box we call." |

If measured train-step latency makes 3 live steps too slow: do 2 live steps and narrate the
third from the recorded run.

## Task 4 — Insurance drills (do each ONCE, timed)

1. **Mock flip:** swap the `rl_bridge.py` import line to mock + restart; confirm the demo still
   runs (narration if needed: "here it is against our offline mock"). Target < 1 min.
2. **Replay:** pick the best `runs/*.json`; verify you can narrate the training arc from it
   (open the file, walk score + mutations) if the network dies entirely.
3. **Cold start:** `pkill -f "jac start"` → full start → app loads → Run Once, timed. Know this
   number; it's your recovery time on stage.

## Task 5 — Final QA sweep

```bash
jac check .                      # zero errors/warnings
pkill -f "jac start"; jac start --dev main.jac < /dev/null
jac browse open localhost:8000
jac browse snapshot              # canvas + console present
# click Run Once via browse, screenshot; click Train, wait, screenshot
jac browse close
```

- Remove `client/CanvasSpike.jac` and any scratch scripts (`scripts/validate_d1.jac` stays —
  it's evidence of methodology worth showing if asked).
- Skim the repo as a judge would: `engine/*.jac` and `client/*.jac` should dominate; confirm
  README or DESIGN.md points at where Jac runs.

## Task 6 — Rehearse

Run the §9 script TWICE back-to-back under a real 4:00 timer, including speaking the narration.
Fix only what breaks the clock. After the second clean run, STOP changing code.

## Task 7 — Close out

- `context.md`: phase 6 complete; final state of all decisions; demo timings; fallback drill
  results.
- Commit everything (ask the user before committing/pushing if not already authorized).

---

## Phase gate (done = demo-ready)

- [ ] Two clean 4:00 rehearsals back-to-back
- [ ] Every console line names a Jac construct
- [ ] Score arc reliable on the locked demo input
- [ ] All three insurance drills done and timed
- [ ] `jac check .` clean; scratch client spike removed
- [ ] `context.md` final update written
