"""Tests for cloning, preconditions, and mutation application."""

def demo_constraints() -> Constraints {
    return Constraints(
        approved_tools=["doc_search", "web_search", "customer_db"],
        approved_models=["small", "large"]
    );
}


def three_agent_workflow() -> WorkflowVersion {
    store = VersionStore();
    wf = WorkflowVersion(label="base");
    store +>:Stores:+> wf;

    a = AgentSpec(agent_id="classifier", role="Classify requests", model="large", prompt="Classify.");
    b = AgentSpec(
        agent_id="support", role="Resolve customer problems", model="large",
        prompt="Resolve.", tools=["doc_search", "web_search"]
    );
    c = AgentSpec(agent_id="reviewer", role="Review responses", model="large", prompt="Review.");

    wf +>:Entry:+> a;
    a +>:FlowsTo(to_agent="support"):+> b;
    b +>:FlowsTo(to_agent="reviewer"):+> c;
    return reseal(wf);
}


def fresh_store() -> VersionStore {
    return VersionStore();
}


test "a clone reproduces the parent exactly" {
    parent = three_agent_workflow();
    child = clone_workflow(parent, fresh_store());
    assert child.config_hash == parent.config_hash, "a faithful clone is the same configuration";
    assert len(workflow_agents(child)) == 3;
}


test "mutating a clone leaves the parent untouched" {
    parent = three_agent_workflow();
    before = parent.config_hash;

    m = Mutation(family=MutationFamily.MODEL, kind="set_model", target="classifier", str_value="small");
    child = apply_mutation(parent, m, demo_constraints(), fresh_store());

    assert child is not None;
    assert parent.config_hash == before, "the parent must be immutable";
    original = agent_by_id(parent, "classifier");
    assert original is not None;
    if original is not None {
        assert original.model == "large", "parent's agent must not be edited";
    }
}


test "a model swap produces a different content address" {
    parent = three_agent_workflow();
    m = Mutation(family=MutationFamily.MODEL, kind="set_model", target="classifier", str_value="small");
    child = apply_mutation(parent, m, demo_constraints(), fresh_store());
    assert child is not None;
    if child is not None {
        assert child.config_hash != parent.config_hash;
        swapped = agent_by_id(child, "classifier");
        assert swapped is not None;
        if swapped is not None {
            assert swapped.model == "small";
        }
    }
    assert m.before == "large" and m.after == "small", "before/after must be recorded for the report";
}


test "a mutation that changes nothing is not a candidate" {
    parent = three_agent_workflow();
    m = Mutation(family=MutationFamily.MODEL, kind="set_model", target="classifier", str_value="large");
    assert apply_mutation(parent, m, demo_constraints(), fresh_store()) is None;
}


test "an immutable prompt cannot be rewritten" {
    parent = three_agent_workflow();
    locked = agent_by_id(parent, "reviewer");
    assert locked is not None;
    if locked is not None {
        locked.mutable_prompt = False;
    }
    m = Mutation(family=MutationFamily.PROMPT, kind="set_prompt", target="reviewer", str_value="new");
    assert apply_mutation(parent, m, demo_constraints(), fresh_store()) is None;
    assert "immutable" in precondition_failure(parent, m);
}


test "a required agent cannot be removed" {
    parent = three_agent_workflow();
    protected = agent_by_id(parent, "reviewer");
    assert protected is not None;
    if protected is not None {
        protected.required = True;
    }
    m = Mutation(family=MutationFamily.TOPOLOGY, kind="remove_agent", target="reviewer");
    assert apply_mutation(parent, m, demo_constraints(), fresh_store()) is None;
}


test "a non-removable agent cannot be removed" {
    parent = three_agent_workflow();
    protected = agent_by_id(parent, "reviewer");
    assert protected is not None;
    if protected is not None {
        protected.removable = False;
    }
    m = Mutation(family=MutationFamily.TOPOLOGY, kind="remove_agent", target="reviewer");
    assert apply_mutation(parent, m, demo_constraints(), fresh_store()) is None;
}


test "removing a middle agent rewires around it" {
    parent = three_agent_workflow();
    m = Mutation(family=MutationFamily.TOPOLOGY, kind="remove_agent", target="support");
    child = apply_mutation(parent, m, demo_constraints(), fresh_store());

    assert child is not None;
    if child is not None {
        ids = [a.agent_id for a in workflow_agents(child)];
        assert ids == ["classifier", "reviewer"], f"got {ids}";
        head = entry_agent(child);
        assert head is not None;
        if head is not None {
            assert head.agent_id == "classifier";
            assert successors_of(head) == ["reviewer"], "the gap must be bridged";
        }
    }
}


