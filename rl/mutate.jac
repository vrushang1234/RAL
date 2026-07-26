"""Typed mutations and their application to a workflow.

Spec: docs/rl-optimization.md sections 11, 14.2, and 19.

Mutations are typed, never free-form rewriting by a model. Each declares its
target, parameters, preconditions, and a rationale. That is what makes the
search reproducible, explainable, and safe to run unattended.

Applying a mutation never edits a version in place: it clones, edits the clone,
and reseals. The parent stays valid forever, which is what makes the archive,
the cache, and the lineage report all work off the same objects.
"""

import from rl.ir {
    AgentSpec, WorkflowVersion, Entry, FlowsTo, DerivedFrom, Constraints,
    VersionStore, Stores,
    workflow_agents, agent_by_id, entry_agent, reseal, validate
}


enum MutationFamily { PROMPT, TOOL, MODEL, RUNTIME, CONTEXT, TOPOLOGY }


obj Mutation {
    has family: MutationFamily;
    has kind: str;
    has target: str;
    has str_value: str = "";
    has int_value: int = 0;
    has float_value: float = 0.0;
    has second_target: str = "";
    has rationale: str = "";
    has before: str = "";
    has after: str = "";
}


def family_name(f: MutationFamily) -> str {
    if f == MutationFamily.PROMPT { return "prompt"; }
    if f == MutationFamily.TOOL { return "tool"; }
    if f == MutationFamily.MODEL { return "model"; }
    if f == MutationFamily.RUNTIME { return "runtime"; }
    if f == MutationFamily.CONTEXT { return "context"; }
    return "topology";
}


def all_families -> list[MutationFamily] {
    return [
        MutationFamily.RUNTIME, MutationFamily.MODEL, MutationFamily.TOOL,
        MutationFamily.PROMPT, MutationFamily.CONTEXT, MutationFamily.TOPOLOGY
    ];
}


"""Deep-copy a version so the parent is never touched (section 2.1).

Attaching `fresh` to the store MUST come before any agent is attached.
Connecting a node into the root-reachable graph after it already has outgoing
edges to unattached nodes silently drops those edges - the clone would come
back with no agents at all.
"""
def clone_workflow(wf: WorkflowVersion, versions: VersionStore) -> WorkflowVersion {
    fresh = WorkflowVersion(label=wf.label, round_no=wf.round_no);
    versions +>:Stores:+> fresh;
    mapping: dict[str, AgentSpec] = {};

    for a in workflow_agents(wf) {
        mapping[a.agent_id] = AgentSpec(
            agent_id=a.agent_id,
            role=a.role,
            model=a.model,
            prompt=a.prompt,
            tools=[t for t in a.tools],
            max_tokens=a.max_tokens,
            temperature=a.temperature,
            retries=a.retries,
            context_mode=a.context_mode,
            mutable_prompt=a.mutable_prompt,
            removable=a.removable,
            required=a.required
        );
    }

    head = entry_agent(wf);
    if head is not None and head.agent_id in mapping {
        fresh +>:Entry:+> mapping[head.agent_id];
    }

    for a in workflow_agents(wf) {
        src = mapping[a.agent_id];
        for e in [edge a ->:FlowsTo:->] {
            if e.to_agent in mapping {
                src +>:FlowsTo(to_agent=e.to_agent, condition=e.condition):+> mapping[e.to_agent];
            }
        }
    }

    return reseal(fresh);
}


def successors_of(a: AgentSpec) -> list[str] {
    return [b.agent_id for b in [a ->:FlowsTo:->]];
}


def predecessors_of(wf: WorkflowVersion, agent_id: str) -> list[AgentSpec] {
    out: list[AgentSpec] = [];
    for p in workflow_agents(wf) {
        if agent_id in successors_of(p) {
            out.append(p);
        }
    }
    return out;
}


def drop_edge(src: AgentSpec, to_agent: str) -> int {
    doomed = [e for e in [edge src ->:FlowsTo:->] if e.to_agent == to_agent];
    for e in doomed {
        del e;
    }
    return len(doomed);
}


