"""Minimal React Flow node block for Trigger / Router / WorkerAgent / Aggregator."""

import from "@xyflow/react" { Handle, Position }

glob KIND_ICONS: dict = {
    "Trigger": "⚡",
    "Router": "🔀",
    "WorkerAgent": "🤖",
    "Aggregator": "🧩"
};

glob KIND_BORDERS: dict = {
    "Trigger": "#2563eb",
    "Router": "#7c3aed",
    "WorkerAgent": "#059669",
    "Aggregator": "#d97706"
};

# jac:ignore[W5015]
def:pub AgentNode(props: any) -> JsxElement {
    data: any = props["data"] if props else {};
    kind: str = str(data["kind"]) if data and data["kind"] else "WorkerAgent";
    label: str = str(data["label"]) if data and data["label"] else "Agent";
    icon: str = KIND_ICONS[kind] if kind in KIND_ICONS else "•";
    border: str = KIND_BORDERS[kind] if kind in KIND_BORDERS else "#64748b";

    return <div
        style={{
            "minWidth": "160px",
            "padding": "10px 12px",
            "borderRadius": "8px",
            "border": "2px solid " + border,
            "background": "#0f172a",
            "color": "#f8fafc",
            "boxShadow": "0 4px 14px rgba(0,0,0,0.35)",
            "fontFamily": "system-ui, sans-serif"
        }}
    >
        {if kind != "Trigger" {
            <Handle type="target" position={Position.Left} style={{"background": border}} />
        }}
        <div style={{"display": "flex", "alignItems": "center", "gap": "8px"}}>
            <span style={{"fontSize": "18px"}}>{icon}</span>
            <div>
                <div style={{"fontWeight": "600", "fontSize": "13px"}}>{label}</div>
                <div style={{"fontSize": "10px", "opacity": "0.7", "marginTop": "2px"}}>{kind}</div>
            </div>
        </div>
        {if kind != "Aggregator" {
            <Handle type="source" position={Position.Right} style={{"background": border}} />
        }}
    </div>;
}