test "removing the entry agent promotes its successor" {
    parent = three_agent_workflow();
    m = Mutation(family=MutationFamily.TOPOLOGY, kind="remove_agent", target="classifier");
    child = apply_mutation(parent, m, demo_constraints(), fresh_store());

    assert child is not None;
    if child is not None {
        head = entry_agent(child);
        assert head is not None;
        if head is not None {
            assert head.agent_id == "support", "the successor must become the new entry";
        }
        assert len(validate(child, demo_constraints())) == 0, "the result must still be a valid workflow";
    }
}


test "a mutation producing an invalid workflow is rejected" {
    parent = three_agent_workflow();
    # 'gpt-unbudgeted' is not in the approved list, so validation must reject it.
    m = Mutation(family=MutationFamily.MODEL, kind="set_model", target="support", str_value="gpt-unbudgeted");
    assert apply_mutation(parent, m, demo_constraints(), fresh_store()) is None;
}


test "removing a tool the agent lacks is refused" {
    parent = three_agent_workflow();
    m = Mutation(family=MutationFamily.TOOL, kind="remove_tool", target="classifier", str_value="doc_search");
    assert apply_mutation(parent, m, demo_constraints(), fresh_store()) is None;
}


test "removing a real tool works and records before/after" {
    parent = three_agent_workflow();
    m = Mutation(family=MutationFamily.TOOL, kind="remove_tool", target="support", str_value="web_search");
    child = apply_mutation(parent, m, demo_constraints(), fresh_store());

    assert child is not None;
    if child is not None {
        agent = agent_by_id(child, "support");
        assert agent is not None;
        if agent is not None {
            assert agent.tools == ["doc_search"];
        }
    }
    assert "web_search" in m.before and "web_search" not in m.after;
}


test "moving a tool transfers it between agents" {
    parent = three_agent_workflow();
    m = Mutation(
        family=MutationFamily.TOOL, kind="move_tool",
        target="support", str_value="doc_search", second_target="reviewer"
    );
    child = apply_mutation(parent, m, demo_constraints(), fresh_store());

    assert child is not None;
    if child is not None {
        src = agent_by_id(child, "support");
        dst = agent_by_id(child, "reviewer");
        assert src is not None and dst is not None;
        if src is not None and dst is not None {
            assert "doc_search" not in src.tools;
            assert "doc_search" in dst.tools;
        }
    }
}


test "bypass makes an inbound edge conditional without deleting the node" {
    parent = three_agent_workflow();
    m = Mutation(
        family=MutationFamily.TOPOLOGY, kind="bypass_agent",
        target="reviewer", str_value="low_confidence"
    );
    child = apply_mutation(parent, m, demo_constraints(), fresh_store());

    assert child is not None;
    if child is not None {
        assert agent_by_id(child, "reviewer") is not None, "bypass keeps the node";
        support = agent_by_id(child, "support");
        assert support is not None;
        if support is not None {
            conds = [e.condition for e in [edge support ->:FlowsTo:->]];
            assert conds == ["low_confidence"], f"got {conds}";
        }
    }
}


test "token budgets must stay positive" {
    parent = three_agent_workflow();
    m = Mutation(family=MutationFamily.RUNTIME, kind="set_max_tokens", target="support", int_value=0);
    assert apply_mutation(parent, m, demo_constraints(), fresh_store()) is None;
}


test "a compound mutation applies every step or none" {
    parent = three_agent_workflow();
    good = [
        Mutation(family=MutationFamily.MODEL, kind="set_model", target="classifier", str_value="small"),
        Mutation(family=MutationFamily.RUNTIME, kind="set_max_tokens", target="classifier", int_value=256)
    ];
    combined = apply_compound(parent, good, demo_constraints(), fresh_store());
    assert combined is not None;
    if combined is not None {
        agent = agent_by_id(combined, "classifier");
        assert agent is not None;
        if agent is not None {
            assert agent.model == "small" and agent.max_tokens == 256;
        }
    }

    mixed = [
        Mutation(family=MutationFamily.MODEL, kind="set_model", target="classifier", str_value="small"),
        Mutation(family=MutationFamily.TOPOLOGY, kind="remove_agent", target="nonexistent")
    ];
    assert apply_compound(parent, mixed, demo_constraints(), fresh_store()) is None;
}


test "an unknown mutation kind is refused rather than silently ignored" {
    parent = three_agent_workflow();
    m = Mutation(family=MutationFamily.RUNTIME, kind="rewrite_everything", target="support");
    assert apply_mutation(parent, m, demo_constraints(), fresh_store()) is None;
}
