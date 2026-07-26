"""Training console — Run Once + Train loop. Phase 6: Jac-named console copy."""

sv import from endpoints { run_single, train_step }

import from .demo_workflow { DEMO_DATASET }  # demo_workflow.cl.jac

def log_color(kind: str) -> str {
    if kind == "score" {
        return "#4ade80";
    } elif kind == "mutation" {
        return "#fbbf24";
    } elif kind == "error" {
        return "#f87171";
    } elif kind == "walker" {
        return "#93c5fd";
    }
    return "#cbd5e1";
}

def:pub TrainingConsole(
    workflow: dict,
    dataset: list,
    logs: list,
    running: bool,
    last_output: str,
    train_control: dict,
    append_logs: Callable[[list], None],
    apply_updated_nodes: Callable[[list], None],
    get_workflow: Callable[[], dict],
    set_running: Callable[[bool], None],
    set_last_output: Callable[[str], None],
    request_stop: Callable[[], None]
) -> JsxElement {
    has dataset_text: str = JSON.stringify(DEMO_DATASET, None, 2);

    def node_meta(wf: dict, nid: str) -> dict {
        for n in (wf["nodes"] as list) {
            if str(n["node_id"]) == nid {
                return {
                    "name": str(n["node_name"]),
                    "kind": str(n["type"])
                };
            }
        }
        return {"name": nid, "kind": "Node"};
    }

    def format_trace_line(wf: dict, row: dict) -> str {
        nid = str(row["node_id"]);
        status = str(row["status"]);
        meta = node_meta(wf, nid);
        name = str(meta["name"]);
        kind = str(meta["kind"]);
        if status == "SKIPPED" {
            return "[TaskWalker] " + nid + " SKIPPED (route not taken)";
        }
        if kind == "Router" and status == "EXECUTED" {
            reason = "";
            route = "";
            out = str(row["output_generated"]) if row["output_generated"] else "";
            if out {
                try {
                    parsed: dict = JSON.parse(out) as dict;
                    if parsed["route"] {
                        route = str(parsed["route"]);
                    }
                    if parsed["reason"] {
                        reason = str(parsed["reason"]);
                    }
                } except Exception {
                    reason = "";
                }
            }
            if route != "" {
                line: str = "[TaskWalker] Router chose \"" + route + "\"";
                if reason != "" {
                    line = line + ": " + reason;
                }
                return line;
            }
        }
        line2: str = "[TaskWalker] → " + kind + " \"" + name + "\" " + status;
        if status == "FAILED" and row["error_message"] {
            line2 = line2 + ": " + str(row["error_message"]);
        }
        return line2;
    }

    def on_dataset_change(e: ChangeEvent) {
        dataset_text = e.target.value;
    }

    async def on_run_once(_e: MouseEvent) {
        if running {
            return;
        }
        set_running(True);
        batch: list = [{"kind": "info", "text": "[byLLM] run_single via TaskWalker…"}];
        try {
            examples: list = JSON.parse(dataset_text) as list;
            if len(examples) == 0 {
                batch = batch + [{"kind": "error", "text": "[run_single] dataset is empty"}];
                append_logs(batch);
                set_running(False);
                return;
            }
            first: dict = examples[0] as dict;
            input_text: str = str(first["initial_input"]);
            wf: dict = get_workflow();
            result: dict = await run_single(workflow=wf, input_text=input_text);
            if result["error"] {
                batch = batch + [{"kind": "error", "text": "[grammar] " + str(result["error"])}];
                append_logs(batch);
                set_running(False);
                return;
            }
            trace: list = result["execution_trace"] as list if result["execution_trace"] else [];
            for t in trace {
                batch = batch + [{"kind": "walker", "text": format_trace_line(wf, t as dict)}];
            }
            out = str(result["final_output"]) if result["final_output"] else "";
            set_last_output(out);
            if result["failed"] {
                batch = batch + [{"kind": "error", "text": "[TaskWalker] walk FAILED (D8 fail-fast)"}];
            } else {
                batch = batch + [{"kind": "info", "text": "[TaskWalker] run_single complete"}];
            }
        } except Exception as err {
            batch = batch + [{"kind": "error", "text": "[run_single] " + str(err)}];
        }
        append_logs(batch);
        set_running(False);
    }

    async def on_train(_e: MouseEvent) {
        if running {
            return;
        }
        train_control["active"] = True;
        set_running(True);
        batch: list = [{"kind": "info", "text": "[RL] train_step loop (client-driven, D6)…"}];
        prev_score: float = -1.0;
        try {
            examples: list = JSON.parse(dataset_text) as list;
            if len(examples) == 0 {
                batch = batch + [{"kind": "error", "text": "[train] dataset is empty"}];
                append_logs(batch);
                set_running(False);
                return;
            }
            for pair_any in examples {
                if not train_control["active"] {
                    batch = batch + [{"kind": "info", "text": "[train] stopped"}];
                    break;
                }
                pair: dict = pair_any as dict;
                inp = str(pair["initial_input"]);
                gt = str(pair["expected_ground_truth"]);
                preview = inp;
                if len(preview) > 60 {
                    preview = preview[:60] + "…";
                }
                batch = batch + [{"kind": "info", "text": "=== pair: " + preview + " ==="}];
                epoch = 0;
                while epoch < 3 {
                    if not train_control["active"] {
                        batch = batch + [{"kind": "info", "text": "[train] stopped"}];
                        break;
                    }
                    epoch = epoch + 1;
                    batch = batch + [{"kind": "info", "text": "[train_step] epoch " + str(epoch) + " running…"}];
                    append_logs(batch);
                    batch = [];
                    wf: dict = get_workflow();
                    result: dict = await train_step(
                        workflow=wf,
                        initial_input=inp,
                        expected_ground_truth=gt
                    );
                    if result["error"] {
                        batch = batch + [{"kind": "error", "text": "[RL] " + str(result["error"])}];
                        continue;
                    }
                    trace: list = result["execution_trace"] as list if result["execution_trace"] else [];
                    for t in trace {
                        batch = batch + [{"kind": "walker", "text": format_trace_line(wf, t as dict)}];
                    }
                    score_f: float = float(result["critic_score"]);
                    arrow = "";
                    if prev_score >= 0.0 {
                        if score_f > prev_score + 0.001 {
                            arrow = " ▲";
                        } elif score_f < prev_score - 0.001 {
                            arrow = " ▼";
                        } else {
                            arrow = " →";
                        }
                    }
                    prev_score = score_f;
                    batch = batch + [{
                        "kind": "score",
                        "text": "[RL] critic_score = " + str(result["critic_score"]) + arrow
                    }];
                    if result["analysis_log"] {
                        batch = batch + [{"kind": "info", "text": "[RL] " + str(result["analysis_log"])}];
                    }
                    updated: list = result["updated_nodes"] as list if result["updated_nodes"] else [];
                    muts: list = result["prompt_mutations"] as list if result["prompt_mutations"] else [];
                    for m in muts {
                        md = m as dict;
                        mid = str(md["node_id"]);
                        ver_s = "?";
                        for u in updated {
                            ud = u as dict;
                            if str(ud["node_id"]) == mid {
                                pc: any = ud["prompt_config"];
                                if pc and pc["prompt_version"] {
                                    ver_s = "v" + str(pc["prompt_version"]);
                                }
                            }
                        }
                        batch = batch + [{
                            "kind": "mutation",
                            "text": "[PromptRehydrator] " + mid + " → " + ver_s
                        }];
                    }
                    apply_updated_nodes(updated);
                    if score_f >= 0.9 {
                        batch = batch + [{"kind": "score", "text": "[RL] target score reached — stopping pair"}];
                        break;
                    }
                }
            }
            if train_control["active"] {
                batch = batch + [{"kind": "info", "text": "[train] complete"}];
            }
        } except Exception as err {
            batch = batch + [{"kind": "error", "text": "[train] " + str(err)}];
        }
        if len(batch) > 0 {
            append_logs(batch);
        }
        train_control["active"] = False;
        set_running(False);
    }

    def on_stop(_e: MouseEvent) {
        request_stop();
    }

    run_bg: str = "#2563eb" if not running else "#334155";
    train_bg: str = "#059669" if not running else "#334155";

    return <aside
        style={{
            "width": "340px",
            "flexShrink": "0",
            "height": "100%",
            "background": "#0b1220",
            "borderLeft": "1px solid #1e293b",
            "color": "#e2e8f0",
            "display": "flex",
            "flexDirection": "column",
            "fontFamily": "system-ui, sans-serif"
        }}
    >
        <div style={{"padding": "14px 14px 8px", "borderBottom": "1px solid #1e293b"}}>
            <div style={{"fontWeight": "700", "fontSize": "15px"}}>Training Console</div>
            <div style={{"fontSize": "12px", "color": "#94a3b8", "marginTop": "4px"}}>
                {str(workflow["workflow_name"]) if workflow and workflow["workflow_name"] else "Workflow"}
            </div>
        </div>

        <div style={{"padding": "12px 14px", "borderBottom": "1px solid #1e293b"}}>
            <div style={{"fontSize": "11px", "color": "#94a3b8", "marginBottom": "6px", "textTransform": "uppercase"}}>
                Dataset
            </div>
            <textarea
                value={dataset_text}
                onChange={on_dataset_change}
                rows={7}
                style={{
                    "width": "100%",
                    "boxSizing": "border-box",
                    "background": "#020617",
                    "color": "#e2e8f0",
                    "border": "1px solid #334155",
                    "borderRadius": "8px",
                    "padding": "8px",
                    "fontFamily": "ui-monospace, monospace",
                    "fontSize": "11px"
                }}
            />
            <div style={{"display": "flex", "gap": "8px", "marginTop": "10px"}}>
                <button
                    type="button"
                    disabled={running}
                    onClick={on_run_once}
                    style={{
                        "padding": "8px 12px",
                        "borderRadius": "6px",
                        "border": "none",
                        "cursor": "pointer",
                        "fontWeight": "600",
                        "fontSize": "13px",
                        "background": run_bg,
                        "color": "white",
                        "flex": "1"
                    }}
                >Run Once</button>
                <button
                    type="button"
                    disabled={running}
                    onClick={on_train}
                    style={{
                        "padding": "8px 12px",
                        "borderRadius": "6px",
                        "border": "none",
                        "cursor": "pointer",
                        "fontWeight": "600",
                        "fontSize": "13px",
                        "background": train_bg,
                        "color": "white",
                        "flex": "1"
                    }}
                >Train</button>
                <button
                    type="button"
                    onClick={on_stop}
                    style={{
                        "padding": "8px 12px",
                        "borderRadius": "6px",
                        "border": "none",
                        "cursor": "pointer",
                        "fontWeight": "600",
                        "fontSize": "13px",
                        "background": "#7f1d1d",
                        "color": "white"
                    }}
                >Stop</button>
            </div>
        </div>

        <div style={{"padding": "12px 14px", "borderBottom": "1px solid #1e293b"}}>
            <div style={{"fontSize": "11px", "color": "#94a3b8", "marginBottom": "6px", "textTransform": "uppercase"}}>
                Last output
            </div>
            <div style={{
                "minHeight": "48px",
                "background": "#020617",
                "border": "1px solid #1e293b",
                "borderRadius": "8px",
                "padding": "8px",
                "fontSize": "12px",
                "whiteSpace": "pre-wrap"
            }}>
                {last_output if last_output else "—"}
            </div>
        </div>

        <div style={{"flex": "1", "overflow": "auto", "padding": "12px 14px"}}>
            <div style={{"fontSize": "11px", "color": "#94a3b8", "marginBottom": "8px", "textTransform": "uppercase"}}>
                Logs
            </div>
            {if len(logs) == 0 {
                <div style={{"fontSize": "12px", "color": "#64748b"}}>No events yet.</div>
            }}
            {for (i, log_entry) in enumerate(logs) {
                kind_s: str = str((log_entry as dict)["kind"]) if (log_entry as dict)["kind"] else "info";
                text_s: str = str((log_entry as dict)["text"]) if (log_entry as dict)["text"] else "";
                <div
                    key={i}
                    style={{
                        "fontFamily": "ui-monospace, monospace",
                        "fontSize": "11px",
                        "color": log_color(kind_s),
                        "marginBottom": "6px",
                        "lineHeight": "1.4"
                    }}
                >{text_s}</div>
            }}
        </div>
    </aside>;
}
