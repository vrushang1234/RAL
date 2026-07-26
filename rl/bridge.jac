"""Adapter between the workflow engine's `optimize` contract and `rl/`.

`endpoints.train_step` builds a payload, calls one `optimize(payload)`, applies
the returned prompt mutations, and shows `critic_score` in the UI. That contract
is SINGLE-SHOT: one task, one execution, one score, mutations returned
immediately. `mock_rl.py` satisfied it by making the score climb.

The honest problem, and the reason this module exists rather than just calling
the search loop: one run of one task cannot distinguish an improvement from
noise (docs/rl-optimization.md section 9). A score that climbs every step is a
UI animation, not evidence.

So this adapter does two things:

  1. Answers the single-shot contract deterministically - a real score from the
     trace and ground truth, and prompt mutations targeted by trace evidence
     rather than appended boilerplate.
  2. Accumulates observations ACROSS calls, keyed by (workflow signature, task),
     so that once the same task has been seen under two workflow versions it can
     report a genuine paired delta with its standard error and say plainly
     whether the change is supported. That verdict goes in `analysis_log`, which
     is what the training console displays.

The multi-round optimizer with archive, validation, and budget lives in
`rl/search.jac` and is reached through the walkers in `api.sv.jac`; this module
is the incremental single-step path the existing UI drives.
"""

import hashlib;
import from rl.stats { PairedResult, paired_from_maps, passes_gate }


node OptimizerMemory {
    has calls: int = 0;
    # The two most recent DISTINCT workflow versions. Tracking only "the last
    # call's signature" breaks as soon as several tasks are scored under one
    # version: the second task would compare a version against itself.
    has current_signature: str = "";
    has previous_signature: str = "";
    has gate_k: float = 1.5;
    has gate_floor: float = 0.02;
}


node Observation {
    has workflow_sig: str;
    has task_key: str;
    has score: float;
    has seq: int = 0;
}


edge Observed: OptimizerMemory --> Observation {
    has note: str = "";
}


def short_hash(text: str) -> str {
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12];
}


"""Content address of the prompts currently in play.

A prompt mutation changes this, which is what lets observations be grouped by
workflow version without the engine having to track versions itself.
"""
def workflow_signature(agent_states: list) -> str {
    parts: list[str] = [];
    for raw in agent_states {
        state = raw as dict;
        node_id = str(state["node_id"]) if "node_id" in state else "";
        prompt = str(state["current_sem_prompt"]) if "current_sem_prompt" in state else "";
        parts.append(node_id + "=" + prompt);
    }
    parts.sort();
    return short_hash("|".join(parts));
}


def normalize_tokens(text: str) -> list[str] {
    cleaned = "";
    for ch in text.lower() {
        cleaned += ch if ch.isalnum() or ch == " " else " ";
    }
    return [t for t in cleaned.split() if len(t) > 2];
}


"""Token-overlap F1 against the expected output.

Deterministic on purpose. A judge model would be a better quality signal on
open-ended work, but it is also the surface a prompt mutation can game
(section 7.3), and it cannot run without an API key. When a judge is wired in,
it replaces this function and nothing else changes.
"""
def overlap_score(actual: str, expected: str) -> float {
    want = set(normalize_tokens(expected));
    got = set(normalize_tokens(actual));
    if len(want) == 0 {
        return 1.0 if len(got) > 0 else 0.0;
    }
    if len(got) == 0 {
        return 0.0;
    }
    shared = len(want & got);
    if shared == 0 {
        return 0.0;
    }
    precision = shared / len(got);
    recall = shared / len(want);
    return 2.0 * precision * recall / (precision + recall);
}


obj TraceFacts {
    has steps: int = 0;
    has errors: int = 0;
    has skipped: int = 0;
    has empty_outputs: int = 0;
    has failing_nodes: list[str] = [];
    has silent_nodes: list[str] = [];
    has executed_nodes: list[str] = [];
}


def read_trace(execution_trace: list) -> TraceFacts {
    facts = TraceFacts();
    for raw in execution_trace {
        step = raw as dict;
        status = str(step["status"]) if "status" in step else "";
        node_id = str(step["node_id"]) if "node_id" in step else "";
        error = str(step["error_message"]) if "error_message" in step else "";
        output = str(step["output_generated"]) if "output_generated" in step else "";

        if status == "SKIPPED" {
            facts.skipped += 1;
            continue;
        }
        facts.steps += 1;
        if node_id != "" and not (node_id in facts.executed_nodes) {
            facts.executed_nodes.append(node_id);
        }
        if error != "" {
            facts.errors += 1;
            if not (node_id in facts.failing_nodes) {
                facts.failing_nodes.append(node_id);
            }
        } elif output.strip() == "" {
            facts.empty_outputs += 1;
            if not (node_id in facts.silent_nodes) {
                facts.silent_nodes.append(node_id);
            }
        }
    }
    return facts;
}


