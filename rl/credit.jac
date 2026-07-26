"""Credit assignment and mutation targeting.

Spec: docs/rl-optimization.md section 10.

The action space factors as family x target x parameters, and targets are the
larger term - six families against a five-agent workflow is thirty pairs before
any parameters. The bandit in `bandit.jac` only picks the family; this module
picks the target, which means it is doing the heavier half of the search.

Everything here is derived from traces that were being collected anyway, so
targeting costs nothing beyond the aggregation.
"""

import from rl.trace { RunRoot, Span, spans_of }
import from rl.ir { WorkflowVersion, AgentSpec, workflow_agents }


obj AgentStats {
    has agent_id: str;
    has invocations: int = 0;
    has failures: int = 0;
    has total_cost_usd: float = 0.0;
    has total_output_tokens: int = 0;
    has cost_share: float = 0.0;
    has edit_rate: float = 0.0;
    has edit_measured: int = 0;
    has tool_calls: int = 0;
    has tool_useful_calls: int = 0;
    has tool_useful_rate: float = 0.0;
    has model: str = "";
    has max_output_tokens: int = 0;
}


obj ToolStats {
    has tool_name: str;
    has agent_id: str;
    has offered: int = 0;
    has invoked: int = 0;
    has useful: int = 0;
    has invoke_rate: float = 0.0;
    has useful_rate: float = 0.0;
}


"""Aggregate per-agent statistics across a set of runs."""
def aggregate_agents(runs: list[RunRoot]) -> list[AgentStats] {
    acc: dict[str, AgentStats] = {};
    grand_cost = 0.0;

    for run in runs {
        for s in spans_of(run) {
            if not (s.agent_id in acc) {
                acc[s.agent_id] = AgentStats(agent_id=s.agent_id, model=s.model);
            }
            st = acc[s.agent_id];
            st.invocations += 1;
            st.total_cost_usd += s.cost_usd;
            st.total_output_tokens += s.output_tokens;
            st.tool_calls += len(s.tools_invoked);
            if s.tool_influenced_output {
                st.tool_useful_calls += 1;
            }
            if s.error != "" {
                st.failures += 1;
            }
            if s.measures_edits {
                st.edit_measured += 1;
                if s.edited_upstream {
                    st.edit_rate += 1.0;
                }
            }
            if s.output_tokens > st.max_output_tokens {
                st.max_output_tokens = s.output_tokens;
            }
            grand_cost += s.cost_usd;
        }
    }

    out: list[AgentStats] = [];
    for k in sorted(acc.keys()) {
        st = acc[k];
        if st.edit_measured > 0 {
            st.edit_rate = st.edit_rate / st.edit_measured;
        }
        if st.invocations > 0 {
            st.tool_useful_rate = st.tool_useful_calls / st.invocations;
        }
        st.cost_share = st.total_cost_usd / grand_cost if grand_cost > 0.0 else 0.0;
        out.append(st);
    }
    return out;
}


"""Per-tool utility: how often it is called versus how often it changes anything.

A tool invoked in 38% of runs that influences the answer in 4% is the clearest
removal candidate the trace can produce.
"""
def aggregate_tools(runs: list[RunRoot]) -> list[ToolStats] {
    acc: dict[str, ToolStats] = {};

    for run in runs {
        for s in spans_of(run) {
            for tool in s.tools_available {
                key = f"{s.agent_id}|{tool}";
                if not (key in acc) {
                    acc[key] = ToolStats(tool_name=tool, agent_id=s.agent_id);
                }
                acc[key].offered += 1;
            }
            for tool in s.tools_invoked {
                key = f"{s.agent_id}|{tool}";
                if not (key in acc) {
                    acc[key] = ToolStats(tool_name=tool, agent_id=s.agent_id);
                }
                acc[key].invoked += 1;
                if s.tool_influenced_output {
                    acc[key].useful += 1;
                }
            }
        }
    }

    out: list[ToolStats] = [];
    for k in sorted(acc.keys()) {
        t = acc[k];
        t.invoke_rate = t.invoked / t.offered if t.offered > 0 else 0.0;
        t.useful_rate = t.useful / t.invoked if t.invoked > 0 else 0.0;
        out.append(t);
    }
    return out;
}


obj TargetScore {
    has agent_id: str;
    has score: float;
    has reason: str;
}


def target_score_key(t: TargetScore) -> float {
    return -t.score;
}


"""Rank agents by how much attention they deserve from the optimizer.

Cost share and failure rate both raise an agent's priority; so does a reviewer
that rarely edits, because that is a conditionalization opportunity rather
than a defect.
"""
def rank_targets(stats: list[AgentStats]) -> list[TargetScore] {
    scored: list[TargetScore] = [];
    for s in stats {
        failure_rate = s.failures / s.invocations if s.invocations > 0 else 0.0;
        score = s.cost_share + failure_rate;
        reason = f"cost share {s.cost_share:.2f}";

        if failure_rate > 0.0 {
            reason = f"{reason}, failure rate {failure_rate:.2f}";
        }
        # A reviewer that almost never edits is an opportunity, not a problem.
        if s.edit_rate > 0.0 and s.edit_rate < 0.10 {
            score += 0.25;
            reason = f"{reason}, edits only {s.edit_rate:.0%} of outputs";
        }
        if s.tool_calls > 0 and s.tool_useful_rate < 0.20 {
            score += 0.20;
            reason = f"{reason}, tools rarely influence the answer";
        }
        scored.append(TargetScore(agent_id=s.agent_id, score=score, reason=reason));
    }
    return sorted(scored, key=target_score_key);
}


"""Tools whose invocation rate far exceeds their usefulness (section 12).

These are the rule-based removal proposals - no model call needed to find them.
"""
def wasteful_tools(tools: list[ToolStats], min_invocations: int, useful_floor: float) -> list[ToolStats] {
    out: list[ToolStats] = [];
    for t in tools {
        if t.invoked >= min_invocations and t.useful_rate < useful_floor {
            out.append(t);
        }
    }
    return out;
}


"""Agents whose token budget is far above anything they actually produce."""
def oversized_budgets(wf: WorkflowVersion, stats: list[AgentStats], slack: float) -> list[str] {
    by_id: dict[str, AgentStats] = {};
    for s in stats {
        by_id[s.agent_id] = s;
    }

    out: list[str] = [];
    for a in workflow_agents(wf) {
        if a.agent_id in by_id {
            observed = by_id[a.agent_id].max_output_tokens;
            if observed > 0 and a.max_tokens > observed * slack {
                out.append(a.agent_id);
            }
        }
    }
    return out;
}


"""Reviewers that almost never change the answer - conditionalization candidates.

Requires `edit_measured > 0`: an agent whose edits were never measured has an
edit_rate of 0 for a completely different reason, and treating that as evidence
of idleness is how a proposer talks itself into deleting the agent that does
all the work.
"""
def idle_reviewers(stats: list[AgentStats], edit_ceiling: float) -> list[str] {
    out: list[str] = [];
    for s in stats {
        if s.edit_measured > 0 and s.edit_rate < edit_ceiling {
            out.append(s.agent_id);
        }
    }
    return out;
}


def stats_for(stats: list[AgentStats], agent_id: str) -> AgentStats | None {
    for s in stats {
        if s.agent_id == agent_id {
            return s;
        }
    }
    return None;
}
