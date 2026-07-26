"""Tests for the engine<->optimizer adapter.

The verdict wording is the point of these tests, not decoration: the whole
reason this adapter exists is that the single-shot contract invites reporting a
number that went up as evidence of improvement.
"""

import from rl.bridge {
    OptimizerMemory, workflow_signature, overlap_score, read_trace,
    critic_score, propose_mutations, optimize_with_memory, scores_for
}


def state(node_id: str, kind: str, prompt: str) -> dict {
    return {
        "node_id": node_id,
        "agent_name": node_id,
        "type": kind,
        "fixed_role_description": "role",
        "expected_input": "{}",
        "expected_output": "{}",
        "current_sem_prompt": prompt
    };
}


def step(node_id: str, status: str, output: str, error: str) -> dict {
    return {
        "step": 1,
        "node_id": node_id,
        "status": status,
        "input_received": "in",
        "output_generated": output,
        "error_message": error
    };
}


def payload_for(states: list, trace: list, initial: str, expected: str, actual: str) -> dict {
    return {
        "workflow_run_id": "run-1",
        "task_context": {
            "initial_input": initial,
            "expected_ground_truth": expected,
            "actual_final_output": actual
        },
        "agent_states": states,
        "edges": [],
        "execution_trace": trace
    };
}


def fresh_memory() -> OptimizerMemory {
    return OptimizerMemory();
}


test "the workflow signature tracks prompts, not node order" {
    a = [state("n1", "WorkerAgent", "alpha"), state("n2", "WorkerAgent", "beta")];
    b = [state("n2", "WorkerAgent", "beta"), state("n1", "WorkerAgent", "alpha")];
    assert workflow_signature(a) == workflow_signature(b), "order must not change the version";

    c = [state("n1", "WorkerAgent", "alpha CHANGED"), state("n2", "WorkerAgent", "beta")];
    assert workflow_signature(a) != workflow_signature(c), "a prompt edit is a new version";
}


test "overlap scoring rewards covering the expected terms" {
    perfect = overlap_score("refund the duplicate charge", "refund the duplicate charge");
    partial = overlap_score("refund issued", "refund the duplicate charge");
    missing = overlap_score("weather is fine today", "refund the duplicate charge");

    assert abs(perfect - 1.0) < 1e-9;
    assert partial > missing;
    assert abs(missing) < 1e-9;
}


test "an empty answer scores zero" {
    assert overlap_score("", "something expected") == 0.0;
}


test "the trace reader separates skipped, errored, and silent nodes" {
    trace = [
        step("a", "SUCCESS", "good output", ""),
        step("b", "FAILED", "", "boom"),
        step("c", "SUCCESS", "", ""),
        step("d", "SKIPPED", "", "")
    ];
    facts = read_trace(trace);
    assert facts.steps == 3, "skipped nodes are not executions";
    assert facts.skipped == 1;
    assert facts.errors == 1 and facts.failing_nodes == ["b"];
    assert facts.empty_outputs == 1 and facts.silent_nodes == ["c"];
}


test "execution failures discount the critic score" {
    clean = read_trace([step("a", "SUCCESS", "refund the duplicate charge", "")]);
    broken = read_trace([
        step("a", "SUCCESS", "refund the duplicate charge", ""),
        step("b", "FAILED", "", "boom")
    ]);
    good = critic_score("refund the duplicate charge", "refund the duplicate charge", clean);
    bad = critic_score("refund the duplicate charge", "refund the duplicate charge", broken);
    assert abs(good - 1.0) < 1e-9;
    assert bad < good, "a failing node must cost score even when the answer is right";
}


test "a failing node gets a targeted robustness edit" {
    states = [state("w1", "WorkerAgent", "Answer the question.")];
    facts = read_trace([step("w1", "FAILED", "", "bad input")]);
    muts = propose_mutations(states, facts, "", "expected answer");
    assert len(muts) == 1;
    first = muts[0] as dict;
    assert str(first["node_id"]) == "w1";
    assert "missing" in str(first["new_sem_prompt"]);
}


test "a silent node gets an output-shape edit" {
    states = [state("w1", "WorkerAgent", "Answer the question.")];
    facts = read_trace([step("w1", "SUCCESS", "", "")]);
    muts = propose_mutations(states, facts, "", "expected answer");
    assert len(muts) == 1;
    first = muts[0] as dict;
    assert "non-empty" in str(first["new_sem_prompt"]);
}


test "the same sentence is never appended twice" {
    # The node already carries the robustness edit and still fails. Falling
    # through to a DIFFERENT instruction is fine; re-appending the same
    # sentence is what a mock does to manufacture a climbing score.
    sentence = "If an input is missing or malformed, state what is missing instead of guessing.";
    states = [state("w1", "WorkerAgent", "Answer the question. " + sentence)];
    facts = read_trace([step("w1", "FAILED", "", "bad input")]);

    for raw in propose_mutations(states, facts, "", "expected answer") {
        m = raw as dict;
        revised = str(m["new_sem_prompt"]);
        assert revised.count(sentence) <= 1, f"duplicated instruction: {revised}";
    }
}


test "a fully-covered failing node stops proposing" {
    # Robustness edit already applied AND the answer covers everything expected:
    # there is no evidence left to act on, so nothing should be proposed.
    sentence = "If an input is missing or malformed, state what is missing instead of guessing.";
    states = [state("w1", "WorkerAgent", "Answer. " + sentence)];
    facts = read_trace([step("w1", "FAILED", "", "bad input")]);
    assert propose_mutations(states, facts, "refund duplicate charge", "refund duplicate charge") == [];
}


