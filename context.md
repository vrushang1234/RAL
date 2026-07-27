# Project Context

## Current Goals

- Demo-ready product with workflow CRUD + flow grammar.
- **Pending Phase 5:** teammate `teammate_rl.py` → flip import in `rl_bridge.py`.
- Optional: `GOOGLE_API_KEY` in `.env`; model is `gemini/gemini-2.5-flash` (2.0-flash retired).

## Architectural Decisions

- **D0–D12** as in `DESIGN.md`.
- **Flow grammar (CRUD):** exactly one Trigger (`entry_node_id`) and one Aggregator (`output_node_id`);
  adjacency Trigger→Router, Router→Agent|Router, Agent→Agent|Router|Aggregator; Pattern B fan-out allowed.
  Full validation on Save / Run / Train; illegal edges rejected immediately on connect.
- **Workflow library:** `WorkflowDoc` nodes on `root` via `list/get/save/delete_workflow` (definitions only — not execution graphs).
- **Seeded examples:** `SEED_WORKFLOWS` in `AppShell.jac` (demo + SRE + recruiting + research) auto-seed on load
  and are delete-protected; per-workflow datasets/eval matrices resolved via `dataset_for_workflow` /
  `eval_matrix_for_workflow` and remounted into TrainingConsole/EvalDashboard via `key={workflow_id}`.
- **Eval route check caveat:** `eval_cell` reads the FIRST executed router's route, so `expected_route`
  in eval matrices must always be the entry router's value (e.g. sev1/sev2/sev3 for SRE, not database/api).

## Recent Changes

- 2026-07-26: **Rebased `hmahuvaw` onto `main`.** Resolved `engine/rl.jac` by keeping main's Jac
  `rl.bridge` optimizer (`optimizer_memory` / `call_rl` + python fallback) and adding Eval
  Dashboard's `log_eval_report`. Branch tip: `48c3fcf`.
- 2026-07-26: **Three complex demo workflows.** New seeded examples showcasing the dashboard/metrics:
  - `client/wf_sre_incident.cl.jac` — SRE Incident Response (nested routers: severity → service; diagnosis → remediation chain; 9 nodes/11 edges)
  - `client/wf_recruiting.cl.jac` — Recruiting Pipeline (Worker→Router: skills assessor feeds a Decision Router advance/reject; 9 nodes/10 edges)
  - `client/wf_research_memo.cl.jac` — Investment Research Memo (3-agent chain: analyst → risk → compliance; 8 nodes/9 edges)
  Each ships `*_DATASET` (Train) + `*_EVAL_MATRIX` (testbench). AppShell seeds all via `SEED_WORKFLOWS`,
  swaps datasets per workflow (keyed remount), and protects seeded ids from Delete. EvalDashboard now takes
  `eval_matrix` as a prop and tracks prompt versions for all WorkerAgents (was hardcoded billing/technical).
  JSON fixtures exported to `fixtures/{sre_incident,recruiting,research_memo}_workflow.json`;
  `scripts/smoke_examples.jac` validates + runs all three (all pass; verified in browser: canvas, dataset swap, eval matrix swap).

- 2026-07-26: **Eval Train fills table.** Train now scores Before → mutates → scores After,
  updating the matrix cell-by-cell (dict replace for React re-render) with an in-panel activity log.
- 2026-07-26: **Eval button missing in UI.** Served bundle was stale; microservice `jac build
  --client web` SIGABRTs on macOS (unversioned libcrypto). Fix: `jac run scripts/compile_client.jac`
  then `./scripts/start-dev.sh` (prebuilds so gateway skips broken build). Eval sits after
  + Aggregator in the toolbar.
- 2026-07-26: **RL Eval Dashboard.** `EVAL_MATRIX` (6 cells); `eval_cell` + `log_eval_report`;
  in-app Eval panel (Baseline / Train / After); `engine/rl.jac` calls Jac `rl.bridge`
  (executed-worker targeting). Reports under `runs/eval_*.json`.
- 2026-07-26: **RL fan-out targeting fix.** Grounding mutations now hit the *executed*
  WorkerAgent (not always `workers[0]` / Billing), so Technical-pair edits stop
  stacking onto Billing’s prompt.
- 2026-07-26: **Fixed GET / 404 after RL merge.** Client UI failed to build because `bun`
  was missing from PATH (`Client build failed → empty dist → 404`). Installed bun;
  app serves again with hardcoded Support Email Triage demo + rename fields.
- 2026-07-26: **Rename UI.** Header edits `workflow_name`; inspector edits `node_name`
  (canvas label updates live). IDs unchanged; Save persists library name.
- 2026-07-26: **Blank-canvas / library UX fix.** Demo always re-seeded + opened on load;
  New creates blank draft listed as “(unsaved)” in Load; RF remounts per workflow_id;
  node delete via onNodesDelete (no wipe on workflow switch); demo protected from Delete.
- 2026-07-26: **Library/canvas bugfixes.** New → blank canvas; Backspace/Delete remove nodes;
  `get_workflow` RPC alias fixed (was 404 as `fetch_workflow`); after Delete → blank draft +
  controlled Load select so deleted ids are not re-fetched.
- 2026-07-26: **Workflow CRUD + flow grammar.**
  - `engine/flow_grammar.jac` + `client/flow_grammar.cl.jac`
  - `engine/workflow_library.jac`; endpoints re-export library + `validate_workflow`
  - Canvas: +Trigger/Router/Agent/Aggregator, connect, delete node/edge; library New/Save/Load/Delete
  - Verified: demo validates; illegal Agent→Trigger rejected on save; triage Run Once still routes
- 2026-07-26: Phase 6 polish; Phase 5 deferred; Phases 1–4 complete.

## Teammate message (Phase 5)

Drop `teammate_rl.py` implementing `optimize(payload: dict) -> dict`, then in `rl_bridge.py`:
`from teammate_rl import optimize as _impl` and restart.
