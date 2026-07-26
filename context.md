# Project Context

## Current Goals

- Build the Visual Multi-Agent Platform with RL Prompt Optimization for JacHacks SF 2026.
- Follow `DESIGN.md` as the source of truth — **full-stack Jac** (client + server).
- Hour 1 next: freeze schemas with RL owner (including D9), scaffold/verify web-app,
  prove React Flow imports in Jac client.

## Architectural Decisions

- **D0** Full-stack Jac web-app: Jac client (JSX + React Flow via npm) + Jac server;
  `jac start --dev main.jac`. No React/TS app, no FastAPI. ~90–95% Jac.
- **D1** Prompt-as-parameter: mutable prompts are node data passed into `by llm()`, not semstrings.
- **D2** Stateless server graph; Jac client WorkflowDefinition is the source of truth.
- **D3** RL black box: `optimize(payload: dict) -> dict`, imported into Jac from `rl_bridge.py`.
- **D4** RL owns scoring; no Critic node in the graph.
- **D5** Single-branch routing via `ROUTE_VALUE` edges.
- **D6** Jac-client-driven training loop; no SSE/WebSockets.
- **D7** Native Jac endpoints only (`def:pub` / `walker:pub`); no FastAPI/Express.
- **D8** Fail-fast abort; FAILED + SKIPPED still sent to RL.
- **D9** RL mutates `prompt_config.system_prompt` (mapped to `current_sem_prompt` in the RL payload); bumps `prompt_version`.
- **D10** Minimal JSONPath: `$` and `$.dotted.path` only.
- **D11** Tools/skills/TOOL_LOOP/per-node models: parsed, not executed in v1.
- **D12** Aggregator required upstreams = intersection with activated nodes.

## Recent Changes

- 2026-07-26: Rewrote `DESIGN.md` for full-stack Jac (D0/D7); removed React/TS + FastAPI path.
- 2026-07-26: Added `DESIGN.md` (WorkflowDefinition schema + locked decisions).
- 2026-07-26: Initialized `context.md`.