test "a healthy trace with a covered answer proposes nothing" {
    states = [state("w1", "WorkerAgent", "Answer.")];
    facts = read_trace([step("w1", "SUCCESS", "refund duplicate charge", "")]);
    muts = propose_mutations(states, facts, "refund duplicate charge", "refund duplicate charge");
    assert muts == [], "no evidence of a problem means no mutation";
}


test "the first observation is reported as a baseline, not an improvement" {
    memory = fresh_memory();
    states = [state("w1", "WorkerAgent", "Answer.")];
    trace = [step("w1", "SUCCESS", "refund duplicate charge", "")];
    out = optimize_with_memory(
        payload_for(states, trace, "task one", "refund duplicate charge", "refund duplicate charge"),
        memory
    );
    log = str(out["analysis_log"]);
    assert "Baseline observation" in log, f"got {log}";
    assert "no comparison yet" in log;
}


test "a single paired task is reported as directional only" {
    memory = fresh_memory();
    v1 = [state("w1", "WorkerAgent", "Answer.")];
    v2 = [state("w1", "WorkerAgent", "Answer. Be specific.")];
    trace = [step("w1", "SUCCESS", "refund", "")];

    optimize_with_memory(payload_for(v1, trace, "t1", "refund duplicate charge", "refund"), memory);
    out = optimize_with_memory(
        payload_for(v2, trace, "t1", "refund duplicate charge", "refund duplicate charge"),
        memory
    );
    log = str(out["analysis_log"]);
    assert "n=1" in log, f"got {log}";
    assert "directional only" in log;
}


test "a small paired effect is called out as indistinguishable from noise" {
    memory = fresh_memory();
    v1 = [state("w1", "WorkerAgent", "Answer.")];
    v2 = [state("w1", "WorkerAgent", "Answer. Be specific.")];
    trace = [step("w1", "SUCCESS", "x", "")];

    # Two tasks under v1, then the same two under v2 with a tiny, noisy change.
    optimize_with_memory(payload_for(v1, trace, "t1", "alpha beta gamma", "alpha"), memory);
    optimize_with_memory(payload_for(v1, trace, "t2", "delta epsilon zeta", "delta epsilon"), memory);
    optimize_with_memory(payload_for(v2, trace, "t1", "alpha beta gamma", "alpha beta"), memory);
    out = optimize_with_memory(payload_for(v2, trace, "t2", "delta epsilon zeta", "delta"), memory);

    log = str(out["analysis_log"]);
    assert "n=2" in log, f"got {log}";
    assert "does NOT clear" in log, f"got {log}";
    assert "not distinguishable from noise" in log;
}


test "a large consistent paired effect is reported as supported" {
    memory = fresh_memory();
    v1 = [state("w1", "WorkerAgent", "Answer.")];
    v2 = [state("w1", "WorkerAgent", "Answer. Be specific.")];
    trace = [step("w1", "SUCCESS", "x", "")];

    # v1 misses everything; v2 nails everything, on three shared tasks.
    optimize_with_memory(payload_for(v1, trace, "t1", "alpha beta", "zzz"), memory);
    optimize_with_memory(payload_for(v1, trace, "t2", "gamma delta", "zzz"), memory);
    optimize_with_memory(payload_for(v1, trace, "t3", "epsilon zeta", "zzz"), memory);
    optimize_with_memory(payload_for(v2, trace, "t1", "alpha beta", "alpha beta"), memory);
    optimize_with_memory(payload_for(v2, trace, "t2", "gamma delta", "gamma delta"), memory);
    out = optimize_with_memory(payload_for(v2, trace, "t3", "epsilon zeta", "epsilon zeta"), memory);

    log = str(out["analysis_log"]);
    assert "n=3" in log, f"got {log}";
    assert "clears the" in log, f"got {log}";
    assert "Supported by the evidence" in log;
}


test "scoring several tasks under one version never compares it to itself" {
    memory = fresh_memory();
    v1 = [state("w1", "WorkerAgent", "Answer.")];
    trace = [step("w1", "SUCCESS", "x", "")];

    optimize_with_memory(payload_for(v1, trace, "t1", "alpha", "alpha"), memory);
    out = optimize_with_memory(payload_for(v1, trace, "t2", "beta", "beta"), memory);
    assert "Baseline observation" in str(out["analysis_log"]),
        "a second task under the same version is still a baseline, not a comparison";
    assert memory.previous_signature == "";
}


test "re-scoring the same task under the same version updates rather than duplicates" {
    memory = fresh_memory();
    v1 = [state("w1", "WorkerAgent", "Answer.")];
    trace = [step("w1", "SUCCESS", "x", "")];

    optimize_with_memory(payload_for(v1, trace, "t1", "alpha beta", "alpha"), memory);
    optimize_with_memory(payload_for(v1, trace, "t1", "alpha beta", "alpha beta"), memory);

    sig = workflow_signature(v1);
    recorded = scores_for(memory, sig);
    assert len(recorded) == 1, "one task under one version is one observation";
    for k in recorded.keys() {
        assert abs(recorded[k] - 1.0) < 1e-9, "the later score must win";
    }
}


test "the response matches the RLOptimizerResponse schema" {
    memory = fresh_memory();
    states = [state("w1", "WorkerAgent", "Answer.")];
    trace = [step("w1", "FAILED", "", "boom")];
    out = optimize_with_memory(payload_for(states, trace, "t", "expected", ""), memory);

    assert "critic_score" in out and "analysis_log" in out and "prompt_mutations" in out;
    score = out["critic_score"] as float;
    assert score >= 0.0 and score <= 1.0;
    for raw in (out["prompt_mutations"] as list) {
        m = raw as dict;
        assert "node_id" in m and "new_sem_prompt" in m;
    }
}
