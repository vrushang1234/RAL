"""One-shot client compile (avoids microservice jac-build subprocess crash)."""

with entry {
    import from pathlib { Path }
    import from jaclang.runtimelib.client.targets.web_target { WebTarget }

    out = WebTarget().build(Path("main.jac"), Path("."));
    print(f"client dist: {out}");
}
