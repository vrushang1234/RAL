"""Task store, stratified splits, and the fixed evaluation ordering.

Spec: docs/rl-optimization.md section 3, plus validation rotation from 15.1.

Two properties matter beyond the raw train/val/test split:

1. Ordering is fixed once, at split time, and interleaved across strata. Every
   prefix of a split is therefore representative, which is what makes the short
   elimination stage in 16.2 meaningful rather than an accident of which tasks
   happened to land first.
2. Validation is rotated per round so that twelve rounds of promotion checks do
   not quietly turn the held-out set into a training set.
"""

import random;


node Dataset {
    has name: str;
    has epoch: str = "e1";
    has seed: int = 7;
}


node Task {
    has task_id: str;
    has prompt: str;
    has expected_output: str = "";
    has expected_facts: str = "";
    has rubric: str = "";
    has category: str = "general";
    has difficulty: str = "medium";
    has split: str = "train";
    has order_index: int = 0;
}


edge Contains: Dataset --> Task {
    has note: str = "";
}


def add_task(ds: Dataset, t: Task) -> Task {
    ds +>:Contains:+> t;
    return t;
}


def all_tasks(ds: Dataset) -> list[Task] {
    return [ds ->:Contains:->];
}


def stratum_of(t: Task) -> str {
    return f"{t.category}|{t.difficulty}";
}


"""Sort key for tasks. A named def, not a lambda: a lambda inside a `def` does
not bind when the module is imported elsewhere (NameError on __jac_lambda_N)."""
def task_order(t: Task) -> int {
    return t.order_index;
}


"""Assign order_index by round-robin across strata.

The point is that tasks[:k] is stratified for every k, not just for k = n.
"""
def assign_order(tasks: list[Task], seed: int) -> list[Task] {
    buckets: dict[str, list[Task]] = {};
    for t in tasks {
        key = stratum_of(t);
        if not (key in buckets) {
            buckets[key] = [];
        }
        buckets[key].append(t);
    }

    keys = sorted(buckets.keys());
    rng = random.Random(seed);
    for k in keys {
        rng.shuffle(buckets[k]);
    }

    idx = 0;
    pos = 0;
    more = True;
    while more {
        more = False;
        for k in keys {
            bucket = buckets[k];
            if pos < len(bucket) {
                bucket[pos].order_index = idx;
                idx += 1;
                more = True;
            }
        }
        pos += 1;
    }

    return sorted(tasks, key=task_order);
}


"""Split every stratum by the same fractions, then order each split (section 3).

Splitting per stratum rather than globally keeps the category mix of train,
validation, and test aligned - otherwise a rare category can land entirely in
one split and the test set measures something the optimizer never saw.
"""
def stratified_split(ds: Dataset, train_frac: float, val_frac: float) -> dict[str, int] {
    tasks = all_tasks(ds);

    buckets: dict[str, list[Task]] = {};
    for t in tasks {
        key = stratum_of(t);
        if not (key in buckets) {
            buckets[key] = [];
        }
        buckets[key].append(t);
    }

    rng = random.Random(ds.seed);
    for k in sorted(buckets.keys()) {
        bucket = buckets[k];
        rng.shuffle(bucket);
        n = len(bucket);
        n_train = int(n * train_frac);
        n_val = int(n * val_frac);
        # Guarantee a test task exists in any stratum big enough to spare one.
        if n >= 3 and n_train + n_val >= n {
            n_val = max(n - n_train - 1, 0);
        }
        for i in range(n) {
            if i < n_train {
                bucket[i].split = "train";
            } elif i < n_train + n_val {
                bucket[i].split = "validation";
            } else {
                bucket[i].split = "test";
            }
        }
    }

    counts: dict[str, int] = {"train": 0, "validation": 0, "test": 0};
    for name in ["train", "validation", "test"] {
        chosen = [t for t in tasks if t.split == name];
        assign_order(chosen, ds.seed);
        counts[name] = len(chosen);
    }
    return counts;
}


"""Tasks in one split, in the fixed evaluation order."""
def split_tasks(ds: Dataset, name: str) -> list[Task] {
    chosen = [t for t in all_tasks(ds) if t.split == name];
    return sorted(chosen, key=task_order);
}


"""The first k tasks of a split - stratified by construction (section 16.2)."""
def batch_prefix(ds: Dataset, name: str, k: int) -> list[Task] {
    return split_tasks(ds, name)[:k];
}


"""Rotate the validation subset per round (section 15.1).

Each round evaluates promotions against a different slice, so repeated
promotion checks erode the held-out set far more slowly.
"""
def validation_subset(ds: Dataset, round_no: int, size: int) -> list[Task] {
    pool = split_tasks(ds, "validation");
    n = len(pool);
    if n == 0 or size <= 0 {
        return [];
    }
    if size >= n {
        return pool;
    }
    start = (round_no * size) % n;
    out: list[Task] = [];
    for i in range(size) {
        out.append(pool[(start + i) % n]);
    }
    return out;
}


def task_ids(tasks: list[Task]) -> list[str] {
    return [t.task_id for t in tasks];
}


"""How evenly a prefix covers the strata - 1.0 means perfectly balanced.

Used to assert that the fixed ordering is doing its job rather than trusting it.
"""
def stratum_balance(tasks: list[Task]) -> float {
    if len(tasks) == 0 {
        return 1.0;
    }
    counts: dict[str, int] = {};
    for t in tasks {
        key = stratum_of(t);
        counts[key] = (counts[key] if key in counts else 0) + 1;
    }
    values = [counts[k] for k in sorted(counts.keys())];
    return min(values) / max(values);
}
