"""Flow grammar validator: Trigger start, Aggregator end, Pattern-B fan-out + chain exceptions."""

def validate_flow(workflow: dict) -> dict {
    errors: list = [];
    if not workflow {
        return {"ok": False, "errors": ["workflow is empty"]};
    }

    nodes_raw: list = workflow["nodes"] as list if workflow["nodes"] else [];
    edges_raw: list = workflow["edges"] as list if workflow["edges"] else [];

    if len(nodes_raw) == 0 {
        return {"ok": False, "errors": ["workflow has no nodes"]};
    }

    by_id: dict = {};
    triggers: list = [];
    aggregators: list = [];
    for n in nodes_raw {
        nid = str(n["node_id"]);
        kind = str(n["type"]);
        if nid in by_id {
            errors = errors + ["duplicate node_id: " + nid];
        }
        by_id[nid] = kind;
        if kind == "Trigger" {
            triggers = triggers + [nid];
        } elif kind == "Aggregator" {
            aggregators = aggregators + [nid];
        } elif kind != "Router" and kind != "WorkerAgent" {
            errors = errors + ["unknown node type on " + nid + ": " + kind];
        }
    }

    if len(triggers) != 1 {
        errors = errors + ["exactly one Trigger required (found " + str(len(triggers)) + ")"];
    }
    if len(aggregators) != 1 {
        errors = errors + ["exactly one Aggregator required (found " + str(len(aggregators)) + ")"];
    }

    entry = str(workflow["entry_node_id"]) if workflow["entry_node_id"] else "";
    output = str(workflow["output_node_id"]) if workflow["output_node_id"] else "";
    if len(triggers) == 1 and entry != triggers[0] {
        errors = errors + ["entry_node_id must be the Trigger (" + str(triggers[0]) + ")"];
    }
    if len(aggregators) == 1 and output != aggregators[0] {
        errors = errors + ["output_node_id must be the Aggregator (" + str(aggregators[0]) + ")"];
    }

    inbound: dict = {};
    outbound: dict = {};
    for nid in by_id.keys() {
        inbound[str(nid)] = [];
        outbound[str(nid)] = [];
    }

    ei = 0;
    for e in edges_raw {
        ei = ei + 1;
        src = str(e["source_node_id"]);
        tgt = str(e["target_node_id"]);
        if src not in by_id {
            errors = errors + ["edge source missing: " + src];
            continue;
        }
        if tgt not in by_id {
            errors = errors + ["edge target missing: " + tgt];
            continue;
        }
        sk = str(by_id[src]);
        tk = str(by_id[tgt]);
        allowed = False;
        if sk == "Trigger" and tk == "Router" {
            allowed = True;
        } elif sk == "Router" and (tk == "WorkerAgent" or tk == "Router") {
            allowed = True;
        } elif sk == "WorkerAgent" and (tk == "WorkerAgent" or tk == "Router" or tk == "Aggregator") {
            allowed = True;
        }
        if not allowed {
            errors = errors + [
                "illegal edge " + sk + " → " + tk + " (" + src + " → " + tgt + ")"
            ];
        }
        if sk == "Aggregator" {
            errors = errors + ["Aggregator must have no outbound edges (" + src + ")"];
        }
        if tk == "Trigger" {
            errors = errors + ["Trigger must have no inbound edges (" + tgt + ")"];
        }
        inbound[tgt] = (inbound[tgt] as list) + [src];
        outbound[src] = (outbound[src] as list) + [tgt];
    }

    if len(triggers) == 1 {
        tid = str(triggers[0]);
        if len(inbound[tid] as list) > 0 {
            errors = errors + ["Trigger must have no inbound edges"];
        }
        # BFS reachability from Trigger
        seen: dict = {};
        queue: list = [tid];
        seen[tid] = True;
        while len(queue) > 0 {
            cur = str(queue[0]);
            queue = queue[1:];
            for nxt in (outbound[cur] as list) {
                ns = str(nxt);
                if ns not in seen {
                    seen[ns] = True;
                    queue = queue + [ns];
                }
            }
        }
        for nid in by_id.keys() {
            if str(nid) not in seen {
                errors = errors + ["node not reachable from Trigger: " + str(nid)];
            }
        }
    }

    if len(aggregators) == 1 {
        aid = str(aggregators[0]);
        if len(outbound[aid] as list) > 0 {
            errors = errors + ["Aggregator must have no outbound edges"];
        }
        # Reverse BFS from Aggregator
        rev: dict = {};
        for nid in by_id.keys() {
            rev[str(nid)] = [];
        }
        for e in edges_raw {
            src = str(e["source_node_id"]);
            tgt = str(e["target_node_id"]);
            if src in by_id and tgt in by_id {
                rev[src] = (rev[src] as list) + [tgt];
                # build predecessors: tgt <- src
            }
        }
        preds: dict = {};
        for nid in by_id.keys() {
            preds[str(nid)] = [];
        }
        for e in edges_raw {
            src = str(e["source_node_id"]);
            tgt = str(e["target_node_id"]);
            if src in by_id and tgt in by_id {
                preds[tgt] = (preds[tgt] as list) + [src];
            }
        }
        can_reach: dict = {};
        rq: list = [aid];
        can_reach[aid] = True;
        while len(rq) > 0 {
            cur = str(rq[0]);
            rq = rq[1:];
            for prev in (preds[cur] as list) {
                ps = str(prev);
                if ps not in can_reach {
                    can_reach[ps] = True;
                    rq = rq + [ps];
                }
            }
        }
        for nid in by_id.keys() {
            if str(nid) not in can_reach {
                errors = errors + ["node cannot reach Aggregator: " + str(nid)];
            }
        }
    }

    ok = len(errors) == 0;
    return {"ok": ok, "errors": errors};
}
