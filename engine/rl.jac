"""RL bridge: call the optimizer + persist payload/response pairs under runs/.

The optimizer is now the Jac implementation in `rl/bridge.jac`, which scores the
trace deterministically and - crucially - accumulates observations across calls
so it can report whether a change is actually supported rather than just showing
a number that went up. See docs/rl-optimization.md section 9.

To fall back to the Python path (`rl_bridge.optimize`, currently backed by
`mock_rl.py`), swap the two marked lines in `call_rl`.
"""

import json;
import os;
import from datetime { datetime }
import from rl.bridge { OptimizerMemory, optimize_with_memory }
# Python fallback, kept wired for the mock / an external teammate optimizer.
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
