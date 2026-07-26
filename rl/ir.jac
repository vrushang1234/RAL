"""Workflow intermediate representation, versioning, and validation.

Spec: docs/rl-optimization.md sections 2 and 19.

The workflow IS the graph - there is no separate serialized IR. A version is
content-addressed by `config_hash` and never mutated in place; every mutation
creates a fresh `WorkflowVersion` linked back by `DerivedFrom`, which is both
the cache key (16.1) and the explainability lineage (20).
"""

import hashlib;
import json;


node AgentSpec {
    has agent_id: str;
    has role: str;
    has model: str;
    has prompt: str;
    has tools: list[str] = [];
    has max_tokens: int = 1024;
    has temperature: float = 0.0;
    has retries: int = 0;
    has context_mode: str = "full";
    # Section 19 - the optimizer may never violate these.
    has mutable_prompt: bool = True;
    has removable: bool = True;
    has required: bool = False;
}


node WorkflowVersion {
    has config_hash: str = "";
    has created_at: str = "";
    has label: str = "";
    has accepted: bool = False;
    has round_no: int = 0;
}


edge Entry: WorkflowVersion --> AgentSpec {
    has note: str = "";
}


"""`to_agent` duplicates the target's id on purpose.

Jac edge objects expose only their own `has` fields - there is no
`.source` / `.target` accessor - so an edge cannot describe its own
endpoints for hashing. Pairing `[edge a ->:FlowsTo:->]` against
`[a ->:FlowsTo:->]` positionally happens to work but would make the
content hash depend on undocumented iteration order. `mutate.jac` is the
only writer, so this field cannot drift.
"""
edge FlowsTo: AgentSpec --> AgentSpec {
    has to_agent: str;
    has condition: str = "";
}


edge DerivedFrom: WorkflowVersion --> WorkflowVersion {
    has mutation_kind: str;
    has target: str;
    has family: str = "";
    has before: str = "";
    has after: str = "";
    has train_delta: float = 0.0;
    has train_se: float = 0.0;
    has val_delta: float = 0.0;
    has val_se: float = 0.0;
    has rationale: str = "";
}


"""Owns every version the search creates.

Candidate versions must hang off a root-reachable container to persist, and
the owner is passed in explicitly rather than having library code reach for
the global `root`.
"""
node VersionStore {
    has name: str = "versions";
}


edge Stores: VersionStore --> WorkflowVersion {
    has note: str = "";
}


"""The user-approved search space (section 19)."""
obj Constraints {
    has approved_tools: list[str] = [];
    has approved_models: list[str] = [];
    has max_retries: int = 3;
    has max_agents: int = 12;
    has allow_cycles: bool = False;
}


obj ValidationIssue {
    has code: str;
    has detail: str;
}


"""Every agent reachable from the entry node, ordered by id for determinism."""
def workflow_agents(wf: WorkflowVersion) -> list[AgentSpec] {
    seen: dict[str, AgentSpec] = {};
    frontier: list[AgentSpec] = [wf ->:Entry:->];

    while len(frontier) > 0 {
        nxt: list[AgentSpec] = [];
        for a in frontier {
            if not (a.agent_id in seen) {
                seen[a.agent_id] = a;
                for b in [a ->:FlowsTo:->] {
                    nxt.append(b);
                }
            }
        }
        frontier = nxt;
    }

    return [seen[k] for k in sorted(seen.keys())];
}


def agent_by_id(wf: WorkflowVersion, agent_id: str) -> AgentSpec | None {
    for a in workflow_agents(wf) {
        if a.agent_id == agent_id {
            return a;
        }
    }
    return None;
}


def entry_agent(wf: WorkflowVersion) -> AgentSpec | None {
    heads = [wf ->:Entry:->];
    if len(heads) == 0 {
        return None;
    }
    return heads[0];
}


"""Order-independent serialization. Two configs equal here are the same policy."""
def canonical_config(wf: WorkflowVersion) -> str {
    agents = workflow_agents(wf);
    head = entry_agent(wf);

    parts: list[str] = ["entry=" + (head.agent_id if head is not None else "")];

    for a in agents {
        row: list[str] = [
            a.agent_id,
            a.role,
            a.model,
            a.prompt,
            ",".join(sorted(a.tools)),
            str(a.max_tokens),
            str(a.temperature),
            str(a.retries),
            a.context_mode
        ];
        parts.append("agent=" + json.dumps(row, separators=(",", ":")));
    }

    edge_rows: list[str] = [];
    for a in agents {
        for e in [edge a ->:FlowsTo:->] {
            edge_rows.append(json.dumps([a.agent_id, e.to_agent, e.condition], separators=(",", ":")));
        }
    }
    for r in sorted(edge_rows) {
        parts.append("edge=" + r);
    }

    return "\n".join(parts);
}