"""Critic score in [0,1]: output quality, discounted by execution failures."""
def critic_score(actual: str, expected: str, facts: TraceFacts) -> float {
    quality = overlap_score(actual, expected);
    if facts.steps == 0 {
        return 0.0;
    }
    reliability = 1.0 - (facts.errors + facts.empty_outputs) / facts.steps;
    return max(min(quality * max(reliability, 0.0), 1.0), 0.0);
}


def record(memory: OptimizerMemory, sig: str, task_key: str, score: float) -> Observation {
    for existing in [memory ->:Observed:->] {
        if existing.workflow_sig == sig and existing.task_key == task_key {
            existing.score = score;
            return existing;
        }
    }
    memory.calls += 1;
    obs = Observation(workflow_sig=sig, task_key=task_key, score=score, seq=memory.calls);
    memory +>:Observed:+> obs;
    return obs;
}


def scores_for(memory: OptimizerMemory, sig: str) -> dict[str, float] {
    out: dict[str, float] = {};
    for obs in [memory ->:Observed:->] {
        if obs.workflow_sig == sig {
            out[obs.task_key] = obs.score;
        }
    }
    return out;
}


"""The verdict shown in the training console.

This is the part that matters. Reporting a bare score that went up invites the
reader to conclude the workflow improved; on one task it is a single sample and
that conclusion is unsupported. The wording below says which of the two
situations the user is actually in.
"""
def verdict(memory: OptimizerMemory, sig: str, previous_sig: str, score: float) -> str {
    if previous_sig == "" or previous_sig == sig {
        return (
            f"score {score:.3f} on 1 task. Baseline observation - no comparison yet. "
            "Run the same tasks again after a mutation to get a paired delta."
        );
    }

    before = scores_for(memory, previous_sig);
    after = scores_for(memory, sig);
    paired: PairedResult = paired_from_maps(before, after);

    if paired.n == 0 {
        return (
            f"score {score:.3f}. No task has been run under both versions yet, so "
            "there is nothing to compare - re-run the earlier tasks to build a pair."
        );
    }
    if paired.n < 2 {
        return (
            f"score {score:.3f}. Paired delta {paired.mean_delta:+.3f} on n=1 - a single "
            "paired task has no variance estimate, so this is directional only. "
            "At least 2 shared tasks are needed for a standard error, and roughly 20 "
            "for the gate to resolve a realistic effect."
        );
    }

    supported = passes_gate(paired, memory.gate_k, memory.gate_floor);
    threshold = max(memory.gate_k * paired.se, memory.gate_floor);
    if supported {
        return (
            f"score {score:.3f}. Paired delta {paired.mean_delta:+.3f} +/- {paired.se:.3f} "
            f"on n={paired.n} shared tasks - clears the {threshold:.3f} bar. "
            "Supported by the evidence so far; confirm on held-out tasks before shipping."
        );
    }
    return (
        f"score {score:.3f}. Paired delta {paired.mean_delta:+.3f} +/- {paired.se:.3f} "
        f"on n={paired.n} shared tasks - does NOT clear the {threshold:.3f} bar. "
        "This change is not distinguishable from noise; more tasks, not more rounds, "
        "is what would settle it."
    );
}


def worker_states(agent_states: list) -> list {
    out: list = [];
    for raw in agent_states {
        state = raw as dict;
        kind = str(state["type"]) if "type" in state else "";
        if kind == "WorkerAgent" {
            out.append(state);
        }
    }
    return out;
}


"""Workers that actually ran this trace — never the SKIPPED twin on a fan-out."""
def executed_worker_states(agent_states: list, facts: TraceFacts) -> list {
    out: list = [];
    for raw in agent_states {
        state = raw as dict;
        kind = str(state["type"]) if "type" in state else "";
        nid = str(state["node_id"]) if "node_id" in state else "";
        if kind == "WorkerAgent" and nid in facts.executed_nodes {
            out.append(state);
        }
    }
    return out;
}


def state_for(agent_states: list, node_id: str) -> dict {
    for raw in agent_states {
        state = raw as dict;
        if "node_id" in state and str(state["node_id"]) == node_id {
            return state;
        }
    }
    return {};
}