"""Add an edge if one does not already exist.

NOT named `connect`: the `+>:Edge:+>` operator desugars to a runtime
`connect()` call, and a module-level `def connect` shadows it, breaking every
edge creation in this file with "connect() got an unexpected keyword argument
'left'".
"""
def link_agents(src: AgentSpec, dst: AgentSpec, condition: str) -> bool {
    if dst.agent_id in successors_of(src) {
        return False;
    }
    src +>:FlowsTo(to_agent=dst.agent_id, condition=condition):+> dst;
    return True;
}


"""Why this mutation may not be applied, or "" if it may (section 19).

Preconditions are checked here so that a violating mutation is never even
generated. `ir.validate` re-checks the result, and the runtime caps check
again during execution - the redundancy is deliberate.
"""
def precondition_failure(wf: WorkflowVersion, m: Mutation) -> str {
    target = agent_by_id(wf, m.target);
    if target is None {
        return f"no agent [{m.target}]";
    }

    if m.kind == "set_prompt" and not target.mutable_prompt {
        return f"agent [{m.target}] has an immutable prompt";
    }
    if m.kind == "remove_agent" {
        if not target.removable {
            return f"agent [{m.target}] is not removable";
        }
        if target.required {
            return f"agent [{m.target}] is required";
        }
        if len(workflow_agents(wf)) <= 1 {
            return "cannot remove the only agent";
        }
    }
    if m.kind == "bypass_agent" and target.required {
        return f"agent [{m.target}] is required and cannot be bypassed";
    }
    if m.kind == "remove_tool" and not (m.str_value in target.tools) {
        return f"agent [{m.target}] does not have tool [{m.str_value}]";
    }
    if m.kind == "add_tool" and m.str_value in target.tools {
        return f"agent [{m.target}] already has tool [{m.str_value}]";
    }
    if m.kind == "move_tool" {
        if not (m.str_value in target.tools) {
            return f"agent [{m.target}] does not have tool [{m.str_value}]";
        }
        if agent_by_id(wf, m.second_target) is None {
            return f"no destination agent [{m.second_target}]";
        }
    }
    if m.kind == "set_max_tokens" and m.int_value <= 0 {
        return "max_tokens must be positive";
    }
    if m.kind in ["set_edge_condition", "add_conditional_edge"] {
        if agent_by_id(wf, m.second_target) is None {
            return f"no edge target [{m.second_target}]";
        }
    }
    return "";
}


"""Remove an agent and rewire its predecessors straight to its successors."""
def excise_agent(wf: WorkflowVersion, agent_id: str) -> bool {
    target = agent_by_id(wf, agent_id);
    if target is None {
        return False;
    }

    # Hold the successors as NODES, resolved before anything is disconnected.
    # Resolving them by id afterwards fails: `agent_by_id` walks from the entry
    # node, and the moment the inbound edge is dropped the successors are no
    # longer reachable, so the rewire silently does nothing and orphans them.
    succ_nodes: list[AgentSpec] = [b for b in [target ->:FlowsTo:->]];
    preds = predecessors_of(wf, agent_id);
    head = entry_agent(wf);
    was_entry = head is not None and head.agent_id == agent_id;

    for p in preds {
        drop_edge(p, agent_id);
        for s in succ_nodes {
            link_agents(p, s, "");
        }
    }

    if was_entry {
        for e in [edge wf ->:Entry:->] {
            del e;
        }
        if len(succ_nodes) > 0 {
            wf +>:Entry:+> succ_nodes[0];
        }
    }

    del target;
    return True;
}


