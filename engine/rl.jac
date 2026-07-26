"""RL bridge helpers: call optimize + persist payload/response pairs under runs/."""

import json;
import os;
import from datetime { datetime }
import from rl_bridge { optimize }

def call_rl(payload: dict) -> dict {
    return optimize(payload) as dict;
}

def log_run(payload: dict, response: dict) -> None {
    os.makedirs("runs", exist_ok=True);
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S%f");
    path = os.path.join("runs", stamp + ".json");
    f = open(path, "w");
    f.write(json.dumps({"payload": payload, "response": response}, indent=2));
    f.close();
}