def prompt_of(state: dict) -> str {
    return str(state["current_sem_prompt"]) if "current_sem_prompt" in state else "";
}


"""Propose prompt edits from trace evidence (sections 10 and 12).

Targeted, not boilerplate: a node that errored gets a robustness instruction, a
node that produced nothing gets an output-shape instruction, and only when
neither applies does an under-performing run get a grounding instruction aimed
at the terms the expected output actually contains.

Each edit is applied at most once per node - re-appending the same sentence
every round is how a mock produces a climbing score without changing behavior.
"""
def propose_mutations(
    agent_states: list,
    facts: TraceFacts,
    actual: str,
    expected: str
) -> list {
    mutations: list = [];
    touched: list[str] = [];

    for node_id in facts.failing_nodes {
        state = state_for(agent_states, node_id);
        if len(state) > 0 {
            prompt = prompt_of(state);
            addition = "If an input is missing or malformed, state what is missing instead of guessing.";
            if addition not in prompt {
                mutations.append({"node_id": node_id, "new_sem_prompt": prompt + " " + addition});
                touched.append(node_id);
            }
        }
    }

    for node_id in facts.silent_nodes {
        state = state_for(agent_states, node_id);
        if len(state) > 0 and not (node_id in touched) {
            prompt = prompt_of(state);
            addition = "Always produce a non-empty answer in the requested output format.";
            if addition not in prompt {
                mutations.append({"node_id": node_id, "new_sem_prompt": prompt + " " + addition});
                touched.append(node_id);
            }
        }
    }

    if len(mutations) == 0 {
        missing = [t for t in set(normalize_tokens(expected)) if not (t in set(normalize_tokens(actual)))];
        # Target the worker(s) that ran — workers[0] is always Billing in the demo
        # and wrongly accumulates Technical-pair edits onto it.
        workers = executed_worker_states(agent_states, facts);
        if len(workers) > 0 and len(missing) > 0 {
            focus = ", ".join(sorted(missing)[:5]);
            addition = f"Make sure the answer addresses: {focus}.";
            for raw in workers {
                target = raw as dict;
                node_id = str(target["node_id"]);
                if node_id in touched {
                    continue;
                }
                prompt = prompt_of(target);
                if addition not in prompt {
                    mutations.append({"node_id": node_id, "new_sem_prompt": prompt + " " + addition});
                    touched.append(node_id);
                }
            }
        }
    }

    return mutations;
}


"""Satisfy the engine's `optimize` contract using the real scoring machinery.

Returns the RLOptimizerResponse shape from schemas/rl_optimizer_response.json:
`critic_score`, `analysis_log`, `prompt_mutations`.
"""
def optimize_with_memory(payload: dict, memory: OptimizerMemory) -> dict {
    task_context = payload["task_context"] as dict if "task_context" in payload else {};
    agent_states = payload["agent_states"] as list if "agent_states" in payload else [];
    execution_trace = payload["execution_trace"] as list if "execution_trace" in payload else [];

    initial_input = str(task_context["initial_input"]) if "initial_input" in task_context else "";
    expected = str(task_context["expected_ground_truth"]) if "expected_ground_truth" in task_context else "";
    actual = str(task_context["actual_final_output"]) if "actual_final_output" in task_context else "";

    facts = read_trace(execution_trace);
    score = critic_score(actual, expected, facts);

    sig = workflow_signature(agent_states);
    task_key = short_hash(initial_input + "||" + expected);

    if sig != memory.current_signature {
        memory.previous_signature = memory.current_signature;
        memory.current_signature = sig;
    }

    record(memory, sig, task_key, score);
    summary = verdict(memory, sig, memory.previous_signature, score);

    mutations = propose_mutations(agent_states, facts, actual, expected);

    trace_note = f"{facts.steps} executed, {facts.skipped} skipped, {facts.errors} errored";
    if len(mutations) == 0 {
        return {
            "critic_score": round(score, 4),
            "analysis_log": f"{summary} Trace: {trace_note}. No targeted edit available - the trace shows no failing or silent node, and the output already covers the expected terms.",
            "prompt_mutations": []
        };
    }

    targets = ", ".join([str((m as dict)["node_id"]) for m in mutations]);
    return {
        "critic_score": round(score, 4),
        "analysis_log": f"{summary} Trace: {trace_note}. Proposed {len(mutations)} edit(s) targeting {targets}.",
        "prompt_mutations": mutations
    };
}
