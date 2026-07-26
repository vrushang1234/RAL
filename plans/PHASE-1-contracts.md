# PHASE 1 — Contracts & Environment (Hour 1, first half)

> Execute this file top to bottom. When done, tick the Gate checklist, update `context.md`, then open `plans/PHASE-2-canvas-spike.md`.

## Context capsule (read even if you have no other context)

**Project:** RAL — a drag-and-drop n8n-style platform to compose, run, and RL-optimize multi-agent LLM workflows. Built as a **full-stack Jac web-app** (Jac client with JSX + Jac server walkers, one process via `jac start --dev main.jac`). Source of truth: `DESIGN.md`. Repo is already scaffolded (`jac.toml` has `kind = "web-app"`, `[serve] base_route_app = "app"`) — extend in place, NEVER re-scaffold.

**Decisions that bind this phase:**
- **D3** — The RL optimizer is a teammate-owned black box behind exactly one function: `optimize(payload: dict) -> dict` in `rl_bridge.py`. The platform never knows how it works. Until Phase 6, the body is a mock.
- **D9** — The RL contract's `current_sem_prompt` maps to the WorkflowDefinition's `prompt_config.system_prompt`. Mutations write there and bump `prompt_version`. `fixed_role_description`, `user_prompt_template`, `output_instructions` are guardrails — never mutated.
- Contracts are FROZEN after this phase; changes must be additive + optional only.

**Universal rules (apply in every phase):**
1. Before writing Jac, load guides: `jac guide <name>`. After every file: `jac check .`.
2. This phase's guides: `jac guide jac-config`, `jac guide jac-python-interop`.
3. Update `context.md` (Recent Changes + Current Goals) at the end of the phase.

## Task 1 — Commit the WorkflowDefinition schema

Create `schemas/workflow_definition.json` by copying **verbatim** the team schema v1.0.0 from `/Users/hmahuvaw/Downloads/message.txt` (474 lines: `schema_version`, `entry_node_id`, `output_node_id`, `global_config`, `tool_catalog`, `skill_catalog`, `nodes[]` with `prompt_config`/`type_config`/`ui`, `edges[]` with `condition`/`data_mapping`, `metadata`).

## Task 2 — Commit the two RL contracts

Create `schemas/workflow_execution_payload.json` (Platform → RL, JSON Schema draft-07):

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "WorkflowExecutionPayload",
  "type": "object",
  "required": ["workflow_run_id", "task_context", "agent_states", "execution_trace"],
  "properties": {
    "workflow_run_id": { "type": "string" },
    "task_context": {
      "type": "object",
      "required": ["initial_input", "expected_ground_truth", "actual_final_output"],
      "properties": {
        "initial_input": { "type": "string" },
        "expected_ground_truth": { "type": "string" },
        "actual_final_output": { "type": "string" }
      }
    },
    "agent_states": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["node_id", "agent_name", "type", "fixed_role_description",
                     "expected_input", "expected_output", "current_sem_prompt"],
        "properties": {
          "node_id": { "type": "string" },
          "agent_name": { "type": "string" },
          "type": { "type": "string", "enum": ["Trigger", "Router", "WorkerAgent", "Aggregator"] },
          "fixed_role_description": { "type": "string" },
          "expected_input": { "type": "string" },
          "expected_output": { "type": "string" },
          "current_sem_prompt": { "type": "string" }
        }
      }
    },
    "edges": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["source", "target"],
        "properties": { "source": { "type": "string" }, "target": { "type": "string" } }
      }
    },
    "execution_trace": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["step", "node_id", "status"],
        "properties": {
          "step": { "type": "integer" },
          "node_id": { "type": "string" },
          "status": { "type": "string", "enum": ["EXECUTED", "SKIPPED", "FAILED"] },
          "input_received": { "type": "string" },
          "output_generated": { "type": "string" },
          "error_message": { "type": "string" }
        }
      }
    }
  }
}
```

Create `schemas/rl_optimizer_response.json` (RL → Platform):

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "RLOptimizerResponse",
  "type": "object",
  "required": ["critic_score", "analysis_log", "prompt_mutations"],
  "properties": {
    "critic_score": { "type": "number", "minimum": 0.0, "maximum": 1.0 },
    "analysis_log": { "type": "string" },
    "prompt_mutations": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["node_id", "new_sem_prompt"],
        "properties": {
          "node_id": { "type": "string" },
          "new_sem_prompt": { "type": "string" }
        }
      }
    }
  }
}
```

