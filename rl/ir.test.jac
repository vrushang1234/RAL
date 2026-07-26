"""Tests for the workflow IR, content hashing, and validation."""

def build_support_workflow() -> WorkflowVersion {
    wf = WorkflowVersion(label="support-baseline");
    classifier = AgentSpec(
        agent_id="classifier",
        role="Classify support requests",
        model="large",
        prompt="Classify the request as billing, technical, or account.",
        max_tokens=300
    );
    support = AgentSpec(
        agent_id="support",
        role="Resolve customer problems",
        model="large",
        prompt="Resolve the customer's problem.",
        tools=["doc_search", "web_search"],
        max_tokens=1500
    );
    reviewer = AgentSpec(
        agent_id="reviewer",
        role="Review responses for correctness",
        model="large",
        prompt="Review the answer.",
        max_tokens=600
    );

    root ++> wf;
    wf +>:Entry:+> classifier;
    classifier +>:FlowsTo(to_agent="support"):+> support;
    support +>:FlowsTo(to_agent="reviewer"):+> reviewer;
    return reseal(wf);
}


def demo_constraints() -> Constraints {
    return Constraints(
        approved_tools=["doc_search", "web_search", "customer_db"],
        approved_models=["large", "small"]
    );
}


test "workflow_agents walks the whole chain in id order" {
    wf = build_support_workflow();
    ids = [a.agent_id for a in workflow_agents(wf)];
    assert ids == ["classifier", "reviewer", "support"], f"got {ids}";
}


test "content hash is stable and order-independent" {
    a = build_support_workflow();
    b = build_support_workflow();
    assert a.config_hash == b.config_hash, "identical configs must hash identically";
    assert len(a.config_hash) == 16;
}


test "content hash changes when any field changes" {
    wf = build_support_workflow();
    before = wf.config_hash;
    target = agent_by_id(wf, "classifier");
    assert target is not None;
    if target is not None {
        target.model = "small";
    }
    after = compute_hash(wf);
    assert before != after, "model swap must change the content address";
}


test "hash tracks edge conditions, not just nodes" {
    wf = build_support_workflow();
    before = compute_hash(wf);
    support = agent_by_id(wf, "support");
    assert support is not None;
    if support is not None {
        for e in [edge support ->:FlowsTo:->] {
            e.condition = "confidence < 0.72";
        }
    }
    assert compute_hash(wf) != before, "conditionalizing an edge must change the hash";
}


test "a clean workflow validates" {
    wf = build_support_workflow();
    issues = validate(wf, demo_constraints());
    assert len(issues) == 0, f"unexpected: {[i.code for i in issues]}";
}


test "unapproved tools are rejected" {
    wf = build_support_workflow();
    support = agent_by_id(wf, "support");
    assert support is not None;
    if support is not None {
        support.tools = ["doc_search", "exfiltrate"];
    }
    codes = [i.code for i in validate(wf, demo_constraints())];
    assert "E_TOOL_UNAPPROVED" in codes, f"got {codes}";
}


test "unapproved models are rejected" {
    wf = build_support_workflow();
    reviewer = agent_by_id(wf, "reviewer");
    assert reviewer is not None;
    if reviewer is not None {
        reviewer.model = "gpt-unbudgeted";
    }
    codes = [i.code for i in validate(wf, demo_constraints())];
    assert "E_MODEL_UNAPPROVED" in codes, f"got {codes}";
}


test "retries outside the allowed band are rejected" {
    wf = build_support_workflow();
    support = agent_by_id(wf, "support");
    assert support is not None;
    if support is not None {
        support.retries = 99;
    }
    codes = [i.code for i in validate(wf, demo_constraints())];
    assert "E_RETRIES" in codes, f"got {codes}";
}


test "cycles are detected and rejected" {
    wf = build_support_workflow();
    reviewer = agent_by_id(wf, "reviewer");
    classifier = agent_by_id(wf, "classifier");
    assert reviewer is not None and classifier is not None;
    if reviewer is not None and classifier is not None {
        reviewer +>:FlowsTo(to_agent="classifier"):+> classifier;
    }
    assert has_cycle(wf), "reviewer -> classifier closes a loop";
    codes = [i.code for i in validate(wf, demo_constraints())];
    assert "E_CYCLE" in codes, f"got {codes}";
    assert "E_NO_TERMINAL" in codes, f"a pure cycle also has no terminal: {codes}";
}


test "a workflow with no terminal node is rejected" {
    wf = WorkflowVersion(label="loop-only");
    solo = AgentSpec(agent_id="solo", role="r", model="small", prompt="p");
    root ++> wf;
    wf +>:Entry:+> solo;
    solo +>:FlowsTo(to_agent="solo"):+> solo;
    codes = [i.code for i in validate(wf, demo_constraints())];
    assert "E_NO_TERMINAL" in codes, f"got {codes}";
}
