# RAL

Visual multi-agent workflows with RL prompt optimization — **Jac full-stack** (JacHacks SF 2026).

## Run

```bash
# Optional: copy .env.example → .env and set GOOGLE_API_KEY for live Gemini
jac start --dev main.jac
# → http://localhost:8000/
```

## Where Jac runs

| Layer | Path |
|---|---|
| Client canvas + console | `client/*.jac` |
| Graph walk + byLLM | `engine/task_walker.jac`, `engine/llm.jac` |
| Prompt mutation | `engine/rehydrate.jac` |
| RPC | `endpoints.sv.jac` (`run_single`, `train_step`) |
| Entry | `main.jac` |

The only intentional non-Jac surface is `rl_bridge.py` → `optimize()` (mock today; teammate live RL in Phase 5).

## Docs

- Architecture: [`DESIGN.md`](DESIGN.md)
- Demo script: [`DEMO.md`](DEMO.md)
- Session state: [`context.md`](context.md)
- Phase plans: [`plans/`](plans/)
