"""Offline smoke: validate + run_single each seeded example workflow (heuristic fallback OK)."""

import json;
import from endpoints { validate_workflow, run_single }

def smoke(name: str, wf: dict, input_text: str) {
    v = validate_workflow(wf);
    print(name, "validate:", v);
    if not v["ok"] {
        return;
    }
    r = run_single(wf, input_text);
    print(name, "failed:", r["failed"], "error:", r["error"]);
    for t in (r["execution_trace"] as list) {
        print(" ", t["node_id"], t["status"]);
    }
    print(name, "final:", (r["final_output"] as str)[:140]);
}

with entry {
    smoke(
        "SRE",
        json.loads(open("fixtures/sre_incident_workflow.json").read()) as dict,
        "PagerDuty SEV ALERT: prod-postgres-primary unreachable for 4 minutes. All checkout writes failing."
    );
    smoke(
        "RECRUITING",
        json.loads(open("fixtures/recruiting_workflow.json").read()) as dict,
        "Application for Senior Backend Engineer: 9 years distributed systems in Go and Rust, led a team of 6."
    );
    smoke(
        "RESEARCH",
        json.loads(open("fixtures/research_memo_workflow.json").read()) as dict,
        "Write a memo on initiating a position in a mid-cap semiconductor equipment maker at 14x forward earnings."
    );
}