def compute_hash(wf: WorkflowVersion) -> str {
    return hashlib.sha256(canonical_config(wf).encode("utf-8")).hexdigest()[:16];
}


"""Recompute the content address after a version's agents are attached."""
def reseal(wf: WorkflowVersion) -> WorkflowVersion {
    wf.config_hash = compute_hash(wf);
    return wf;
}


def walk_for_cycle(a: AgentSpec, state: dict[str, int]) -> bool {
    state[a.agent_id] = 1;
    for b in [a ->:FlowsTo:->] {
        mark: int = state[b.agent_id] if b.agent_id in state else 0;
        if mark == 1 {
            return True;
        }
        if mark == 0 and walk_for_cycle(b, state) {
            return True;
        }
    }
    state[a.agent_id] = 2;
    return False;
}


def has_cycle(wf: WorkflowVersion) -> bool {
    head = entry_agent(wf);
    if head is None {
        return False;
    }
    state: dict[str, int] = {};
    return walk_for_cycle(head, state);
}


"""Static validation (2.2) plus search-space enforcement (19).

Runs before any candidate executes. Runtime caps in `runtime.jac` are
deliberately redundant with this - a constraint checked only here is one
proposal-generator bug away from being unenforced.
"""
def validate(wf: WorkflowVersion, c: Constraints) -> list[ValidationIssue] {
    issues: list[ValidationIssue] = [];

    heads = [wf ->:Entry:->];
    if len(heads) != 1 {
        issues.append(ValidationIssue(
            code="E_ENTRY",
            detail=f"expected exactly 1 entry point, found {len(heads)}"
        ));
    }

    agents = workflow_agents(wf);
    if len(agents) == 0 {
        issues.append(ValidationIssue(code="E_EMPTY", detail="workflow has no agents"));
        return issues;
    }
    if len(agents) > c.max_agents {
        issues.append(ValidationIssue(
            code="E_SIZE",
            detail=f"{len(agents)} agents exceeds cap of {c.max_agents}"
        ));
    }

    reachable: list[str] = [a.agent_id for a in agents];
    terminals = [a for a in agents if len([a ->:FlowsTo:->]) == 0];
    if len(terminals) == 0 {
        issues.append(ValidationIssue(
            code="E_NO_TERMINAL",
            detail="no terminal node - every agent has an outgoing edge"
        ));
    }

    for a in agents {
        for t in a.tools {
            if not (t in c.approved_tools) {
                issues.append(ValidationIssue(
                    code="E_TOOL_UNAPPROVED",
                    detail=f"agent [{a.agent_id}] uses unapproved tool [{t}]"
                ));
            }
        }
        if not (a.model in c.approved_models) {
            issues.append(ValidationIssue(
                code="E_MODEL_UNAPPROVED",
                detail=f"agent [{a.agent_id}] uses unapproved model [{a.model}]"
            ));
        }
        if a.retries < 0 or a.retries > c.max_retries {
            issues.append(ValidationIssue(
                code="E_RETRIES",
                detail=f"agent [{a.agent_id}] retries={a.retries} outside [0, {c.max_retries}]"
            ));
        }
        if a.max_tokens <= 0 {
            issues.append(ValidationIssue(
                code="E_TOKENS",
                detail=f"agent [{a.agent_id}] has non-positive max_tokens"
            ));
        }
        for e in [edge a ->:FlowsTo:->] {
            if not (e.to_agent in reachable) {
                issues.append(ValidationIssue(
                    code="E_DANGLING_EDGE",
                    detail=f"edge [{a.agent_id}] -> [{e.to_agent}] has no live target"
                ));
            }
        }
    }

    head = entry_agent(wf);
    head_id: str = head.agent_id if head is not None else "";
    for a in agents {
        if a.required and a.agent_id != head_id and len([a <-:FlowsTo:<-]) == 0 {
            issues.append(ValidationIssue(
                code="E_REQUIRED_ORPHANED",
                detail=f"required agent [{a.agent_id}] is unreachable"
            ));
        }
    }

    if not c.allow_cycles and has_cycle(wf) {
        issues.append(ValidationIssue(code="E_CYCLE", detail="workflow contains a cycle"));
    }

    return issues;
}


def is_valid(wf: WorkflowVersion, c: Constraints) -> bool {
    return len(validate(wf, c)) == 0;
}
