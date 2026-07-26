"""Persisted WorkflowDefinition library (not the execution graph — D2)."""

import from datetime { datetime }
import from .flow_grammar { validate_flow }

node WorkflowDoc {
    has workflow_id: str = "";
    has name: str = "";
    has body: dict = {};
    has updated_at: str = "";
}

def list_workflows() -> list {
    out: list = [];
    for d in [root -->][?:WorkflowDoc] {
        out = out + [{
            "workflow_id": d.workflow_id,
            "name": d.name,
            "updated_at": d.updated_at
        }];
    }
    return out;
}

def get_workflow(workflow_id: str) -> dict {
    for d in [root -->][?:WorkflowDoc] {
        if d.workflow_id == workflow_id {
            return {
                "workflow_id": d.workflow_id,
                "name": d.name,
                "updated_at": d.updated_at,
                "body": d.body
            };
        }
    }
    return {};
}

def save_workflow(workflow: dict) -> dict {
    v = validate_flow(workflow);
    if not v["ok"] {
        return {"ok": False, "errors": v["errors"], "workflow_id": ""};
    }
    wid = str(workflow["workflow_id"]) if workflow["workflow_id"] else "";
    if wid == "" {
        return {"ok": False, "errors": ["workflow_id required"], "workflow_id": ""};
    }
    name = str(workflow["workflow_name"]) if workflow["workflow_name"] else wid;
    stamp = datetime.now().strftime("%Y-%m-%dT%H:%M:%SZ");
    for d in [root -->][?:WorkflowDoc] {
        if d.workflow_id == wid {
            d.name = name;
            d.body = workflow;
            d.updated_at = stamp;
            return {"ok": True, "errors": [], "workflow_id": wid};
        }
    }
    root ++> WorkflowDoc(
        workflow_id=wid,
        name=name,
        body=workflow,
        updated_at=stamp
    );
    return {"ok": True, "errors": [], "workflow_id": wid};
}

def delete_workflow(workflow_id: str) -> dict {
    for d in [root -->][?:WorkflowDoc] {
        if d.workflow_id == workflow_id {
            del d;
            return {"ok": True, "errors": []};
        }
    }
    return {"ok": False, "errors": ["workflow not found: " + workflow_id]};
}
