"""RL eval matrix dashboard — baseline / train / after comparison."""

sv import from endpoints { eval_cell, train_step, log_eval_report }

def:pub EvalDashboard(
    eval_matrix: list,
    get_workflow: Callable[[], dict],
    apply_updated_nodes: Callable[[list], None],
    append_logs: Callable[[list], None],
    running: bool,
    set_running: Callable[[bool], None],
    train_control: dict,
    request_stop: Callable[[], None],
    on_close: Callable[[], None]
) -> JsxElement {
    has baseline: dict = {};
    has after: dict = {};
    has status: str = "Train scores Before → mutates → scores After (or use Baseline / After alone).";
    has last_mutations: int = 0;
    has worker_versions: dict = {};
    has versions_label: str = "";
    has activity: list = [];

    def empty_cell_result() -> dict {
        return {
            "critic_score": 0.0,
            "route_ok": False,
            "worker_hit": False,
            "route": "",
            "error": ""
        };
    }

    # Jac has→useState: mutate-in-place on dicts does not re-render; replace the map.
    def with_cell(phase_map: dict, tid: str, cell: dict) -> dict {
        nxt: dict = {};
        for k in phase_map.keys() {
            nxt[str(k)] = phase_map[k];
        }
        nxt[tid] = cell;
        return nxt;
    }

    def push_activity(line: str) {
        nxt: list = activity + [line];
        if len(nxt) > 12 {
            trimmed: list = [];
            start = len(nxt) - 12;
            i = 0;
            for item in nxt {
                if i >= start {
                    trimmed = trimmed + [item];
                }
                i = i + 1;
            }
            activity = trimmed;
        } else {
            activity = nxt;
        }
        append_logs([{"kind": "info", "text": "[eval] " + line}]);
    }

    def snapshot_versions(wf: dict) {
        vers: dict = {};
        label = "";
        for n_any in (wf["nodes"] as list) {
            n = n_any as dict;
            if str(n["type"]) != "WorkerAgent" {
                continue;
            }
            pc: any = n["prompt_config"] if n["prompt_config"] else None;
            ver = 0;
            if pc and pc["prompt_version"] {
                ver = int(pc["prompt_version"]);
            }
            vers[str(n["node_id"])] = ver;
            if label != "" {
                label = label + "/";
            }
            label = label + "v" + str(ver);
        }
        worker_versions = vers;
        versions_label = label;
    }

    def mean_score(phase_map: dict) -> float {
        if not phase_map {
            return 0.0;
        }
        total = 0.0;
        n = 0;
        for tid in phase_map.keys() {
            cell = phase_map[tid] as dict;
            total = total + float(cell["critic_score"]);
            n = n + 1;
        }
        if n == 0 {
            return 0.0;
        }
        return total / float(n);
    }

    def route_accuracy(phase_map: dict) -> float {
        if not phase_map {
            return 0.0;
        }
        ok = 0;
        n = 0;
        for tid in phase_map.keys() {
            cell = phase_map[tid] as dict;
            n = n + 1;
            if cell["route_ok"] {
                ok = ok + 1;
            }
        }
        if n == 0 {
            return 0.0;
        }
        return float(ok) / float(n);
    }

    def fmt4(x: float) -> str {
        return str(round(x, 4));
    }

    def cell_from_eval(task: dict, res: dict, err: str) -> dict {
        if err {
            return {
                "critic_score": 0.0,
                "route_ok": False,
                "worker_hit": False,
                "route": "",
                "error": err,
                "category": str(task["category"]),
                "difficulty": str(task["difficulty"])
            };
        }
        return {
            "critic_score": float(res["critic_score"]) if res["critic_score"] else 0.0,
            "route_ok": True if res["route_ok"] else False,
            "worker_hit": True if res["worker_hit"] else False,
            "route": str(res["route"]) if res["route"] else "",
            "error": str(res["error"]) if res["error"] else "",
            "category": str(task["category"]),
            "difficulty": str(task["difficulty"])
        };
    }

    async def persist_report() {
        eval_payload: dict = {
            "baseline": baseline,
            "after": after,
            "summary": {
                "mean_before": mean_score(baseline),
                "mean_after": mean_score(after),
                "delta": mean_score(after) - mean_score(baseline),
                "route_acc_before": route_accuracy(baseline),
                "route_acc_after": route_accuracy(after),
                "worker_prompt_versions": worker_versions,
                "mutations_last_train": last_mutations
            }
        };
        try {
            res = await log_eval_report(eval_payload);
            if res and res["path"] {
                push_activity("saved " + str(res["path"]));
            }
        } except Exception as err {
            push_activity("persist failed: " + str(err));
        }
    }

    async def score_one(task: dict) -> dict {
        try {
            res = await eval_cell(
                workflow=get_workflow(),
                initial_input=str(task["initial_input"]),
                expected_ground_truth=str(task["expected_ground_truth"]),
                expected_route=str(task["expected_route"]),
                expected_worker_id=str(task["expected_worker_id"])
            );
            if res["error"] {
                return cell_from_eval(task, res, str(res["error"]));
            }
            return cell_from_eval(task, res, "");
        } except Exception as err {
            return cell_from_eval(task, {}, str(err));
        }
    }

    """Score every matrix cell into baseline or after; updates the table after each cell."""
    async def score_matrix(phase: str) -> dict {
        total = len(eval_matrix);
        idx = 0;
        for task_any in eval_matrix {
            if not train_control["active"] {
                break;
            }
            task = task_any as dict;
            tid = str(task["task_id"]);
            idx = idx + 1;
            status = "Scoring " + phase + " " + str(idx) + "/" + str(total) + ": " + tid;
            push_activity(status);
            cell = await score_one(task);
            if phase == "baseline" {
                baseline = with_cell(baseline, tid, cell);
            } else {
                after = with_cell(after, tid, cell);
            }
            if cell["error"] {
                push_activity(tid + " error: " + str(cell["error"]));
            } else {
                push_activity(
                    tid + " critic=" + fmt4(float(cell["critic_score"]))
                    + " route=" + str(cell["route"])
                );
            }
        }
        snapshot_versions(get_workflow());
        phase_map = baseline if phase == "baseline" else after;
        m = mean_score(phase_map);
        ra = route_accuracy(phase_map);
        status = phase + " done — mean critic=" + fmt4(m) + " route_acc=" + fmt4(ra);
        push_activity(status);
        return phase_map;
    }

    async def run_phase(phase: str) {
        if running {
            return;
        }
        train_control["active"] = True;
        set_running(True);
        if phase == "baseline" {
            baseline = {};
        } else {
            after = {};
        }
        try {
            await score_matrix(phase);
            await persist_report();
        } except Exception as err {
            status = phase + " failed: " + str(err);
            push_activity(status);
        }
        train_control["active"] = False;
        set_running(False);
    }

    async def on_baseline(_e: MouseEvent) {
        await run_phase("baseline");
    }

    async def on_after(_e: MouseEvent) {
        await run_phase("after");
    }

    async def on_train_matrix(_e: MouseEvent) {
        if running {
            return;
        }
        train_control["active"] = True;
        set_running(True);
        mut_total = 0;
        try {
            # 1) Populate Before column
            baseline = {};
            status = "Train: scoring baseline…";
            push_activity(status);
            await score_matrix("baseline");

            if not train_control["active"] {
                status = "Train stopped during baseline";
                train_control["active"] = False;
                set_running(False);
                return;
            }

            # 2) Mutate prompts on each matrix task
            total = len(eval_matrix);
            idx = 0;
            for task_any in eval_matrix {
                if not train_control["active"] {
                    status = "Train stopped";
                    break;
                }
                task = task_any as dict;
                tid = str(task["task_id"]);
                idx = idx + 1;
                status = "Training " + str(idx) + "/" + str(total) + ": " + tid;
                push_activity(status);
                result: dict = await train_step(
                    workflow=get_workflow(),
                    initial_input=str(task["initial_input"]),
                    expected_ground_truth=str(task["expected_ground_truth"])
                );
                if result["error"] {
                    push_activity(tid + " RL error: " + str(result["error"]));
                    continue;
                }
                muts: list = result["prompt_mutations"] as list if result["prompt_mutations"] else [];
                mut_total = mut_total + len(muts);
                updated: list = result["updated_nodes"] as list if result["updated_nodes"] else [];
                apply_updated_nodes(updated);
                push_activity(
                    tid + " train critic=" + str(result["critic_score"])
                    + " muts=" + str(len(muts))
                );
                if result["analysis_log"] {
                    push_activity(str(result["analysis_log"]));
                }
            }
            last_mutations = mut_total;
            snapshot_versions(get_workflow());

            if not train_control["active"] {
                status = "Train stopped — mutations=" + str(mut_total);
                await persist_report();
                train_control["active"] = False;
                set_running(False);
                return;
            }

            # 3) Populate After column with updated prompts
            after = {};
            status = "Train: scoring after…";
            push_activity(status);
            await score_matrix("after");
            status = (
                "Train complete — mutations=" + str(mut_total)
                + " · mean " + fmt4(mean_score(baseline))
                + " → " + fmt4(mean_score(after))
            );
            push_activity(status);
            await persist_report();
        } except Exception as err {
            status = "Train failed: " + str(err);
            push_activity(status);
        }
        train_control["active"] = False;
        set_running(False);
    }

    def on_clear(_e: MouseEvent) {
        baseline = {};
        after = {};
        activity = [];
        last_mutations = 0;
        status = "Cleared. Train (fills table) or Baseline → After.";
    }

    def on_stop(_e: MouseEvent) {
        request_stop();
        status = "Stop requested";
    }

    def handle_close(_e: MouseEvent) {
        on_close();
    }

    mean_b = mean_score(baseline);
    mean_a = mean_score(after);
    delta = mean_a - mean_b if after else 0.0;
    ra_b = route_accuracy(baseline);
    ra_a = route_accuracy(after);

    btn: dict = {
        "padding": "6px 10px",
        "borderRadius": "6px",
        "border": "1px solid #334155",
        "background": "#1e293b",
        "color": "#e2e8f0",
        "cursor": "pointer",
        "fontSize": "12px",
        "fontWeight": "600"
    };
    btn_go: dict = {
        "padding": "6px 10px",
        "borderRadius": "6px",
        "border": "1px solid #1d4ed8",
        "background": "#2563eb" if not running else "#334155",
        "color": "#fff",
        "cursor": "pointer",
        "fontSize": "12px",
        "fontWeight": "600"
    };
    btn_train: dict = {
        "padding": "6px 10px",
        "borderRadius": "6px",
        "border": "1px solid #047857",
        "background": "#059669" if not running else "#334155",
        "color": "#fff",
        "cursor": "pointer",
        "fontSize": "12px",
        "fontWeight": "600"
    };

    th: dict = {
        "textAlign": "left",
        "padding": "6px 8px",
        "fontSize": "11px",
        "color": "#94a3b8",
        "borderBottom": "1px solid #1e293b",
        "whiteSpace": "nowrap"
    };
    td: dict = {
        "padding": "6px 8px",
        "fontSize": "12px",
        "borderBottom": "1px solid #0f172a",
        "color": "#e2e8f0"
    };

    return <aside
        style={{
            "width": "420px",
            "flexShrink": "0",
            "height": "100%",
            "background": "#0b1220",
            "borderLeft": "1px solid #1e293b",
            "color": "#e2e8f0",
            "display": "flex",
            "flexDirection": "column",
            "fontFamily": "system-ui, sans-serif",
            "overflow": "hidden"
        }}
    >
        <div style={{
            "padding": "14px",
            "borderBottom": "1px solid #1e293b",
            "display": "flex",
            "justifyContent": "space-between",
            "alignItems": "center"
        }}>
            <div>
                <div style={{"fontWeight": "700", "fontSize": "15px"}}>Eval Dashboard</div>
                <div style={{"fontSize": "11px", "color": "#94a3b8", "marginTop": "4px"}}>
                    RL testbench matrix
                </div>
            </div>
            <button type="button" style={btn} onClick={handle_close}>Close</button>
        </div>

        <div style={{"padding": "12px 14px", "borderBottom": "1px solid #1e293b"}}>
            <div style={{"display": "flex", "flexWrap": "wrap", "gap": "8px"}}>
                <button type="button" style={btn_go} disabled={running} onClick={on_baseline}>
                    Run Baseline
                </button>
                <button type="button" style={btn_train} disabled={running} onClick={on_train_matrix}>
                    Train on Matrix
                </button>
                <button type="button" style={btn_go} disabled={running} onClick={on_after}>
                    Run After
                </button>
                <button type="button" style={btn} disabled={running} onClick={on_clear}>Clear</button>
                <button type="button" style={btn} onClick={on_stop}>Stop</button>
            </div>
            <div style={{"fontSize": "12px", "color": "#94a3b8", "marginTop": "10px"}}>{status}</div>
            {if len(activity) > 0 {
                <div style={{
                    "marginTop": "8px",
                    "maxHeight": "88px",
                    "overflow": "auto",
                    "fontSize": "11px",
                    "fontFamily": "ui-monospace, Menlo, monospace",
                    "color": "#64748b",
                    "lineHeight": "1.45"
                }}>
                    {for line in activity {
                        <div>{str(line)}</div>
                    }}
                </div>
            }}
        </div>

        <div style={{
            "padding": "12px 14px",
            "borderBottom": "1px solid #1e293b",
            "display": "grid",
            "gridTemplateColumns": "1fr 1fr",
            "gap": "10px"
        }}>
            <div>
                <div style={{"fontSize": "10px", "color": "#94a3b8", "textTransform": "uppercase"}}>
                    Mean critic
                </div>
                <div style={{"fontSize": "18px", "fontWeight": "700", "marginTop": "4px"}}>
                    {fmt4(mean_b) + " → " + fmt4(mean_a)}
                </div>
                <div style={{
                    "fontSize": "12px",
                    "color": "#4ade80" if delta >= 0.0 else "#f87171",
                    "marginTop": "2px"
                }}>
                    {"Δ " + fmt4(delta)}
                </div>
            </div>
            <div>
                <div style={{"fontSize": "10px", "color": "#94a3b8", "textTransform": "uppercase"}}>
                    Route accuracy
                </div>
                <div style={{"fontSize": "18px", "fontWeight": "700", "marginTop": "4px"}}>
                    {fmt4(ra_b) + " → " + fmt4(ra_a)}
                </div>
                <div style={{"fontSize": "12px", "color": "#94a3b8", "marginTop": "2px"}}>
                    {"prompts " + (versions_label if versions_label != "" else "—")
                        + " · mut " + str(last_mutations)}
                </div>
            </div>
        </div>

        <div style={{"flex": "1", "overflow": "auto", "padding": "8px 6px"}}>
            <table style={{"width": "100%", "borderCollapse": "collapse"}}>
                <thead>
                    <tr>
                        <th style={th}>Task</th>
                        <th style={th}>Before</th>
                        <th style={th}>After</th>
                        <th style={th}>Δ</th>
                        <th style={th}>Route</th>
                        <th style={th}>Worker</th>
                    </tr>
                </thead>
                <tbody>
                    {for task_any in eval_matrix {
                        task = task_any as dict;
                        tid = str(task["task_id"]);
                        bcell: dict = baseline[tid] as dict if tid in baseline else empty_cell_result();
                        acell: dict = after[tid] as dict if tid in after else empty_cell_result();
                        bscore = float(bcell["critic_score"]) if bcell["critic_score"] else 0.0;
                        ascore = float(acell["critic_score"]) if acell["critic_score"] else 0.0;
                        d = ascore - bscore if tid in after and tid in baseline else 0.0;
                        route_mark = "—" ;
                        if tid in after {
                            route_mark = "✓" if acell["route_ok"] else "✗";
                        } elif tid in baseline {
                            route_mark = "✓" if bcell["route_ok"] else "✗";
                        }
                        worker_mark = "—";
                        if tid in after {
                            worker_mark = "✓" if acell["worker_hit"] else "✗";
                        } elif tid in baseline {
                            worker_mark = "✓" if bcell["worker_hit"] else "✗";
                        }
                        label = str(task["category"]) + "/" + str(task["difficulty"]);
                        <tr key={tid}>
                            <td style={td}>
                                <div style={{"fontWeight": "600"}}>{tid}</div>
                                <div style={{"fontSize": "10px", "color": "#64748b"}}>{label}</div>
                            </td>
                            <td style={td}>{fmt4(bscore) if tid in baseline else "—"}</td>
                            <td style={td}>{fmt4(ascore) if tid in after else "—"}</td>
                            <td style={td}>{fmt4(d) if tid in after and tid in baseline else "—"}</td>
                            <td style={td}>{route_mark}</td>
                            <td style={td}>{worker_mark}</td>
                        </tr>
                    }}
                </tbody>
            </table>
        </div>
    </aside>;
}
