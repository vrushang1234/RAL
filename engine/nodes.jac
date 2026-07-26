"""Graph archetypes for workflow execution (detached from root — D2)."""

node FlowNode {
    has node_id: str;
    has node_name: str;
    has kind: str;
    has fixed_role_description: str = "";
    has prompt_config: dict = {};
    has expected_input_schema: dict = {};
    has expected_output_schema: dict = {};
    has type_config: dict = {};
    has enabled: bool = True;
}

edge FlowEdge: FlowNode --> FlowNode {
    has edge_id: str = "";
    has condition_type: str = "ALWAYS";
    has route_value: str = "";
    has mapping_source: str = "$";
    has mapping_target: str = "$";
    has target_node_id: str = "";
}
