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

## Recent Changes

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