Notes: `current_sem_prompt` in the payload is populated from `prompt_config.system_prompt` (D9). `expected_input`/`expected_output` are the node's I/O JSON Schemas serialized to strings. `edges` is optional topology info for the RL engine's credit assignment.

## Task 3 — `mock_rl.py` (complete file)

```python
"""Mock RL optimizer. Same signature as the teammate's real implementation.

Deliberately mutates a prompt on every call so the full loop
(rehydrate -> version bump -> response -> canvas update) is genuinely
exercised before the real RL engine lands in Phase 6.
"""


def optimize(payload: dict) -> dict:
    mutations = []
    for state in payload["agent_states"]:
        if state["type"] == "WorkerAgent":
            mutations.append({
                "node_id": state["node_id"],
                "new_sem_prompt": state["current_sem_prompt"]
                + " Be more concise and specific.",
            })
            break
    return {
        "critic_score": 0.42,
        "analysis_log": "[mock] Appended conciseness instruction to first worker.",
        "prompt_mutations": mutations,
    }
```

## Task 4 — `rl_bridge.py` (complete file)

The ONLY place the platform touches RL. Phase 6 swaps one import line.

```python
"""RL black-box boundary. In: WorkflowExecutionPayload. Out: RLOptimizerResponse.

The implementation behind `_impl` is entirely the RL owner's concern
(in-process, HTTP client, anything). Swap the import in Phase 6.
"""

from mock_rl import optimize as _impl
# Phase 6: from teammate_rl import optimize as _impl   (keep mock line for instant fallback)

REQUIRED_KEYS = {"critic_score", "analysis_log", "prompt_mutations"}


def optimize(payload: dict) -> dict:
    response = _impl(payload)
    missing = REQUIRED_KEYS - set(response)
    if missing:
        raise ValueError(f"RLOptimizerResponse missing keys: {missing}")
    if not isinstance(response["prompt_mutations"], list):
        raise ValueError("prompt_mutations must be a list")
    return response
```

## Task 5 — Environment

1. Create `.env` at repo root: `OPENAI_API_KEY=<key>`. Ensure `.env` is in `.gitignore` (append if missing).
2. Add to `jac.toml`:

```toml
[byllm.model]
default_model = "gpt-4o-mini"
```

(`gpt-4o-mini`-class speed is mandatory: the demo runs on a 4-minute clock and each train step makes 3–5 LLM calls.)

## Task 6 — Teammate coordination (send now, do NOT block on reply)

Send the RL owner: (a) both schema files; (b) the `optimize(payload: dict) -> dict` signature — raise on failure, never return partial JSON; (c) the D9 mapping (mutations target `prompt_config.system_prompt` only, platform bumps `prompt_version`); (d) request their `requirements.txt` to merge; (e) agree both sides read `OPENAI_API_KEY`.

## Gate — all must pass before Phase 2

- [ ] `schemas/` contains all three JSON files, valid JSON (`python3 -m json.tool < each`)
- [ ] `python3 -c "from rl_bridge import optimize; print(optimize({'agent_states':[{'node_id':'w1','type':'WorkerAgent','current_sem_prompt':'x'}]}))"` prints a dict with all three keys
- [ ] `jac check .` green (scaffold untouched, still compiles)
- [ ] `.env` exists and is gitignored; `[byllm.model]` in `jac.toml`
- [ ] Teammate message sent
- [ ] `context.md` updated
