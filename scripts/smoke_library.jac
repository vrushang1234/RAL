
import json;
import from endpoints { save_workflow, list_workflows, get_workflow, delete_workflow, validate_workflow }
with entry {
    wf = json.loads(open("fixtures/demo_workflow.json").read());
    print("validate", validate_workflow(wf));
    r = save_workflow(wf);
    print("save", r);
    print("list", list_workflows());
    g = get_workflow(str(wf["workflow_id"]));
    print("get name", g["name"] if g else None);
}
