"""RAL - Entry Point: run/train + workflow library + AppShell."""

import from endpoints {
    run_single,
    train_step,
    list_workflows,
    get_workflow,
    save_workflow,
    delete_workflow,
    validate_workflow
}

cl {
    import from .client.AppShell { AppShell }

    def:pub app -> JsxElement {
        return <AppShell />;
    }
}
