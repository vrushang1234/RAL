"""Tests for the engine<->optimizer adapter.

The verdict wording is the point of these tests, not decoration: the whole
reason this adapter exists is that the single-shot contract invites reporting a
number that went up as evidence of improvement.
"""

import from rl.bridge {
    OptimizerMemory, workflow_signature, overlap_score, read_trace,
    critic_score, propose_mutations, optimize_with_memory, scores_for,
    split_managed, parse_directives, compose_prompt,
    MANAGED_HEADER, ROBUSTNESS_TEXT, FORMAT_TEXT, COVERAGE_PREFIX, MAX_COVERAGE_TERMS
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
    muts = propose_mutations(states, facts, "", "expected answer", fresh_memory());
    assert len(muts) == 1;
    first = muts[0] as dict;
    assert str(first["node_id"]) == "w1";
    assert ROBUSTNESS_TEXT in str(first["new_sem_prompt"]);
    assert str(first["new_sem_prompt"]).startswith("Answer the question."),
        "the author's text must survive untouched";
}


test "a silent node gets an output-shape edit" {
    states = [state("w1", "WorkerAgent", "Answer the question.")];
    facts = read_trace([step("w1", "SUCCESS", "", "")]);
    muts = propose_mutations(states, facts, "", "expected answer", fresh_memory());
    assert len(muts) == 1;
    assert FORMAT_TEXT in str((muts[0] as dict)["new_sem_prompt"]);
}


test "the managed block round-trips" {
    base = "Reply to the customer.";
    directives: dict[str, str] = {"robustness": ROBUSTNESS_TEXT, "format": FORMAT_TEXT};
    composed = compose_prompt(base, directives);
    parts = split_managed(composed);
    assert parts[0] == base, f"base drifted: {parts[0]}";
    recovered = parse_directives(parts[1]);
    assert recovered["robustness"] == ROBUSTNESS_TEXT;
    assert recovered["format"] == FORMAT_TEXT;
}


test "a prompt with no managed block is all base" {
    parts = split_managed("Just the author's text.");
    assert parts[0] == "Just the author's text.";
    assert parts[1] == "";
}


test "repeating the same situation proposes nothing the second time" {
    memory = fresh_memory();
    states = [state("w1", "WorkerAgent", "Answer the question.")];
    facts = read_trace([step("w1", "FAILED", "", "bad input")]);

    first = propose_mutations(states, facts, "", "expected answer", memory);
    assert len(first) == 1;

    # Feed the revised prompt back in, exactly as the engine does.
    revised = str((first[0] as dict)["new_sem_prompt"]);
    again = propose_mutations(
        [state("w1", "WorkerAgent", revised)], facts, "", "expected answer", memory
    );
    assert again == [], f"idempotence broken: {again}";
}


test "the prompt stays bounded across many rounds on different tasks" {
    # THE regression test. Previously each task appended its own sentence, so
    # prompts grew without bound and repeated the same instruction shape.
    memory = fresh_memory();
    prompt = "Reply.";
    tasks = [
        "apologetic business confirming days number",
        "apologetic reference refunded reply within",
        "apologetic number reply will with",
        "acknowledging asking crash fix interim",
        "escalate priority ticket urgent within"
    ];

    for expected in tasks {
        states = [state("w1", "WorkerAgent", prompt)];
        facts = read_trace([step("w1", "SUCCESS", "something unrelated", "")]);
        muts = propose_mutations(states, facts, "something unrelated", expected, memory);
        if len(muts) > 0 {
            prompt = str((muts[0] as dict)["new_sem_prompt"]);
        }
    }

    assert prompt.count(COVERAGE_PREFIX) == 1,
        f"coverage guidance must appear exactly once, got:\n{prompt}";
    assert prompt.count(MANAGED_HEADER) == 1, f"one managed block only:\n{prompt}";
    assert prompt.startswith("Reply."), "the author's text must survive";

    parts = split_managed(prompt);
    directives = parse_directives(parts[1]);
    terms = directives["coverage"].replace(COVERAGE_PREFIX, "").strip().rstrip(".").split(", ");
    assert len(terms) <= MAX_COVERAGE_TERMS, f"term list must stay capped, got {len(terms)}";
}


test "coverage guidance converges and then stops mutating" {
    memory = fresh_memory();
    prompt = "Reply.";
    facts = read_trace([step("w1", "SUCCESS", "unrelated", "")]);

    # Same task twice: the second pass has nothing new to add.
    first = propose_mutations(
        [state("w1", "WorkerAgent", prompt)], facts, "unrelated", "alpha beta gamma", memory
    );
    assert len(first) == 1;
    prompt = str((first[0] as dict)["new_sem_prompt"]);

    second = propose_mutations(
        [state("w1", "WorkerAgent", prompt)], facts, "unrelated", "alpha beta gamma", memory
    );
    assert second == [], "a converged term set must stop producing mutations";
}


test "a fully-covered failing node stops proposing" {
    states = [state("w1", "WorkerAgent", compose_prompt("Answer.", {"robustness": ROBUSTNESS_TEXT}))];
    facts = read_trace([step("w1", "FAILED", "", "bad input")]);
    assert propose_mutations(
        states, facts, "refund duplicate charge", "refund duplicate charge", fresh_memory()
    ) == [];
}


test "a healthy trace with a covered answer proposes nothing" {
    states = [state("w1", "WorkerAgent", "Answer.")];
    facts = read_trace([step("w1", "SUCCESS", "refund duplicate charge", "")]);
    muts = propose_mutations(
        states, facts, "refund duplicate charge", "refund duplicate charge", fresh_memory()
    );
    assert muts == [], "no evidence of a problem means no mutation";
}


test "grounding edits target the executed worker, not the first WorkerAgent" {
    # Demo fan-out: billing is listed first but SKIPPED on a technical email.
    states = [
        state("worker_billing", "WorkerAgent", "Reply."),
        state("worker_technical", "WorkerAgent", "Answer.")
    ];
    facts = read_trace([
        step("trigger", "SUCCESS", "in", ""),
        step("router", "SUCCESS", "technical", ""),
        step("worker_billing", "SKIPPED", "", ""),
        step("worker_technical", "SUCCESS", "please reboot", ""),
        step("agg", "SUCCESS", "please reboot", "")
    ]);
    muts = propose_mutations(
        states,
        facts,
        "please reboot",
        "Reply acknowledging the crash, asking for the app version and suggesting reinstall",
        fresh_memory()
    );
    assert len(muts) == 1, f"expected one mutation, got {muts}";
    first = muts[0] as dict;
    assert str(first["node_id"]) == "worker_technical", f"got {first}";
    assert COVERAGE_PREFIX in str(first["new_sem_prompt"]);
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
