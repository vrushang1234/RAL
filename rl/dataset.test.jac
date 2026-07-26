"""Tests for splits, the fixed ordering, and validation rotation."""

def build_dataset(seed: int) -> Dataset {
    ds = Dataset(name="support", seed=seed);
    cats = ["billing", "technical", "account"];
    diffs = ["easy", "hard"];
    n = 0;
    for c in cats {
        for d in diffs {
            for _i in range(4) {
                add_task(ds, Task(
                    task_id=f"t{n}",
                    prompt=f"{c}/{d} request {n}",
                    category=c,
                    difficulty=d
                ));
                n += 1;
            }
        }
    }
    return ds;
}


test "every task lands in exactly one split" {
    ds = build_dataset(7);
    counts = stratified_split(ds, 0.5, 0.3);
    assert counts["train"] + counts["validation"] + counts["test"] == 24;
    assert counts["train"] == 12, f"got {counts}";
    assert counts["validation"] == 6, f"got {counts}";
    assert counts["test"] == 6, f"got {counts}";
}


test "splits are stratified - every category reaches the test set" {
    ds = build_dataset(7);
    _ = stratified_split(ds, 0.5, 0.3);
    test_cats = sorted(set([t.category for t in split_tasks(ds, "test")]));
    assert test_cats == ["account", "billing", "technical"], f"got {test_cats}";
}


test "a short prefix is stratified, not accidental" {
    ds = build_dataset(7);
    _ = stratified_split(ds, 0.5, 0.3);
    # Six strata, twelve train tasks: the first six must cover all six strata.
    prefix = batch_prefix(ds, "train", 6);
    assert len(prefix) == 6;
    assert stratum_balance(prefix) == 1.0, "the elimination prefix must be representative";
}


test "ordering is deterministic for a given seed" {
    a = build_dataset(11);
    b = build_dataset(11);
    _ = stratified_split(a, 0.5, 0.3);
    _ = stratified_split(b, 0.5, 0.3);
    assert task_ids(split_tasks(a, "train")) == task_ids(split_tasks(b, "train"));
}


test "a different seed gives a different ordering" {
    a = build_dataset(11);
    b = build_dataset(12);
    _ = stratified_split(a, 0.5, 0.3);
    _ = stratified_split(b, 0.5, 0.3);
    assert task_ids(split_tasks(a, "train")) != task_ids(split_tasks(b, "train"));
}


test "batch_prefix is stable across calls - candidates share a batch" {
    ds = build_dataset(7);
    _ = stratified_split(ds, 0.5, 0.3);
    first = task_ids(batch_prefix(ds, "train", 4));
    second = task_ids(batch_prefix(ds, "train", 4));
    assert first == second, "every candidate in a round must see the same tasks";
}


test "the 20-task batch extends the 4-task prefix" {
    ds = build_dataset(7);
    _ = stratified_split(ds, 0.5, 0.3);
    short = task_ids(batch_prefix(ds, "train", 4));
    long = task_ids(batch_prefix(ds, "train", 8));
    assert long[:4] == short, "stage B must reuse stage A's cached results";
}


test "validation rotation advances and wraps" {
    ds = build_dataset(7);
    _ = stratified_split(ds, 0.5, 0.3);
    r0 = task_ids(validation_subset(ds, 0, 3));
    r1 = task_ids(validation_subset(ds, 1, 3));
    r2 = task_ids(validation_subset(ds, 2, 3));
    assert len(r0) == 3 and len(r1) == 3;
    assert r0 != r1, "consecutive rounds must not reuse the same validation slice";
    assert r2 == r0, "with 6 tasks and size 3 the rotation wraps every 2 rounds";
}


test "validation subset degrades gracefully when oversized" {
    ds = build_dataset(7);
    _ = stratified_split(ds, 0.5, 0.3);
    everything = validation_subset(ds, 0, 999);
    assert len(everything) == 6;
    assert len(validation_subset(ds, 0, 0)) == 0;
}


test "a tiny stratum still yields a test task" {
    ds = Dataset(name="tiny", seed=3);
    for i in range(3) {
        add_task(ds, Task(task_id=f"x{i}", prompt="p", category="rare", difficulty="hard"));
    }
    counts = stratified_split(ds, 0.9, 0.9);
    assert counts["test"] >= 1, f"a 3-task stratum must not be fully consumed: {counts}";
}
