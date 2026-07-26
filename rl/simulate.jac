"""A deterministic environment for developing and demonstrating the optimizer.

This is a SIMULATOR, not a model of any real workload. It exists because the
search loop needs an environment where the ground truth is known, so that tests
can assert the optimizer finds a specific improvement rather than merely
"changing something". The live path is `agent_llm.jac`.

The simulated world encodes the situation from section 22:

  - Classification is easy: a small model is fully adequate, so swapping the
    classifier to a cheaper model should cost nothing in quality.
  - Internal documentation is broadly useful; web search helps only on tasks
    that genuinely need recent information.
  - A reviewer only adds value when the upstream answer is already weak, so a
    conditional reviewer should dominate an unconditional one.

Every quantity is a pure function of the task id and the configuration, so
repeated evaluation of the same pair returns identical results - no sampling
noise is injected. That is deliberate: variance in the tests should come from
task difficulty, which pairing cancels, not from the environment.
"""

import hashlib;


obj ModelSpec {
    has name: str;
    has in_per_1k: float;
    has out_per_1k: float;
    has skill: float;
}


glob MODELS: dict[str, ModelSpec] = {
    "small": ModelSpec(name="small", in_per_1k=0.00015, out_per_1k=0.0006, skill=0.86),
    "large": ModelSpec(name="large", in_per_1k=0.0030, out_per_1k=0.0150, skill=0.94)
};


def model_spec(name: str) -> ModelSpec {
    if name in MODELS {
        return MODELS[name];
    }
    return ModelSpec(name=name, in_per_1k=0.001, out_per_1k=0.004, skill=0.80);
}


"""Stable pseudo-random value in [0,1) from a string - no RNG state involved."""
def unit_hash(s: str) -> float {
    digest = hashlib.sha256(s.encode("utf-8")).hexdigest()[:8];
    return int(digest, 16) / 4294967296.0;
}


obj SimTask {
    has task_id: str;
    has difficulty: float;
    has needs_docs: bool = True;
    has needs_web: bool = False;
}


"""Derive hidden task properties. `technical/hard` tasks need recent information."""
def sim_task(task_id: str, category: str, difficulty: str) -> SimTask {
    d = unit_hash(task_id + "|difficulty");
    if difficulty == "hard" {
        d = 0.5 + d * 0.5;
    } else {
        d = d * 0.5;
    }
    return SimTask(
        task_id=task_id,
        difficulty=d,
        needs_docs=True,
        needs_web=(category == "technical" and difficulty == "hard")
    );
}


obj AgentOutcome {
    has quality: float;
    has input_tokens: int;
    has output_tokens: int;
    has cost_usd: float;
    has tools_invoked: list[str] = [];
    has tool_influenced: bool = False;
    has tool_error: bool = False;
    has doc_coverage: float = 0.0;
    has schema_ok: bool = True;
}


"""Does this agent's prompt tell it to prefer internal docs over the web?

The optimizer discovers this instruction through prompt mutation; the simulator
rewards it by cutting wasted web calls on tasks that do not need them.
"""
def prefers_docs(prompt: str) -> bool {
    low = prompt.lower();
    return "documentation before" in low or "docs before" in low or "internal documentation first" in low;
}


def requires_json(prompt: str) -> bool {
    return "json" in prompt.lower();
}


"""How well a token budget fits the work - starved budgets lose quality."""
def budget_fit(max_tokens: int, needed: int) -> float {
    if max_tokens >= needed {
        return 1.0;
    }
    return max(max_tokens / needed, 0.25);
}


"""Simulate one agent invocation.

`role_kind` is derived from the agent's role text: classifier / support /
reviewer. Anything else is treated as a generic worker.
"""
def role_kind(role: str) -> str {
    low = role.lower();
    if "classif" in low {
        return "classifier";
    }
    if "review" in low {
        return "reviewer";
    }
    if "resolve" in low or "support" in low or "answer" in low {
        return "support";
    }
    return "worker";
}


