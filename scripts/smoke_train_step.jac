"""Offline smoke: train_step + mock RL + runs/ log."""

import json;
import from endpoints { train_step }

with entry {
    wf = json.loads(open("fixtures/demo_workflow.json").read());
    r = train_step(
        wf,
        "Hi, I was charged twice for my subscription this month.",
        "Refund apology."
    );
    print("score", r["critic_score"]);
    print("analysis", r["analysis_log"]);
    print("error", r["error"]);
    print("muts", r["prompt_mutations"]);
    for u in (r["updated_nodes"] as list) {
        pc = u["prompt_config"];
        if pc and "Be more concise" in str(pc["system_prompt"]) {
            print("mutated", u["node_id"], "v", pc["prompt_version"]);
        }
    }
}
