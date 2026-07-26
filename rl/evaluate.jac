"""Output evaluation and judge hardening.

Spec: docs/rl-optimization.md section 7.

The judge is a reward-hacking surface and this optimizer mutates prompts -
which is exactly the lever that games an LLM judge. Verbosity, confident
phrasing, and removed hedging all raise judge scores without raising quality.
Four defenses, all cheap, all enforced here:

1. The judge is BLIND by construction. `judge_output` has no parameter through
   which the workflow config, the mutation, or the arm could leak.
2. Position swap is mandatory on pairwise comparisons; disagreement is a tie.
3. A small human-labeled calibration set is re-checked periodically. If
   agreement drifts, every reward computed since the last check is suspect.
4. The judge model and rubric version enter the cache key, so a judge change
   invalidates cached scores rather than silently mixing scales.
"""

import json;
import from rl.trace { RunRoot }
import from rl.stats { TaskScore }
import from rl.dataset { Task }


obj RubricScore {
    has correctness: int;
    has completeness: int;
    has actionability: int;
    has grounding: int;
    has formatting: int;
    has rationale: str = "";
}

sem RubricScore.correctness   = "0-5. Factual accuracy measured only against the supplied expected facts.";
sem RubricScore.completeness  = "0-5. Whether every part of the task was addressed.";
sem RubricScore.actionability = "0-5. Whether a reader could act on this without further clarification.";
sem RubricScore.grounding     = "0-5. 5 means no claim beyond the supplied evidence; 0 means substantial invention.";
sem RubricScore.formatting    = "0-5. Conformance to the requested output shape.";
sem RubricScore.rationale     = "One sentence naming the single biggest deduction.";


def judge_output(task: str, output: str, expected_facts: str, rubric: str) -> RubricScore by llm(temperature=0.0);

sem judge_output = "Score one candidate output against the rubric. You are not told which system produced it; do not speculate about that. Judge content, not length or tone.";
sem judge_output.task = "The original task given to the system under evaluation.";
sem judge_output.output = "The candidate output to score.";
sem judge_output.expected_facts = "Ground-truth facts. Treat anything absent here as unverified.";
sem judge_output.rubric = "The scoring rubric, one criterion per line.";


enum Winner { LEFT, RIGHT, TIE }


def compare_outputs(task: str, left: str, right: str, expected_facts: str) -> Winner by llm(temperature=0.0);

sem compare_outputs = "Decide which of two outputs better answers the task. Judge content only; ignore length and confidence of tone.";
sem compare_outputs.task = "The original task.";
sem compare_outputs.left = "First candidate output.";
sem compare_outputs.right = "Second candidate output.";
sem compare_outputs.expected_facts = "Ground-truth facts available for the task.";


def rubric_to_quality(r: RubricScore) -> float {
    total = r.correctness + r.completeness + r.actionability + r.grounding + r.formatting;
    return total / 25.0;
}


"""Pairwise comparison run in both orders (section 7.3).

Position bias in LLM judges is large enough to manufacture a winner on its own.
Running both orders and treating disagreement as a tie removes it. This costs
two judge calls instead of one and is not optional.
"""
def compare_with_swap(task: str, left: str, right: str, expected_facts: str) -> Winner {
    first = compare_outputs(task, left, right, expected_facts);
    second = compare_outputs(task, right, left, expected_facts);

    if first == Winner.LEFT and second == Winner.RIGHT {
        return Winner.LEFT;
    }
    if first == Winner.RIGHT and second == Winner.LEFT {
        return Winner.RIGHT;
    }
    return Winner.TIE;
}


enum EvalMode { DETERMINISTIC, RUBRIC, SIMULATED }


"""Version stamp for everything that affects a score (section 16.1).

Any change here must invalidate cached scores - otherwise the optimizer
compares numbers produced on two different scales and calls the difference a
reward.
"""
obj EvaluatorVersion {
    has judge_model: str = "none";
    has rubric_version: str = "v1";
    has mode: str = "simulated";
}


def evaluator_key(v: EvaluatorVersion) -> str {
    return f"{v.mode}|{v.judge_model}|{v.rubric_version}";
}


def exact_match(output: str, expected: str) -> float {
    return 1.0 if output.strip().lower() == expected.strip().lower() else 0.0;
}


def json_schema_ok(output: str, required_keys: list[str]) -> bool {
    try {
        parsed = json.loads(output);
    } except Exception {
        return False;
    }
    if not isinstance(parsed, dict) {
        return False;
    }
    for k in required_keys {
        if not (k in parsed) {
            return False;
        }
    }
    return True;
}


"""Turn a completed run into a TaskScore.

`SIMULATED` reads ground truth straight off the run and is what the tests and
the offline demo use. `DETERMINISTIC` is preferred for any real task that
admits it - it is free of judge drift and free of gaming. `RUBRIC` is the
fallback for open-ended work and is the only mode that spends a judge call.
"""
def score_run(run: RunRoot, task: Task, mode: EvalMode) -> TaskScore {
    # A run that tripped a cap or errored is a failure, not a low score - it
    # never produced an answer to judge.
    if not run.ok {
        return TaskScore(
            task_id=task.task_id,
            quality=0.0,
            cost_usd=run.total_cost_usd,
            latency_ms=run.critical_path_ms,
            failed=True,
            schema_ok=run.schema_ok
        );
    }

    quality = 0.0;
    if mode == EvalMode.SIMULATED {
        quality = run.final_quality;
    } elif mode == EvalMode.DETERMINISTIC {
        quality = exact_match(run.output_text, task.expected_output);
    } else {
        scored = judge_output(task.prompt, run.output_text, task.expected_facts, task.rubric);
        quality = rubric_to_quality(scored);
    }

    return TaskScore(
        task_id=task.task_id,
        quality=quality,
        cost_usd=run.total_cost_usd,
        latency_ms=run.critical_path_ms,
        failed=False,
        schema_ok=run.schema_ok
    );
}


obj CalibrationExample {
    has task_id: str;
    has prompt: str;
    has output: str;
    has expected_facts: str;
    has human_quality: float;
}


obj CalibrationReport {
    has n: int;
    has mean_abs_error: float;
    has agreement: float;
    has drifted: bool;
}


"""Check the judge against held-out human labels (section 7.3).

If agreement has drifted, every reward computed since the last check is
suspect - which is a much more useful thing to know than a slightly better
rubric would have been.
"""
def calibrate_judge(
    examples: list[CalibrationExample],
    rubric: str,
    tolerance: float
) -> CalibrationReport {
    n = len(examples);
    if n == 0 {
        return CalibrationReport(n=0, mean_abs_error=0.0, agreement=1.0, drifted=False);
    }

    total_error = 0.0;
    agreed = 0;
    for e in examples {
        scored = judge_output(e.prompt, e.output, e.expected_facts, rubric);
        predicted = rubric_to_quality(scored);
        err = abs(predicted - e.human_quality);
        total_error += err;
        if err <= tolerance {
            agreed += 1;
        }
    }

    mae = total_error / n;
    return CalibrationReport(
        n=n,
        mean_abs_error=mae,
        agreement=agreed / n,
        drifted=mae > tolerance
    );
}
