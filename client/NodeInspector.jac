"""Inspector overlay for a selected workflow node."""

def:pub NodeInspector(
    workflow: dict,
    node_id: str,
    on_update_prompt: Callable[[str, str], None],
    on_delete_node: Callable[[str], None],
    on_close: Callable[[], None]
) -> JsxElement {
    selected: dict = {};
    found: bool = False;
    if workflow and workflow["nodes"] {
        nodes_src: list = workflow["nodes"] as list;
        for n in nodes_src {
            if n["node_id"] == node_id {
                selected = n as dict;
                found = True;
            }
        }
    }

    if not found {
        return <div />;
    }

    pc: any = selected["prompt_config"];
    has_prompt: bool = True if pc else False;
    prompt_text: str = str(pc["system_prompt"]) if has_prompt and pc["system_prompt"] else "";
    prompt_ver: str = str(pc["prompt_version"]) if has_prompt and pc["prompt_version"] else "1";
    in_schema: str = JSON.stringify(selected["expected_input_schema"], None, 2) if selected["expected_input_schema"] else "{}";
    out_schema: str = JSON.stringify(selected["expected_output_schema"], None, 2) if selected["expected_output_schema"] else "{}";
    role: str = str(selected["fixed_role_description"]) if selected["fixed_role_description"] else "";

    def handle_prompt_change(e: ChangeEvent) {
        on_update_prompt(node_id, e.target.value);
    }

    def handle_close(_e: MouseEvent) {
        on_close();
    }

    def handle_delete(_e: MouseEvent) {
        on_delete_node(node_id);
    }

    return <div
        style={{
            "position": "fixed",
            "top": "16px",
            "right": "16px",
            "width": "420px",
            "maxHeight": "calc(100vh - 32px)",
            "overflow": "auto",
            "background": "#0f172a",
            "color": "#e2e8f0",
            "border": "1px solid #334155",
            "borderRadius": "12px",
            "padding": "16px",
            "zIndex": "40",
            "boxShadow": "0 20px 40px rgba(0,0,0,0.45)",
            "fontFamily": "system-ui, sans-serif"
        }}
    >
        <div style={{"display": "flex", "justifyContent": "space-between", "alignItems": "center", "marginBottom": "12px"}}>
            <div>
                <div style={{"fontWeight": "700", "fontSize": "16px"}}>{str(selected["node_name"])}</div>
                <div style={{"fontSize": "12px", "color": "#94a3b8", "marginTop": "4px"}}>{str(selected["type"])}</div>
            </div>
            <div style={{"display": "flex", "gap": "8px"}}>
                <button
                    type="button"
                    onClick={handle_delete}
                    style={{
                        "background": "#7f1d1d",
                        "color": "#fecaca",
                        "border": "1px solid #991b1b",
                        "borderRadius": "6px",
                        "padding": "4px 10px",
                        "cursor": "pointer"
                    }}
                >Delete</button>
                <button
                    type="button"
                    onClick={handle_close}
                    style={{
                        "background": "#1e293b",
                        "color": "#e2e8f0",
                        "border": "1px solid #475569",
                        "borderRadius": "6px",
                        "padding": "4px 10px",
                        "cursor": "pointer"
                    }}
                >Close</button>
            </div>
        </div>

        <div style={{"marginBottom": "14px"}}>
            <div style={{"fontSize": "11px", "textTransform": "uppercase", "letterSpacing": "0.04em", "color": "#94a3b8", "marginBottom": "6px"}}>
                Role (guardrail — RL cannot change this)
            </div>
            <div style={{"fontSize": "13px", "lineHeight": "1.45", "background": "#1e293b", "padding": "10px", "borderRadius": "8px"}}>
                {role}
            </div>
        </div>

        {if has_prompt {
            <div style={{"marginBottom": "14px"}}>
                <div style={{"display": "flex", "justifyContent": "space-between", "alignItems": "center", "marginBottom": "6px"}}>
                    <div style={{"fontSize": "11px", "textTransform": "uppercase", "letterSpacing": "0.04em", "color": "#94a3b8"}}>
                        System prompt
                    </div>
                    <span style={{
                        "fontSize": "11px",
                        "background": "#312e81",
                        "color": "#c7d2fe",
                        "padding": "2px 8px",
                        "borderRadius": "999px"
                    }}>{"v" + prompt_ver}</span>
                </div>
                <textarea
                    value={prompt_text}
                    onChange={handle_prompt_change}
                    rows={6}
                    style={{
                        "width": "100%",
                        "boxSizing": "border-box",
                        "background": "#020617",
                        "color": "#f8fafc",
                        "border": "1px solid #475569",
                        "borderRadius": "8px",
                        "padding": "10px",
                        "fontFamily": "ui-monospace, monospace",
                        "fontSize": "12px",
                        "resize": "vertical"
                    }}
                />
            </div>
        }}

        <div style={{"marginBottom": "10px"}}>
            <div style={{"fontSize": "11px", "textTransform": "uppercase", "letterSpacing": "0.04em", "color": "#94a3b8", "marginBottom": "6px"}}>
                Expected input schema
            </div>
            <pre style={{
                "margin": "0",
                "background": "#020617",
                "padding": "10px",
                "borderRadius": "8px",
                "fontSize": "11px",
                "overflow": "auto",
                "border": "1px solid #1e293b"
            }}>{in_schema}</pre>
        </div>

        <div>
            <div style={{"fontSize": "11px", "textTransform": "uppercase", "letterSpacing": "0.04em", "color": "#94a3b8", "marginBottom": "6px"}}>
                Expected output schema
            </div>
            <pre style={{
                "margin": "0",
                "background": "#020617",
                "padding": "10px",
                "borderRadius": "8px",
                "fontSize": "11px",
                "overflow": "auto",
                "border": "1px solid #1e293b"
            }}>{out_schema}</pre>
        </div>
    </div>;
}