"""Apply one mutation to a CLONE and return the new version, or None.

Returns None when a precondition fails or the result does not validate - a
rejected mutation must never leave a half-edited graph behind, which is
exactly why this works on a clone.
"""
def apply_mutation(
    parent: WorkflowVersion,
    m: Mutation,
    c: Constraints,
    versions: VersionStore
) -> WorkflowVersion | None {
    failure = precondition_failure(parent, m);
    if failure != "" {
        return None;
    }

    child = clone_workflow(parent, versions);
    target = agent_by_id(child, m.target);
    if target is None {
        return None;
    }

    if m.kind == "set_model" {
        m.before = target.model;
        target.model = m.str_value;
        m.after = m.str_value;
    } elif m.kind == "set_prompt" {
        m.before = target.prompt;
        target.prompt = m.str_value;
        m.after = m.str_value;
    } elif m.kind == "set_max_tokens" {
        m.before = str(target.max_tokens);
        target.max_tokens = m.int_value;
        m.after = str(m.int_value);
    } elif m.kind == "set_temperature" {
        m.before = str(target.temperature);
        target.temperature = m.float_value;
        m.after = str(m.float_value);
    } elif m.kind == "set_retries" {
        m.before = str(target.retries);
        target.retries = m.int_value;
        m.after = str(m.int_value);
    } elif m.kind == "set_context_mode" {
        m.before = target.context_mode;
        target.context_mode = m.str_value;
        m.after = m.str_value;
    } elif m.kind == "add_tool" {
        m.before = ",".join(target.tools);
        target.tools = target.tools + [m.str_value];
        m.after = ",".join(target.tools);
    } elif m.kind == "remove_tool" {
        m.before = ",".join(target.tools);
        target.tools = [t for t in target.tools if t != m.str_value];
        m.after = ",".join(target.tools);
    } elif m.kind == "move_tool" {
        dest = agent_by_id(child, m.second_target);
        if dest is None {
            return None;
        }
        m.before = f"{m.target}:{','.join(target.tools)}";
        target.tools = [t for t in target.tools if t != m.str_value];
        if not (m.str_value in dest.tools) {
            dest.tools = dest.tools + [m.str_value];
        }
        m.after = f"{m.second_target}:{','.join(dest.tools)}";
    } elif m.kind == "set_edge_condition" {
        found = False;
        for e in [edge target ->:FlowsTo:->] {
            if e.to_agent == m.second_target {
                m.before = e.condition;
                e.condition = m.str_value;
                m.after = m.str_value;
                found = True;
            }
        }
        if not found {
            return None;
        }
    } elif m.kind == "add_conditional_edge" {
        dest = agent_by_id(child, m.second_target);
        if dest is None or not link_agents(target, dest, m.str_value) {
            return None;
        }
        m.before = "";
        m.after = f"{m.target}->{m.second_target} if {m.str_value}";
    } elif m.kind == "remove_agent" {
        m.before = m.target;
        if not excise_agent(child, m.target) {
            return None;
        }
        m.after = "";
    } elif m.kind == "bypass_agent" {
        # Keep the node but make every inbound edge conditional.
        m.before = "unconditional";
        for p in predecessors_of(child, m.target) {
            for e in [edge p ->:FlowsTo:->] {
                if e.to_agent == m.target {
                    e.condition = m.str_value if m.str_value != "" else "low_confidence";
                }
            }
        }
        m.after = m.str_value if m.str_value != "" else "low_confidence";
    } else {
        return None;
    }

    reseal(child);

    if len(validate(child, c)) > 0 {
        return None;
    }
    # A mutation that changed nothing is not a candidate.
    if child.config_hash == parent.config_hash {
        return None;
    }
    return child;
}


"""Apply several mutations as one action (section 14.2).

Compound moves exist because a topology change usually needs a compensating
edit to be worth anything - removing a reviewer scores negative, while making
it conditional scores positive, and only the compound form can express the
second as a single step.
"""
def apply_compound(
    parent: WorkflowVersion,
    mutations: list[Mutation],
    c: Constraints,
    versions: VersionStore
) -> WorkflowVersion | None {
    current = parent;
    applied = 0;
    for m in mutations {
        nxt = apply_mutation(current, m, c, versions);
        if nxt is None {
            return None;
        }
        current = nxt;
        applied += 1;
    }
    if applied == 0 {
        return None;
    }
    return current;
}


"""Link a child version to its parent, recording why it exists (section 20)."""
def link_lineage(
    child: WorkflowVersion,
    parent: WorkflowVersion,
    m: Mutation,
    train_delta: float,
    train_se: float,
    val_delta: float,
    val_se: float
) -> WorkflowVersion {
    child +>:DerivedFrom(
        mutation_kind=m.kind,
        target=m.target,
        family=family_name(m.family),
        before=m.before,
        after=m.after,
        train_delta=train_delta,
        train_se=train_se,
        val_delta=val_delta,
        val_se=val_se,
        rationale=m.rationale
    ):+> parent;
    return child;
}


def describe(m: Mutation) -> str {
    return f"{family_name(m.family)}/{m.kind} on [{m.target}]";
}
