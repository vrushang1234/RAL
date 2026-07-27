"""Stateful shell: WorkflowDefinition CRUD + canvas + library + training console."""

sv import from endpoints {
    list_workflows,
    get_workflow,
    save_workflow,
    delete_workflow
}

import from .demo_workflow { DEMO_WORKFLOW, DEMO_DATASET, EVAL_MATRIX }  # demo_workflow.cl.jac
import from .wf_sre_incident { SRE_WORKFLOW, SRE_DATASET, SRE_EVAL_MATRIX }
import from .wf_recruiting { RECRUITING_WORKFLOW, RECRUITING_DATASET, RECRUITING_EVAL_MATRIX }
import from .wf_research_memo { RESEARCH_WORKFLOW, RESEARCH_DATASET, RESEARCH_EVAL_MATRIX }
import from .flow_grammar { validate_flow }  # flow_grammar.cl.jac
import from .node_templates { make_node, edge_allowed }  # node_templates.cl.jac
import from .TrainingConsole { TrainingConsole }
import from .EvalDashboard { EvalDashboard }
import from .NodeInspector { NodeInspector }
import from .FlowCanvas { FlowCanvas }

# Built-in example workflows seeded into the library on load; protected from Delete.
glob SEED_WORKFLOWS: list = [DEMO_WORKFLOW, SRE_WORKFLOW, RECRUITING_WORKFLOW, RESEARCH_WORKFLOW];

def is_seeded_workflow(workflow_id: str) -> bool {
    for wf_any in SEED_WORKFLOWS {
        if str((wf_any as dict)["workflow_id"]) == workflow_id {
            return True;
        }
    }
    return False;
}

def dataset_for_workflow(workflow_id: str) -> list {
    if workflow_id == "wf_sre_incident" {
        return SRE_DATASET;
    } elif workflow_id == "wf_recruiting" {
        return RECRUITING_DATASET;
    } elif workflow_id == "wf_research_memo" {
        return RESEARCH_DATASET;
    }
    return DEMO_DATASET;
}

def eval_matrix_for_workflow(workflow_id: str) -> list {
    if workflow_id == "wf_sre_incident" {
        return SRE_EVAL_MATRIX;
    } elif workflow_id == "wf_recruiting" {
        return RECRUITING_EVAL_MATRIX;
    } elif workflow_id == "wf_research_memo" {
        return RESEARCH_EVAL_MATRIX;
    }
    return EVAL_MATRIX;
}

