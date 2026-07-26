"""Offline smoke: build demo workflow and run_single without a live API key."""

import json;
import from endpoints { run_single }

with entry {
    wf = json.loads(open("fixtures/demo_workflow.json").read());
    billing = "Hi, I was charged twice for my subscription this month. Please refund one charge.";
    r1 = run_single(wf, billing);
    print("BILLING final:", (r1["final_output"] as str)[:160]);
    print("BILLING visited:", r1["visited_ids"]);
    for t in (r1["execution_trace"] as list) {
        print(" ", t["node_id"], t["status"]);
    }

    tech = "The app crashes every time I try to export a PDF on macOS.";
    r2 = run_single(wf, tech);
    print("TECH visited:", r2["visited_ids"]);
    for t in (r2["execution_trace"] as list) {
        print(" ", t["node_id"], t["status"]);
    }
}
