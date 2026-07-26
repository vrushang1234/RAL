"""The candidate archive and Pareto frontier.

Spec: docs/rl-optimization.md section 14.1.

A single incumbent carried forward is a greedy hill-climber, and it stalls
before reaching the structural changes that matter most. The archive is what
lets the search leave a local optimum: the parent for the next round is SAMPLED
from the top-k, not always taken as the current best.

Scores live on `ArchiveEntry` nodes rather than on the `Holds` edge because Jac
edge objects cannot be correlated back to their endpoints - reading a score off
an edge would depend on undocumented iteration order.
"""

import random;
import from rl.ir { WorkflowVersion }


node Archive {
    has capacity: int = 8;
}


node ArchiveEntry {
    has config_hash: str;
    has score: float;
    has quality: float;
    has cost_usd: float;
    has latency_ms: float;
    has round_no: int = 0;
    has label: str = "";
}


edge Holds: Archive --> ArchiveEntry {
    has note: str = "";
}


edge Refers: ArchiveEntry --> WorkflowVersion {
    has note: str = "";
}


def entry_score_key(e: ArchiveEntry) -> float {
    return -e.score;
}


def entries_of(archive: Archive) -> list[ArchiveEntry] {
    return sorted([archive ->:Holds:->], key=entry_score_key);
}


def version_of(item: ArchiveEntry) -> WorkflowVersion | None {
    found = [item ->:Refers:->];
    if len(found) == 0 {
        return None;
    }
    return found[0];
}


def find_entry(archive: Archive, config_hash: str) -> ArchiveEntry | None {
    for e in entries_of(archive) {
        if e.config_hash == config_hash {
            return e;
        }
    }
    return None;
}


"""Insert a version, or update it in place if the hash is already archived.

Content addressing makes de-duplication free: the same configuration reached by
two different mutation paths is one entry, not two.
"""
def admit(
    archive: Archive,
    wf: WorkflowVersion,
    score: float,
    quality: float,
    cost_usd: float,
    latency_ms: float
) -> ArchiveEntry {
    existing = find_entry(archive, wf.config_hash);
    if existing is not None {
        existing.score = score;
        existing.quality = quality;
        existing.cost_usd = cost_usd;
        existing.latency_ms = latency_ms;
        return existing;
    }

    entry = ArchiveEntry(
        config_hash=wf.config_hash,
        score=score,
        quality=quality,
        cost_usd=cost_usd,
        latency_ms=latency_ms,
        round_no=wf.round_no,
        label=wf.label
    );
    archive +>:Holds:+> entry;
    entry +>:Refers:+> wf;
    return entry;
}


"""Drop everything past capacity, lowest score first."""
def prune(archive: Archive) -> int {
    ranked = entries_of(archive);
    if len(ranked) <= archive.capacity {
        return 0;
    }
    doomed = ranked[archive.capacity:];
    for e in doomed {
        del e;
    }
    return len(doomed);
}


def best_entry(archive: Archive) -> ArchiveEntry | None {
    ranked = entries_of(archive);
    if len(ranked) == 0 {
        return None;
    }
    return ranked[0];
}


"""Sample a parent for the next round, weighted toward higher scores.

This is the mechanism that escapes local optima. Always taking the best entry
reduces the archive to a single incumbent and reintroduces exactly the stall
it exists to prevent - so `temperature` should not be set to 0 without a
reason.
"""
def sample_parent(archive: Archive, seed: int, temperature: float) -> ArchiveEntry | None {
    ranked = entries_of(archive);
    if len(ranked) == 0 {
        return None;
    }
    if len(ranked) == 1 or temperature <= 0.0 {
        return ranked[0];
    }

    # Rank-based weights: robust to the scale of the score, unlike softmax.
    weights: list[float] = [];
    total = 0.0;
    for i in range(len(ranked)) {
        w = 1.0 / ((i + 1) ** (1.0 / temperature));
        weights.append(w);
        total += w;
    }

    rng = random.Random(seed);
    draw = rng.random() * total;
    running = 0.0;
    for i in range(len(ranked)) {
        running += weights[i];
        if draw <= running {
            return ranked[i];
        }
    }
    return ranked[len(ranked) - 1];
}


"""True when `a` is at least as good on every objective and better on one."""
def dominates(a: ArchiveEntry, b: ArchiveEntry) -> bool {
    not_worse = (
        a.quality >= b.quality
        and a.cost_usd <= b.cost_usd
        and a.latency_ms <= b.latency_ms
    );
    strictly_better = (
        a.quality > b.quality
        or a.cost_usd < b.cost_usd
        or a.latency_ms < b.latency_ms
    );
    return not_worse and strictly_better;
}


"""The non-dominated set (section 14.1).

There is often no single best configuration. Reporting one operating point
hides a decision that belongs to the user, so the final report shows the
frontier and lets them choose.
"""
def pareto_frontier(archive: Archive) -> list[ArchiveEntry] {
    all_entries = entries_of(archive);
    front: list[ArchiveEntry] = [];
    for a in all_entries {
        beaten = False;
        for b in all_entries {
            if b.config_hash != a.config_hash and dominates(b, a) {
                beaten = True;
            }
        }
        if not beaten {
            front.append(a);
        }
    }
    return front;
}


obj OperatingPoints {
    has best_quality: str = "";
    has best_cost: str = "";
    has best_latency: str = "";
    has best_overall: str = "";
}


"""Name the four operating points a user actually chooses between."""
def operating_points(archive: Archive) -> OperatingPoints {
    front = pareto_frontier(archive);
    if len(front) == 0 {
        return OperatingPoints();
    }

    best_q = front[0];
    best_c = front[0];
    best_l = front[0];
    for e in front {
        if e.quality > best_q.quality {
            best_q = e;
        }
        if e.cost_usd < best_c.cost_usd {
            best_c = e;
        }
        if e.latency_ms < best_l.latency_ms {
            best_l = e;
        }
    }

    overall = best_entry(archive);
    return OperatingPoints(
        best_quality=best_q.config_hash,
        best_cost=best_c.config_hash,
        best_latency=best_l.config_hash,
        best_overall=overall.config_hash if overall is not None else ""
    );
}