def classify_outcome(model: ModelSpec, _task: SimTask, max_tokens: int) -> AgentOutcome {
    # Classification is easy: any model at or above 0.85 skill saturates it,
    # so difficulty is deliberately unused here. This is the ground truth that
    # makes the classifier model-swap in section 22 a free win.
    competence = 1.0 if model.skill >= 0.85 else model.skill / 0.85;
    fit = budget_fit(max_tokens, 200);
    out_tokens = 60;
    return AgentOutcome(
        quality=min(competence * fit, 1.0),
        input_tokens=250,
        output_tokens=out_tokens,
        cost_usd=(250 * model.in_per_1k + out_tokens * model.out_per_1k) / 1000.0
    );
}


def support_outcome(
    model: ModelSpec,
    task: SimTask,
    tools: list[str],
    prompt: str,
    max_tokens: int
) -> AgentOutcome {
    has_docs = "doc_search" in tools;
    has_web = "web_search" in tools;
    docs_first = prefers_docs(prompt);

    invoked: list[str] = [];
    doc_coverage = 0.0;
    influenced = False;

    if has_docs {
        invoked.append("doc_search");
        doc_coverage = 0.85 if task.needs_docs else 0.4;
        influenced = True;
    }

    # Without the docs-first instruction the agent also searches the web
    # speculatively; with it, only when documentation came up short.
    web_called = False;
    if has_web {
        if docs_first {
            web_called = doc_coverage < 0.5 or task.needs_web;
        } else {
            web_called = True;
        }
    }
    if web_called {
        invoked.append("web_search");
        if task.needs_web {
            influenced = True;
        }
    }

    evidence = 0.0;
    if has_docs and task.needs_docs {
        evidence += 0.20;
    }
    if task.needs_web {
        evidence += 0.15 if web_called else -0.20;
    }

    # Scaled so quality does NOT saturate at 1.0. Headroom matters: with every
    # answer already perfect there is nothing for a reviewer to fix, and the
    # conditional-reviewer result from section 22 could never be reproduced.
    fit = budget_fit(max_tokens, 900);
    base = model.skill * (1.0 - 0.45 * task.difficulty) * 0.75;
    quality = max(min((base + evidence) * fit, 1.0), 0.0);

    out_tokens = int(420 * fit);
    in_tokens = 800 + 300 * len(invoked);
    return AgentOutcome(
        quality=quality,
        input_tokens=in_tokens,
        output_tokens=out_tokens,
        cost_usd=(in_tokens * model.in_per_1k + out_tokens * model.out_per_1k) / 1000.0,
        tools_invoked=invoked,
        tool_influenced=influenced,
        doc_coverage=doc_coverage,
        schema_ok=(not requires_json(prompt)) or model.skill >= 0.8
    );
}


"""A reviewer lifts weak answers and leaves strong ones alone.

This is what makes an unconditional reviewer wasteful and a conditional one
valuable - and it is exactly the distinction section 22 turns on.
"""
def review_outcome(model: ModelSpec, upstream_quality: float, max_tokens: int) -> AgentOutcome {
    headroom = max(1.0 - upstream_quality, 0.0);
    lift = headroom * 0.55 * model.skill if upstream_quality < 0.80 else 0.0;
    fit = budget_fit(max_tokens, 400);
    out_tokens = int(180 * fit);
    return AgentOutcome(
        quality=min(upstream_quality + lift * fit, 1.0),
        input_tokens=700,
        output_tokens=out_tokens,
        cost_usd=(700 * model.in_per_1k + out_tokens * model.out_per_1k) / 1000.0
    );
}


def worker_outcome(model: ModelSpec, task: SimTask, max_tokens: int) -> AgentOutcome {
    fit = budget_fit(max_tokens, 500);
    out_tokens = int(250 * fit);
    return AgentOutcome(
        quality=min(model.skill * (1.0 - 0.3 * task.difficulty) * fit, 1.0),
        input_tokens=500,
        output_tokens=out_tokens,
        cost_usd=(500 * model.in_per_1k + out_tokens * model.out_per_1k) / 1000.0
    );
}
