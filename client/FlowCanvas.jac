"""React Flow canvas bound to a WorkflowDefinition dict — connect + drag."""

import "@xyflow/react/dist/style.css";
import from "@xyflow/react" { ReactFlow, Background, Controls }
import from .AgentNode { AgentNode }

glob AGENT_NODE_TYPES: dict = {"agent": AgentNode};

def:pub FlowCanvas(
    workflow: dict,
    on_select_node: Callable[[str], None],
    on_nodes_change: Callable[[str, float, float], None],
    on_connect: Callable[[str, str], None],
    on_delete_edge: Callable[[str], None],
    on_delete_node: Callable[[str], None]
) -> JsxElement {
    def handle_node_click(_ev: any, rf_node: any) {
        if rf_node and rf_node["id"] {
            on_select_node(str(rf_node["id"]));
        }
    }

    def handle_nodes_change(changes: any) {
        # Only persist drags. Ignore RF "remove" here — switching workflows
        # emits removes for the old graph and would wipe the new canvas.
        if not changes {
            return;
        }
        for c in (changes as list) {
            ctype: any = c["type"] if c else None;
            if ctype == "position" and not c["dragging"] {
                pos: any = c["position"] if c else None;
                cid: any = c["id"] if c else None;
                if cid and pos {
                    on_nodes_change(str(cid), float(pos["x"]), float(pos["y"]));
                }
            }
        }
    }

    def handle_nodes_delete(deleted: any) {
        if not deleted {
            return;
        }
        for n in (deleted as list) {
            if n and n["id"] {
                on_delete_node(str(n["id"]));
            }
        }
    }

    def handle_connect(connection: any) {
        if connection and connection["source"] and connection["target"] {
            on_connect(str(connection["source"]), str(connection["target"]));
        }
    }

    def handle_edges_change(_changes: any) {
        # Edge removes come through onEdgesDelete to avoid switch-workflow wipes.
        return;
    }

    def handle_edges_delete(deleted: any) {
        if not deleted {
            return;
        }
        for e in (deleted as list) {
            if e and e["id"] {
                on_delete_edge(str(e["id"]));
            }
        }
    }

    rf_nodes: list = [];
    rf_edges: list = [];
    nodes_src: list = (workflow["nodes"] as list) if workflow and workflow["nodes"] else [];
    edges_src: list = (workflow["edges"] as list) if workflow and workflow["edges"] else [];
    for n in nodes_src {
        ui: any = n["ui"] if n["ui"] else {};
        pos: any = ui["position"] if ui["position"] else {"x": 0, "y": 0};
        rf_nodes = rf_nodes + [{
            "id": n["node_id"],
            "position": pos,
            "type": "agent",
            "data": {"label": n["node_name"], "kind": n["type"]}
        }];
    }
    for e in edges_src {
        ui: any = e["ui"] if e["ui"] else {};
        cond: any = e["condition"] if e["condition"] else {};
        label: str = str(ui["label"]) if ui and ui["label"] else "";
        animated: bool = True if cond and cond["type"] == "ROUTE_VALUE" else False;
        rf_edges = rf_edges + [{
            "id": e["edge_id"],
            "source": e["source_node_id"],
            "target": e["target_node_id"],
            "label": label,
            "animated": animated
        }];
    }

    wid: str = str(workflow["workflow_id"]) if workflow and workflow["workflow_id"] else "wf";

    return <div style={{"flex": "1", "height": "100%", "minWidth": "0", "background": "#020617"}}>
        <ReactFlow
            key={wid}
            nodes={rf_nodes}
            edges={rf_edges}
            nodeTypes={AGENT_NODE_TYPES}
            onNodeClick={handle_node_click}
            onNodesChange={handle_nodes_change}
            onNodesDelete={handle_nodes_delete}
            onConnect={handle_connect}
            onEdgesChange={handle_edges_change}
            onEdgesDelete={handle_edges_delete}
            deleteKeyCode={["Backspace", "Delete"]}
            fitView={True}
            proOptions={{"hideAttribution": True}}
        >
            <Background color="#334155" gap={18} />
            <Controls />
        </ReactFlow>
    </div>;
}
