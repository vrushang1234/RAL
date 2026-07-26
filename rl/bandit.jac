"""Mutation-family selection and the phase schedule.

Spec: docs/rl-optimization.md sections 13 and 18.

Honest framing, because it changes what should be built and what should be
claimed: across a realistic run this bandit receives roughly 20-50 pulls spread
over six arms, against a high-variance reward. It will NOT converge. It is a
principled exploration schedule, not a learned policy, and it should never be
described to a user as the system "learning what works".

Two properties keep it from being actively harmful:
  - the reward recorded is the POST-VALIDATION reward, so an arm is not
    rewarded for candidates that later fail to generalize;
  - the estimate is a sliding window, because the problem is non-stationary -
    model swaps pay off early and are exhausted quickly, while prompt and
    topology changes matter later.
"""

import math;
import random;
import from rl.mutate { MutationFamily, family_name, all_families }


node BanditArm {
    has family_key: str;
    has pulls: int = 0;
    has window: list[float] = [];
    has lifetime_reward: float = 0.0;
    has unlocked: bool = False;
}


node BanditState {
    has explore_c: float = 0.7;
    has window_size: int = 8;
    has total_pulls: int = 0;
    has seed: int = 5;
}


edge HasArm: BanditState --> BanditArm {
    has note: str = "";
}


"""Phase schedule from section 18.

Phases order the search from low-risk to high-risk and are implemented as arm
gating: entering a phase unlocks a family, and earlier phases stay unlocked so
later phases ADD to the action set rather than replacing it.
"""
def families_for_phase(phase: int) -> list[str] {
    unlocked: list[str] = ["runtime"];
    if phase >= 2 {
        unlocked.append("model");
        unlocked.append("tool");
    }
    if phase >= 3 {
        unlocked.append("prompt");
    }
    if phase >= 4 {
        unlocked.append("context");
    }
    if phase >= 5 {
        unlocked.append("topology");
    }
    return unlocked;
}


def max_phase -> int {
    return 5;
}


def arm_key(a: BanditArm) -> str {
    return a.family_key;
}


def arms_of(state: BanditState) -> list[BanditArm] {
    return sorted([state ->:HasArm:->], key=arm_key);
}


def init_bandit(state: BanditState, phase: int) -> BanditState {
    allowed = families_for_phase(phase);
    for f in all_families() {
        key = family_name(f);
        state +>:HasArm:+> BanditArm(family_key=key, unlocked=(key in allowed));
    }
    return state;
}


def arm_for(state: BanditState, family_key: str) -> BanditArm | None {
    for a in arms_of(state) {
        if a.family_key == family_key {
            return a;
        }
    }
    return None;
}


"""Unlock every family the phase allows. Returns the newly unlocked keys."""
def apply_phase(state: BanditState, phase: int) -> list[str] {
    allowed = families_for_phase(phase);
    freshly: list[str] = [];
    for a in arms_of(state) {
        if (a.family_key in allowed) and not a.unlocked {
            a.unlocked = True;
            freshly.append(a.family_key);
        }
    }
    return freshly;
}


"""Sliding-window mean. An unpulled arm has no estimate, not a zero one."""
def arm_value(a: BanditArm) -> float {
    if len(a.window) == 0 {
        return 0.0;
    }
    return sum(a.window) / len(a.window);
}


def ucb(a: BanditArm, total_pulls: int, c: float) -> float {
    if a.pulls == 0 {
        return 1000000.0;
    }
    return arm_value(a) + c * math.sqrt(math.log(max(total_pulls, 2)) / a.pulls);
}


"""Pick a family among the UNLOCKED arms only (sections 13 and 18).

Ties among never-pulled arms are broken with a seeded RNG so a run is
reproducible.
"""
def select_family(state: BanditState) -> str {
    candidates = [a for a in arms_of(state) if a.unlocked];
    if len(candidates) == 0 {
        return "";
    }

    best_score = -1000000.0;
    best: list[str] = [];
    for a in candidates {
        score = ucb(a, state.total_pulls, state.explore_c);
        if score > best_score + 1e-12 {
            best_score = score;
            best = [a.family_key];
        } elif abs(score - best_score) <= 1e-12 {
            best.append(a.family_key);
        }
    }

    if len(best) == 1 {
        return best[0];
    }
    rng = random.Random(state.seed + state.total_pulls);
    return best[rng.randrange(len(best))];
}


"""Record the post-validation reward for an arm.

Called only after a candidate has been accepted or rejected on VALIDATION -
rewarding an arm on the train-batch delta teaches it to propose mutations that
overfit.
"""
def record_pull(state: BanditState, family_key: str, reward: float) -> bool {
    arm = arm_for(state, family_key);
    if arm is None {
        return False;
    }
    arm.pulls += 1;
    arm.lifetime_reward += reward;
    arm.window.append(reward);
    if len(arm.window) > state.window_size {
        arm.window.pop(0);
    }
    state.total_pulls += 1;
    return True;
}


obj ArmReport {
    has family_key: str;
    has pulls: int;
    has mean_reward: float;
    has unlocked: bool;
}


def report_arms(state: BanditState) -> list[ArmReport] {
    out: list[ArmReport] = [];
    for a in arms_of(state) {
        out.append(ArmReport(
            family_key=a.family_key,
            pulls=a.pulls,
            mean_reward=arm_value(a),
            unlocked=a.unlocked
        ));
    }
    return out;
}


def family_from_key(key: str) -> MutationFamily {
    if key == "prompt" { return MutationFamily.PROMPT; }
    if key == "tool" { return MutationFamily.TOOL; }
    if key == "model" { return MutationFamily.MODEL; }
    if key == "runtime" { return MutationFamily.RUNTIME; }
    if key == "context" { return MutationFamily.CONTEXT; }
    return MutationFamily.TOPOLOGY;
}
