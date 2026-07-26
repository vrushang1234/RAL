"""Spawn FlowNode graph from a WorkflowDefinition dict — never attach to root (D2)."""

import from .nodes { FlowNode, FlowEdge }

obj BuiltGraph {
    has entry_node: FlowNode;
    has nodes_by_id: dict = {};
    has output_node_id: str = "";
}

def build_graph(workflow: dict) -> BuiltGraph {
    nodes_by_id: dict = {};
    for n in (workflow["nodes"] as list) {
        pc: dict = {};
        raw_pc: any = n["prompt_config"];
        if raw_pc {
            pc = raw_pc as dict;
        }
        eis: dict = {};
        if n["expected_input_schema"] {
            eis = n["expected_input_schema"] as dict;
        }
        eos: dict = {};
        if n["expected_output_schema"] {
            eos = n["expected_output_schema"] as dict;
        }
        tc: dict = {};
        if n["type_config"] {
            tc = n["type_config"] as dict;
        }
        role = str(n["fixed_role_description"]) if n["fixed_role_description"] else "";
        enabled = True if n["enabled"] else False;
        fn = FlowNode(
            node_id=str(n["node_id"]),
            node_name=str(n["node_name"]),
            kind=str(n["type"]),
            fixed_role_description=role,
            prompt_config=pc,
            expected_input_schema=eis,
            expected_output_schema=eos,
            type_config=tc,
            enabled=enabled
        );
        nodes_by_id[str(n["node_id"])] = fn;
    }

    for e in (workflow["edges"] as list) {
        src_id = str(e["source_node_id"]);
        tgt_id = str(e["target_node_id"]);
        src = nodes_by_id[src_id] as FlowNode;
        tgt = nodes_by_id[tgt_id] as FlowNode;
        cond: dict = e["condition"] as dict if e["condition"] else {};
        mapping: dict = e["data_mapping"] as dict if e["data_mapping"] else {};
        ctype = str(cond["type"]) if cond["type"] else "ALWAYS";
        rv = str(cond["route_value"]) if cond["route_value"] else "";
        ms = str(mapping["source"]) if mapping["source"] else "$";
        mt = str(mapping["target"]) if mapping["target"] else "$";
        src +>:FlowEdge(
            edge_id=str(e["edge_id"]),
            condition_type=ctype,
            route_value=rv,
            mapping_source=ms,
            mapping_target=mt,
            target_node_id=tgt_id
        ):+> tgt;
    }

    entry_id = str(workflow["entry_node_id"]);
    out_id = str(workflow["output_node_id"]) if workflow["output_node_id"] else "";
    return BuiltGraph(
        entry_node=nodes_by_id[entry_id] as FlowNode,
        nodes_by_id=nodes_by_id,
        output_node_id=out_id
    );
}
