"""Read API over a persisted optimization run.

Spec: docs/rl-optimization.md sections 19, 20, 21.

These endpoints expose what a training run produced - status, the explainable
diff, and the Pareto frontier - over the graph that `demo.jac` (or any driver)
persisted under `root`. They are read-only on purpose: kicking off a multi-
thousand-call training run from an unauthenticated HTTP endpoint is not
something to hand out by default.

Each becomes `POST /walker/<Name>` under `jac start`.
"""

import from rl.ir { WorkflowVersion, Constraints, validate, ValidationIssue }
import from rl.archive { Archive, ArchiveEntry, best_entry, version_of }
import from rl.search { TrainingRun }
import from rl.bandit { BanditState, ArmReport, report_arms }
import from rl.report { ChangeRecord, FrontierRow, lineage, frontier_rows }


"""Accepted changes for the archive's current best workflow.

Returns [] rather than failing when nothing was accepted - "the optimizer found
nothing" is a legitimate outcome, not an error.
"""
def changes_for(archive: Archive) -> list[ChangeRecord] {
    best = best_entry(archive);
    if best is None {
        return [];
    }
    wf = version_of(best);
    if wf is None {
        return [];
    }
    return lineage(wf);
}


def issues_for(archive: Archive, c: Constraints) -> list[ValidationIssue] {
    best = best_entry(archive);
    if best is None {
        return [];
    }
    wf = version_of(best);
    if wf is None {
        return [];
    }
    return validate(wf, c);
}


walker:pub TrainingStatus {
    """Rounds run, changes accepted, budget consumed, and why training stopped."""
    has reports: list[TrainingRun] = [];

    can collect with Root entry {
        for r in [-->[?:TrainingRun]] {
            report r;
        }
    }
}


walker:pub AcceptedChanges {
    """The explainable diff: every accepted change with its train and validation deltas."""
    has reports: list[ChangeRecord] = [];

    can collect with Root entry {
        for a in [-->[?:Archive]] {
            for change in changes_for(a) {
                report change;
            }
        }
    }
}


walker:pub Frontier {
    """The Pareto-optimal operating points a user chooses between."""
    has reports: list[FrontierRow] = [];

    can collect with Root entry {
        for a in [-->[?:Archive]] {
            for row in frontier_rows(a) {
                report row;
            }
        }
    }
}


walker:pub ExplorationReport {
    """Mutation-family exploration history.

    Presented as a record of what was tried, NOT as a learned policy - at
    realistic pull counts these estimates have not converged.
    """
    has reports: list[ArmReport] = [];

    can collect with Root entry {
        for b in [-->[?:BanditState]] {
            for arm in report_arms(b) {
                report arm;
            }
        }
    }
}


walker:pub SafetyCheck {
    """Re-validate the optimized workflow against the approved search space.

    Section 19's redundancy, exposed: the caller can confirm independently that
    what training produced still sits inside the constraints they authorized.
    """
    has approved_tools: list[str] = [];
    has approved_models: list[str] = [];
    has reports: list[ValidationIssue] = [];

    can check with Root entry {
        limits = Constraints(
            approved_tools=self.approved_tools,
            approved_models=self.approved_models
        );
        for a in [-->[?:Archive]] {
            for issue in issues_for(a, limits) {
                report issue;
            }
        }
    }
}
