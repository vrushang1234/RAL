"""Offline smoke: validate_flow on demo + illegal edge."""

import json;
import from engine.flow_grammar { validate_flow }

with entry {
    wf = json.loads(open("fixtures/demo_workflow.json").read());
    r1 = validate_flow(wf);
    print("demo ok", r1["ok"], r1["errors"]);

    bad = json.loads(json.dumps(wf));
    edges = bad["edges"] as list;
    edges = edges + [{
        "edge_id": "bad",
        "source_node_id": "worker_billing",
        "target_node_id": "trigger_1",
        "condition": {"type": "ALWAYS", "expression": None, "route_value": None},
        "data_mapping": {"source": "$", "target": "$"},
        "ui": {"label": None}
    }];
    bad["edges"] = edges;
    r2 = validate_flow(bad);
    print("illegal ok", r2["ok"]);
    for e in (r2["errors"] as list) {
        print(" ", e);
    }
}