def:pub AppShell -> JsxElement {
    has workflow: dict = DEMO_WORKFLOW;
    has workflow_box: dict = {"current": DEMO_WORKFLOW};
    has train_control: dict = {"active": False};
    has logs: list = [];
    has selected_node_id: str = "";
    has running: bool = False;
    has last_output: str = "";
    has library: list = [];
    has drafts: list = [];
    has grammar_errors: list = [];
    has id_counter: int = 1;
    has load_select: str = "wf_demo_triage";
    has show_eval: bool = False;

    def blank_workflow(workflow_id: str, name: str) -> dict {
        return {
            "schema_version": "1.0.0",
            "workflow_id": workflow_id,
            "workflow_name": name,
            "workflow_version": 1,
            "configuration_hash": None,
            "status": "DRAFT",
            "description": "",
            "entry_node_id": "",
            "output_node_id": "",
            "input_schema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"input": {"type": "string"}},
                "required": ["input"]
            },
            "output_schema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"output": {"type": "string"}},
                "required": ["output"]
            },
            "global_config": DEMO_WORKFLOW["global_config"],
            "tool_catalog": [],
            "skill_catalog": [],
            "nodes": [],
            "edges": [],
            "metadata": {
                "created_at": "2026-07-26T00:00:00Z",
                "updated_at": "2026-07-26T00:00:00Z",
                "created_by": "user",
                "tags": []
            }
        };
    }

    def replace_workflow(next_wf: dict) {
        workflow_box["current"] = next_wf;
        workflow = next_wf;
        v = validate_flow(next_wf);
        grammar_errors = v["errors"] as list if v["errors"] else [];
        remember_draft(next_wf);
    }

    def remember_draft(wf: dict) {
        wid = str(wf["workflow_id"]) if wf["workflow_id"] else "";
        if wid == "" or is_seeded_workflow(wid) {
            return;
        }
        in_lib: bool = False;
        for item in library {
            if str((item as dict)["workflow_id"]) == wid {
                in_lib = True;
            }
        }
        if in_lib {
            drop_draft(wid);
            return;
        }
        updated: list = [];
        found: bool = False;
        for d in drafts {
            dd: dict = d as dict;
            if str(dd["workflow_id"]) == wid {
                updated = updated + [{
                    "workflow_id": wid,
                    "name": str(wf["workflow_name"]) + " (unsaved)",
                    "body": wf
                }];
                found = True;
            } else {
                updated = updated + [dd];
            }
        }
        if not found {
            updated = updated + [{
                "workflow_id": wid,
                "name": str(wf["workflow_name"]) + " (unsaved)",
                "body": wf
            }];
        }
        drafts = updated;
    }

    def drop_draft(workflow_id: str) {
        kept: list = [];
        for d in drafts {
            if str((d as dict)["workflow_id"]) != workflow_id {
                kept = kept + [d];
            }
        }
        drafts = kept;
    }

    def find_draft(workflow_id: str) -> any {
        for d in drafts {
            if str((d as dict)["workflow_id"]) == workflow_id {
                return d;
            }
        }
        return None;
    }

    def library_options() -> list {
        opts: list = [];
        seen: dict = {};
        for item in library {
            wid = str((item as dict)["workflow_id"]);
            seen[wid] = True;
            opts = opts + [item];
        }
        for d in drafts {
            dd: dict = d as dict;
            wid = str(dd["workflow_id"]);
            if wid not in seen {
                opts = opts + [{
                    "workflow_id": wid,
                    "name": str(dd["name"]),
                    "updated_at": ""
                }];
            }
        }
        return opts;
    }

    def current_workflow() -> dict {
        return workflow_box["current"] as dict;
    }

    def append_logs(entries: list) {
        if not entries {
            return;
        }
        logs = logs + entries;
    }

    def append_log(kind: str, text: str) {
        logs = logs + [{"kind": kind, "text": text}];
    }

    def on_select_node(node_id: str) {
        selected_node_id = node_id;
    }

    def on_close_inspector() {
        selected_node_id = "";
    }

    def count_kind(base: dict, kind: str) -> int {
        n = 0;
        for nitem in (base["nodes"] as list) {
            if str(nitem["type"]) == kind {
                n = n + 1;
            }
        }
        return n;
    }

    def kind_of(base: dict, nid: str) -> str {
        for nitem in (base["nodes"] as list) {
            if str(nitem["node_id"]) == nid {
                return str(nitem["type"]);
            }
        }
        return "";
    }

    def rebuild_workflow(base: dict, new_nodes: list, new_edges: list) -> dict {
        entry = str(base["entry_node_id"]);
        output = str(base["output_node_id"]);
        for nitem in new_nodes {
            if str(nitem["type"]) == "Trigger" {
                entry = str(nitem["node_id"]);
            }
            if str(nitem["type"]) == "Aggregator" {
                output = str(nitem["node_id"]);
            }
        }
        return {
            "schema_version": base["schema_version"],
            "workflow_id": base["workflow_id"],
            "workflow_name": base["workflow_name"],
            "workflow_version": base["workflow_version"],
            "configuration_hash": base["configuration_hash"],
            "status": base["status"],
            "description": base["description"],
            "entry_node_id": entry,
            "output_node_id": output,
            "input_schema": base["input_schema"],
            "output_schema": base["output_schema"],
            "global_config": base["global_config"],
            "tool_catalog": base["tool_catalog"],
            "skill_catalog": base["skill_catalog"],
            "nodes": new_nodes,
            "edges": new_edges,
            "metadata": base["metadata"]
        };
    }

    def on_update_prompt(node_id: str, new_prompt: str) {
        base: dict = current_workflow();
        new_nodes: list = [];
        for n in (base["nodes"] as list) {
            if n["node_id"] == node_id {
                pc: any = n["prompt_config"];
                if pc {
                    new_pc: dict = {
                        "prompt_id": pc["prompt_id"],
                        "prompt_version": pc["prompt_version"],
                        "system_prompt": new_prompt,
                        "user_prompt_template": pc["user_prompt_template"],
                        "output_instructions": pc["output_instructions"],
                        "variables": pc["variables"]
                    };
                    new_nodes = new_nodes + [{
                        "node_id": n["node_id"],
                        "node_name": n["node_name"],
                        "type": n["type"],
                        "enabled": n["enabled"],
                        "fixed_role_description": n["fixed_role_description"],
                        "expected_input_schema": n["expected_input_schema"],
                        "expected_output_schema": n["expected_output_schema"],
                        "prompt_config": new_pc,
                        "model_config": n["model_config"],
                        "skill_bindings": n["skill_bindings"],
                        "tool_bindings": n["tool_bindings"],
                        "runtime_config": n["runtime_config"],
                        "type_config": n["type_config"],
                        "ui": n["ui"]
                    }];
                } else {
                    new_nodes = new_nodes + [n];
                }
            } else {
                new_nodes = new_nodes + [n];
            }
        }
        replace_workflow(rebuild_workflow(base, new_nodes, base["edges"] as list));
        append_log("info", "Updated system_prompt on " + node_id);
    }

    def on_rename_workflow(e: ChangeEvent) {
        name = str(e.target.value);
        base: dict = current_workflow();
        renamed_base: dict = {
            "schema_version": base["schema_version"],
            "workflow_id": base["workflow_id"],
            "workflow_name": name,
            "workflow_version": base["workflow_version"],
            "configuration_hash": base["configuration_hash"],
            "status": base["status"],
            "description": base["description"],
            "entry_node_id": base["entry_node_id"],
            "output_node_id": base["output_node_id"],
            "input_schema": base["input_schema"],
            "output_schema": base["output_schema"],
            "global_config": base["global_config"],
            "tool_catalog": base["tool_catalog"],
            "skill_catalog": base["skill_catalog"],
            "nodes": base["nodes"],
            "edges": base["edges"],
            "metadata": base["metadata"]
        };
        replace_workflow(rebuild_workflow(renamed_base, base["nodes"] as list, base["edges"] as list));
    }

    def on_rename_node(node_id: str, new_name: str) {
        base: dict = current_workflow();
        new_nodes: list = [];
        for n in (base["nodes"] as list) {
            if str(n["node_id"]) == node_id {
                new_nodes = new_nodes + [{
                    "node_id": n["node_id"],
                    "node_name": new_name,
                    "type": n["type"],
                    "enabled": n["enabled"],
                    "fixed_role_description": n["fixed_role_description"],
                    "expected_input_schema": n["expected_input_schema"],
                    "expected_output_schema": n["expected_output_schema"],
                    "prompt_config": n["prompt_config"],
                    "model_config": n["model_config"],
                    "skill_bindings": n["skill_bindings"],
                    "tool_bindings": n["tool_bindings"],
                    "runtime_config": n["runtime_config"],
                    "type_config": n["type_config"],
                    "ui": n["ui"]
                }];
            } else {
                new_nodes = new_nodes + [n];
            }
        }
        replace_workflow(rebuild_workflow(base, new_nodes, base["edges"] as list));
    }

    def on_nodes_change(node_id: str, x: float, y: float) {
        base: dict = current_workflow();
        new_nodes: list = [];
        for n in (base["nodes"] as list) {
            if n["node_id"] == node_id {
                old_ui: any = n["ui"] if n["ui"] else {};
                new_ui: dict = {
                    "position": {"x": x, "y": y},
                    "width": old_ui["width"] if old_ui["width"] else 280,
                    "height": old_ui["height"] if old_ui["height"] else 160,
                    "collapsed": old_ui["collapsed"] if old_ui["collapsed"] else False
                };
                new_nodes = new_nodes + [{
                    "node_id": n["node_id"],
                    "node_name": n["node_name"],
                    "type": n["type"],
                    "enabled": n["enabled"],
                    "fixed_role_description": n["fixed_role_description"],
                    "expected_input_schema": n["expected_input_schema"],
                    "expected_output_schema": n["expected_output_schema"],
                    "prompt_config": n["prompt_config"],
                    "model_config": n["model_config"],
                    "skill_bindings": n["skill_bindings"],
                    "tool_bindings": n["tool_bindings"],
                    "runtime_config": n["runtime_config"],
                    "type_config": n["type_config"],
                    "ui": new_ui
                }];
            } else {
                new_nodes = new_nodes + [n];
            }
        }
        replace_workflow(rebuild_workflow(base, new_nodes, base["edges"] as list));
    }

    def add_node(kind: str) {
        base: dict = current_workflow();
        if kind == "Trigger" and count_kind(base, "Trigger") >= 1 {
            append_log("error", "[grammar] only one Trigger allowed");
            return;
        }
        if kind == "Aggregator" and count_kind(base, "Aggregator") >= 1 {
            append_log("error", "[grammar] only one Aggregator allowed");
            return;
        }
        id_counter = id_counter + 1;
        suffix = "node";
        if kind == "Trigger" {
            suffix = "trigger";
        } elif kind == "Router" {
            suffix = "router";
        } elif kind == "WorkerAgent" {
            suffix = "agent";
        } elif kind == "Aggregator" {
            suffix = "aggregator";
        }
        nid = "n_" + suffix + "_" + str(id_counter);
        x = 80.0 + (id_counter as float) * 24.0;
        y = 80.0 + (id_counter as float) * 28.0;
        new_node = make_node(kind, nid, x, y);
        new_nodes = (base["nodes"] as list) + [new_node];
        replace_workflow(rebuild_workflow(base, new_nodes, base["edges"] as list));
        append_log("info", "[canvas] added " + kind + " " + nid);
        selected_node_id = nid;
    }

    def on_connect(src: str, tgt: str) {
        base: dict = current_workflow();
        sk = kind_of(base, src);
        tk = kind_of(base, tgt);
        if not edge_allowed(sk, tk) {
            append_log("error", "[grammar] illegal edge " + sk + " → " + tk);
            return;
        }
        for e in (base["edges"] as list) {
            if str(e["source_node_id"]) == src and str(e["target_node_id"]) == tgt {
                append_log("info", "[canvas] edge already exists");
                return;
            }
        }
        id_counter = id_counter + 1;
        eid = "e_" + str(id_counter);
        cond_type = "ALWAYS";
        route_val: any = None;
        label: any = None;
        if sk == "Router" {
            cond_type = "ROUTE_VALUE";
            route_val = "route_" + str(id_counter);
            label = route_val;
        } elif sk == "WorkerAgent" and tk == "Aggregator" {
            cond_type = "ON_SUCCESS";
        }
        new_edge: dict = {
            "edge_id": eid,
            "source_node_id": src,
            "target_node_id": tgt,
            "condition": {"type": cond_type, "expression": None, "route_value": route_val},
            "data_mapping": {"source": "$", "target": "$"},
            "ui": {"label": label}
        };
        new_edges = (base["edges"] as list) + [new_edge];
        replace_workflow(rebuild_workflow(base, base["nodes"] as list, new_edges));
        append_log("info", "[canvas] connected " + src + " → " + tgt);
    }

    def on_delete_edge(edge_id: str) {
        base: dict = current_workflow();
        new_edges: list = [];
        for e in (base["edges"] as list) {
            if str(e["edge_id"]) != edge_id {
                new_edges = new_edges + [e];
            }
        }
        replace_workflow(rebuild_workflow(base, base["nodes"] as list, new_edges));
        append_log("info", "[canvas] deleted edge " + edge_id);
    }

    def on_delete_node(node_id: str) {
        base: dict = current_workflow();
        new_nodes: list = [];
        for n in (base["nodes"] as list) {
            if str(n["node_id"]) != node_id {
                new_nodes = new_nodes + [n];
            }
        }
        new_edges: list = [];
        for e in (base["edges"] as list) {
            if str(e["source_node_id"]) != node_id and str(e["target_node_id"]) != node_id {
                new_edges = new_edges + [e];
            }
        }
        replace_workflow(rebuild_workflow(base, new_nodes, new_edges));
        if selected_node_id == node_id {
            selected_node_id = "";
        }
        append_log("info", "[canvas] deleted node " + node_id);
    }

    def set_running(value: bool) {
        running = value;
        if not value {
            train_control["active"] = False;
        }
    }

    def set_last_output(value: str) {
        last_output = value;
    }

    def apply_updated_nodes(updated: list) {
        if not updated {
            return;
        }
        updates: dict = {};
        for u in updated {
            updates[u["node_id"]] = u["prompt_config"];
        }
        base: dict = current_workflow();
        new_nodes: list = [];
        for n in (base["nodes"] as list) {
            if n["node_id"] in updates {
                new_nodes = new_nodes + [{
                    "node_id": n["node_id"],
                    "node_name": n["node_name"],
                    "type": n["type"],
                    "enabled": n["enabled"],
                    "fixed_role_description": n["fixed_role_description"],
                    "expected_input_schema": n["expected_input_schema"],
                    "expected_output_schema": n["expected_output_schema"],
                    "prompt_config": updates[n["node_id"]],
                    "model_config": n["model_config"],
                    "skill_bindings": n["skill_bindings"],
                    "tool_bindings": n["tool_bindings"],
                    "runtime_config": n["runtime_config"],
                    "type_config": n["type_config"],
                    "ui": n["ui"]
                }];
            } else {
                new_nodes = new_nodes + [n];
            }
        }
        replace_workflow(rebuild_workflow(base, new_nodes, base["edges"] as list));
    }

    def request_stop() {
        train_control["active"] = False;
        running = False;
        append_logs([{"kind": "info", "text": "[stop] training interrupted"}]);
    }

    async def refresh_library() {
        try {
            res: dict = await list_workflows();
            items: list = res["items"] as list if res["items"] else [];
            library = items;
        } except Exception as err {
            append_log("error", "[library] list failed: " + str(err));
        }
    }

    async can with entry {
        replace_workflow(DEMO_WORKFLOW);
        load_select = "wf_demo_triage";
        try {
            res: dict = await list_workflows();
            items: list = res["items"] as list if res["items"] else [];
            seeded_any: bool = False;
            for wf_any in SEED_WORKFLOWS {
                wf_seed: dict = wf_any as dict;
                seed_id = str(wf_seed["workflow_id"]);
                present: bool = False;
                for item in items {
                    if str((item as dict)["workflow_id"]) == seed_id {
                        present = True;
                    }
                }
                if not present {
                    seeded = await save_workflow(wf_seed);
                    if seeded["ok"] {
                        seeded_any = True;
                        append_log("info", "[library] seeded " + seed_id);
                    }
                }
            }
            if seeded_any {
                res2: dict = await list_workflows();
                items = res2["items"] as list if res2["items"] else [];
            }
            library = items;
            demo_res = await get_workflow("wf_demo_triage");
            if demo_res and demo_res["body"] {
                replace_workflow(demo_res["body"] as dict);
                load_select = "wf_demo_triage";
            }
            append_log("info", "[library] loaded " + str(len(items)) + " workflow(s)");
        } except Exception as err {
            append_log("error", "[library] seed/list failed: " + str(err));
            replace_workflow(DEMO_WORKFLOW);
            load_select = "wf_demo_triage";
        }
    }

    async def on_save(_e: MouseEvent) {
        wf = current_workflow();
        v = validate_flow(wf);
        if not v["ok"] {
            append_log("error", "[grammar] cannot save: " + str(v["errors"]));
            grammar_errors = v["errors"] as list;
            return;
        }
        try {
            res = await save_workflow(wf);
            if res["ok"] {
                saved_id = str(res["workflow_id"]);
                drop_draft(saved_id);
                append_log("info", "[library] saved " + saved_id);
                load_select = saved_id;
                await refresh_library();
            } else {
                append_log("error", "[library] save rejected: " + str(res["errors"]));
            }
        } except Exception as err {
            append_log("error", "[library] " + str(err));
        }
    }

    async def on_load(workflow_id: str) {
        if workflow_id == "" {
            return;
        }
        draft = find_draft(workflow_id);
        if draft {
            replace_workflow((draft as dict)["body"] as dict);
            selected_node_id = "";
            load_select = workflow_id;
            append_log("info", "[library] opened draft " + workflow_id);
            return;
        }
        try {
            res = await get_workflow(workflow_id);
            if res and res["body"] {
                drop_draft(workflow_id);
                replace_workflow(res["body"] as dict);
                selected_node_id = "";
                load_select = workflow_id;
                append_log("info", "[library] loaded " + workflow_id);
            } else {
                append_log("error", "[library] not found: " + workflow_id);
                load_select = str(current_workflow()["workflow_id"]);
                await refresh_library();
            }
        } except Exception as err {
            append_log("error", "[library] " + str(err));
            load_select = str(current_workflow()["workflow_id"]);
        }
    }

    async def on_delete_workflow(_e: MouseEvent) {
        wid = str(current_workflow()["workflow_id"]);
        in_lib: bool = False;
        for item in library {
            if str((item as dict)["workflow_id"]) == wid {
                in_lib = True;
            }
        }
        if not in_lib {
            drop_draft(wid);
            append_log("info", "[library] discarded unsaved draft " + wid);
            replace_workflow(DEMO_WORKFLOW);
            selected_node_id = "";
            load_select = "wf_demo_triage";
            return;
        }
        if is_seeded_workflow(wid) {
            append_log("error", "[library] built-in example workflows cannot be deleted — use New for a blank canvas");
            return;
        }
        try {
            res = await delete_workflow(wid);
            if res["ok"] {
                drop_draft(wid);
                append_log("info", "[library] deleted " + wid);
                replace_workflow(DEMO_WORKFLOW);
                selected_node_id = "";
                load_select = "wf_demo_triage";
                await refresh_library();
            } else {
                append_log("error", "[library] " + str(res["errors"]));
            }
        } except Exception as err {
            append_log("error", "[library] " + str(err));
        }
    }

    def on_new(_e: MouseEvent) {
        id_counter = id_counter + 1;
        next_id = "wf_custom_" + str(id_counter);
        next_name = "Untitled " + str(id_counter);
        replace_workflow(blank_workflow(next_id, next_name));
        selected_node_id = "";
        load_select = next_id;
        append_log("info", "[library] new blank canvas " + next_id + " — add nodes, then Save");
    }

    def on_toggle_eval(_e: MouseEvent) {
        show_eval = not show_eval;
    }

    def on_close_eval() {
        show_eval = False;
    }

    def add_trigger(_e: MouseEvent) { add_node("Trigger"); }
    def add_router(_e: MouseEvent) { add_node("Router"); }
    def add_agent(_e: MouseEvent) { add_node("WorkerAgent"); }
    def add_aggregator(_e: MouseEvent) { add_node("Aggregator"); }

    async def on_load_change(e: ChangeEvent) {
        wid = str(e.target.value);
        if wid != "" {
            await on_load(wid);
        }
    }

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
    eval_btn_label: str = "Eval";
    if show_eval {
        eval_btn_label = "Hide Eval";
    }

    return <div style={{
        "display": "flex",
        "height": "100vh",
        "width": "100vw",
        "overflow": "hidden",
        "background": "#020617",
        "fontFamily": "system-ui, sans-serif"
    }}>
        <div style={{"flex": "1", "display": "flex", "flexDirection": "column", "minWidth": "0"}}>
            <header style={{
                "padding": "10px 16px",
                "borderBottom": "1px solid #1e293b",
                "color": "#f8fafc",
                "display": "flex",
                "flexDirection": "column",
                "gap": "8px"
            }}>
                <div style={{"display": "flex", "alignItems": "center", "gap": "12px"}}>
                    <span style={{"fontWeight": "800", "letterSpacing": "0.04em"}}>RAL</span>
                    <input
                        type="text"
                        value={str(workflow["workflow_name"]) if workflow["workflow_name"] else ""}
                        onChange={on_rename_workflow}
                        placeholder="Workflow name"
                        style={{
                            "flex": "1",
                            "maxWidth": "360px",
                            "background": "#020617",
                            "color": "#f8fafc",
                            "border": "1px solid #334155",
                            "borderRadius": "6px",
                            "padding": "6px 10px",
                            "fontSize": "13px",
                            "fontWeight": "600"
                        }}
                    />
                </div>
                <div style={{"display": "flex", "flexWrap": "wrap", "gap": "8px", "alignItems": "center"}}>
                    <button type="button" style={btn} onClick={on_new}>New</button>
                    <button type="button" style={btn} onClick={on_save}>Save</button>
                    <button type="button" style={btn} onClick={on_delete_workflow}>Delete</button>
                    <select
                        value={load_select}
                        onChange={on_load_change}
                        style={{
                            "background": "#020617",
                            "color": "#e2e8f0",
                            "border": "1px solid #334155",
                            "borderRadius": "6px",
                            "padding": "6px 8px",
                            "fontSize": "12px"
                        }}
                    >
                        <option value="">Load…</option>
                        {for item in library_options() {
                            <option
                                key={str((item as dict)["workflow_id"])}
                                value={str((item as dict)["workflow_id"])}
                            >{str((item as dict)["name"])}</option>
                        }}
                    </select>
                    <span style={{"color": "#475569", "margin": "0 4px"}}>|</span>
                    <button type="button" style={btn} onClick={add_trigger}>+ Trigger</button>
                    <button type="button" style={btn} onClick={add_router}>+ Router</button>
                    <button type="button" style={btn} onClick={add_agent}>+ Agent</button>
                    <button type="button" style={btn} onClick={add_aggregator}>+ Aggregator</button>
                    <span style={{"color": "#475569", "margin": "0 4px"}}>|</span>
                    <button type="button" style={btn} onClick={on_toggle_eval}>
                        {eval_btn_label}
                    </button>
                </div>
                {if len(grammar_errors) > 0 {
                    <div style={{"fontSize": "12px", "color": "#fbbf24"}}>
                        {"Flow incomplete/invalid: " + str(grammar_errors)}
                    </div>
                }}
            </header>
            <FlowCanvas
                workflow={workflow}
                on_select_node={on_select_node}
                on_nodes_change={on_nodes_change}
                on_connect={on_connect}
                on_delete_edge={on_delete_edge}
                on_delete_node={on_delete_node}
            />
        </div>
        {if show_eval {
            <EvalDashboard
                key={"eval_" + str(workflow["workflow_id"])}
                eval_matrix={eval_matrix_for_workflow(str(workflow["workflow_id"]))}
                get_workflow={current_workflow}
                apply_updated_nodes={apply_updated_nodes}
                append_logs={append_logs}
                running={running}
                set_running={set_running}
                train_control={train_control}
                request_stop={request_stop}
                on_close={on_close_eval}
            />
        } else {
            <TrainingConsole
                key={"train_" + str(workflow["workflow_id"])}
                workflow={workflow}
                dataset={dataset_for_workflow(str(workflow["workflow_id"]))}
                logs={logs}
                running={running}
                last_output={last_output}
                train_control={train_control}
                append_logs={append_logs}
                apply_updated_nodes={apply_updated_nodes}
                get_workflow={current_workflow}
                set_running={set_running}
                set_last_output={set_last_output}
                request_stop={request_stop}
            />
        }}
        {if selected_node_id != "" {
            <NodeInspector
                workflow={workflow}
                node_id={selected_node_id}
                on_update_prompt={on_update_prompt}
                on_rename_node={on_rename_node}
                on_delete_node={on_delete_node}
                on_close={on_close_inspector}
            />
        }}
    </div>;
}
