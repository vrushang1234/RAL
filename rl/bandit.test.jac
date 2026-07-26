"""Tests for family selection, phase gating, and the sliding window."""

def new_bandit(phase: int) -> BanditState {
    return init_bandit(BanditState(seed=5, window_size=3), phase);
}


test "phase 1 unlocks only the cheapest family" {
    st = new_bandit(1);
    unlocked = [a.family_key for a in arms_of(st) if a.unlocked];
    assert unlocked == ["runtime"], f"got {unlocked}";
}


test "phases add to the action set rather than replacing it" {
    assert families_for_phase(1) == ["runtime"];
    assert "runtime" in families_for_phase(5), "earlier phases must stay unlocked";
    assert "topology" in families_for_phase(5);
    assert "topology" not in families_for_phase(4);
    assert len(families_for_phase(5)) == 6;
}


test "advancing the phase unlocks new arms and reports which" {
    st = new_bandit(1);
    freshly = apply_phase(st, 2);
    assert sorted(freshly) == ["model", "tool"], f"got {freshly}";
    unlocked = sorted([a.family_key for a in arms_of(st) if a.unlocked]);
    assert unlocked == ["model", "runtime", "tool"];
}


test "re-applying the same phase unlocks nothing new" {
    st = new_bandit(2);
    assert apply_phase(st, 2) == [], "already-unlocked arms are not re-reported";
}


test "selection never returns a locked family" {
    st = new_bandit(1);
    for _i in range(10) {
        picked = select_family(st);
        assert picked == "runtime", f"locked family selected: {picked}";
        record_pull(st, picked, 0.0);
    }
}


test "every unlocked arm gets tried before any is repeated" {
    st = new_bandit(5);
    seen: list[str] = [];
    for _i in range(6) {
        picked = select_family(st);
        seen.append(picked);
        record_pull(st, picked, 0.0);
    }
    assert len(set(seen)) == 6, f"unpulled arms must be explored first: {seen}";
}


test "a rewarding arm is preferred once every arm has been tried" {
    # explore_c = 0 isolates the value ordering. With the exploration bonus on,
    # a single-pull arm can still outrank a proven one - which is the bonus
    # doing its job, not a bug.
    st = init_bandit(BanditState(seed=5, window_size=3, explore_c=0.0), 5);
    for _i in range(6) {
        picked = select_family(st);
        record_pull(st, picked, 0.0);
    }
    record_pull(st, "model", 0.5);
    record_pull(st, "model", 0.5);
    assert select_family(st) == "model";
}


test "the exploration bonus can still outrank a proven arm" {
    st = new_bandit(5);
    for _i in range(6) {
        picked = select_family(st);
        record_pull(st, picked, 0.0);
    }
    record_pull(st, "model", 0.5);
    record_pull(st, "model", 0.5);

    proven = arm_for(st, "model");
    thin = arm_for(st, "topology");
    assert proven is not None and thin is not None;
    if proven is not None and thin is not None {
        assert arm_value(proven) > arm_value(thin);
        assert ucb(thin, st.total_pulls, 0.7) > ucb(proven, st.total_pulls, 0.7),
            "a barely-sampled arm keeps a wide bonus - that is the point of UCB";
    }
}


test "the window slides so stale rewards stop counting" {
    st = new_bandit(5);
    # window_size is 3.
    record_pull(st, "model", 1.0);
    record_pull(st, "model", 0.0);
    record_pull(st, "model", 0.0);
    arm = arm_for(st, "model");
    assert arm is not None;
    if arm is not None {
        assert abs(arm_value(arm) - (1.0 / 3.0)) < 1e-9;
        record_pull(st, "model", 0.0);
        assert abs(arm_value(arm)) < 1e-9, "the early win must age out of the window";
        assert arm.pulls == 4, "pull count is lifetime, not windowed";
        assert abs(arm.lifetime_reward - 1.0) < 1e-9;
    }
}


test "an unpulled arm has no estimate rather than a zero one" {
    st = new_bandit(5);
    arm = arm_for(st, "topology");
    assert arm is not None;
    if arm is not None {
        assert arm.pulls == 0;
        assert ucb(arm, 10, 0.7) > 1000.0, "never-tried arms must dominate selection";
    }
}


test "recording against an unknown family is refused" {
    st = new_bandit(1);
    assert not record_pull(st, "telepathy", 1.0);
    assert st.total_pulls == 0;
}


test "arm reporting exposes pulls and window mean" {
    st = new_bandit(2);
    record_pull(st, "model", 0.2);
    record_pull(st, "model", 0.4);
    rows = report_arms(st);
    assert len(rows) == 6;
    for r in rows {
        if r.family_key == "model" {
            assert r.pulls == 2;
            assert abs(r.mean_reward - 0.3) < 1e-9;
            assert r.unlocked;
        }
        if r.family_key == "topology" {
            assert not r.unlocked;
        }
    }
}


test "family keys round-trip through the enum" {
    for f in all_families() {
        assert family_from_key(family_name(f)) == f;
    }
}
