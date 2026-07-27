"""RL bridge: call the optimizer + persist payload/response pairs under runs/.

The optimizer is the Jac implementation in `rl/bridge.jac`, which scores the
trace deterministically and accumulates observations across calls so it can say
whether a change is actually supported rather than just showing a number that
went up. See docs/rl-optimization.md section 9.

DO NOT revert this to `import from rl_bridge { optimize }` without meaning to.
That path runs `mock_rl.py`, which appends the literal sentence "Be more
concise and specific." to a prompt on every single call with no de-duplication,
so prompts accumulate it N times and the score climbs by counting the word.
That is a rehearsal fixture, not an optimizer.

The Python path is still importable below as a deliberate fallback (an external
teammate optimizer can be dropped into `rl_bridge.py`); swap the two marked
lines in `call_rl` to use it.

Also persists eval-matrix reports via `log_eval_report`.
"""

import json;
import os;
import from datetime { datetime }
import from rl.bridge { OptimizerMemory, optimize_with_memory }
# Deliberate fallback: mock_rl today, an external optimizer later.
import from rl_bridge { optimize as python_optimize }


"""Get-or-create the cross-call optimizer memory.

The memory has to outlive a single `train_step`: a paired delta needs the same
task scored under two workflow versions, and those arrive as separate calls.
"""
def optimizer_memory -> OptimizerMemory {
    existing = [root -->[?:OptimizerMemory]];
    if len(existing) > 0 {
        return existing[0];
    }
    fresh = OptimizerMemory();
    root ++> fresh;
    return fresh;
}


def call_rl(payload: dict) -> dict {
    return optimize_with_memory(payload, optimizer_memory());
    # Fallback: return python_optimize(payload) as dict;
}


def log_run(payload: dict, response: dict) -> None {
    os.makedirs("runs", exist_ok=True);
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S%f");
    path = os.path.join("runs", stamp + ".json");
    f = open(path, "w");
    f.write(json.dumps({"payload": payload, "response": response}, indent=2));
    f.close();
}

def log_eval_report(eval_report: dict) -> dict {
    os.makedirs("runs", exist_ok=True);
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S%f");
    path = os.path.join("runs", "eval_" + stamp + ".json");
    f = open(path, "w");
    f.write(json.dumps(eval_report, indent=2));
    f.close();
    return {"ok": True, "path": path};
}
