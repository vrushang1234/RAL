"""Persist RL train payloads and eval-matrix reports under runs/."""

import json;
import os;
import from datetime { datetime }
import from rl.bridge { OptimizerMemory, optimize_with_memory }

def _ensure_memory() -> OptimizerMemory {
    for m in [root -->][?:OptimizerMemory] {
        return m;
    }
    mem = OptimizerMemory();
    root ++> mem;
    return mem;
}

def call_rl(payload: dict) -> dict {
    mem = _ensure_memory();
    return optimize_with_memory(payload, mem);
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
