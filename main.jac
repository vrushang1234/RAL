"""RAL - Entry Point: run/train + workflow library + optimizer reports + AppShell."""

import from endpoints {
    run_single,
    train_step,
    eval_cell,
    log_eval_report,
    list_workflows,
    get_workflow,
    save_workflow,
    delete_workflow,
    validate_workflow
}
import from api { TrainingStatus, AcceptedChanges, Frontier, ExplorationReport, SafetyCheck }

cl {
    import from .client.AppShell { AppShell }

    def:pub app -> JsxElement {
        return <AppShell />;
    }
}
