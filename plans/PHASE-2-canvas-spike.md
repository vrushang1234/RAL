# PHASE 2 — React Flow-in-Jac Spike (Hour 1, second half)

> Execute after `plans/PHASE-1-contracts.md`. This phase retires the single biggest UI risk: rendering React Flow from Jac client code. When done, tick the Gate, update `context.md`, open `plans/PHASE-3-client-shell.md`.

## Context capsule

**Project:** RAL — full-stack Jac web-app; visual multi-agent workflow builder with RL prompt optimization. `DESIGN.md` is the source of truth. Repo already scaffolded as `kind = "web-app"`.

**Decisions that bind this phase:**
- **D0** — The frontend is Jac client code (`.jac` + JSX). React Flow comes in as an npm package (`@xyflow/react`) declared in `jac.toml` and imported from Jac. If React Flow interop fails after ~30 minutes of honest effort, fall back to a minimal absolutely-positioned-div + SVG-lines canvas **still written in Jac client** — NEVER a separate React/TS app. The fallback must keep the same component contract (`nodes` list / `edges` list, same dict shapes) so Phase 3+ is unaffected.

**Universal rules:**
1. Guides for this phase: `jac guide jac-npm-packages`, `jac guide jac-cl-components`, `jac guide jac-cl-js-interop` (only if you hit browser-API friction).
2. `jac check .` after every file edit.
3. Verified syntax facts (from the guides — do not deviate):
   - npm imports: double-quoted package names, named imports only — `import from "@xyflow/react" { ReactFlow }`. CSS by string-path import: `import "@xyflow/react/dist/style.css";`.
   - Client component = `def:pub Name() -> JsxElement` with `has` fields as reactive state. Lambdas for event handlers.
   - `jac start --dev main.jac` for dev serve; launch long-running with `< /dev/null`; kill stale servers first (`pkill -f "jac start"`) or the Vite proxy points at a dead port and all RPC fails.
   - QA loop: `jac browse open localhost:8000` → `jac browse snapshot` → `jac browse screenshot` → `jac browse close`.

## Task 1 — Install React Flow

```bash
jac install --npm @xyflow/react
```

This patches `jac.toml` `[dependencies.npm]` and installs. Verify the entry appears in `jac.toml`.

## Task 2 — `client/CanvasSpike.jac` (complete file)

```jac
"""Spike: prove React Flow renders and mutates Jac client state."""

import "@xyflow/react/dist/style.css";
import from "@xyflow/react" { ReactFlow, Background, Controls, applyNodeChanges, applyEdgeChanges }

def:pub CanvasSpike() -> JsxElement {
    has nodes: list = [
        {"id": "a", "position": {"x": 100.0, "y": 100.0}, "data": {"label": "Trigger"}},
        {"id": "b", "position": {"x": 400.0, "y": 100.0}, "data": {"label": "Worker"}}
    ];
    has edges: list = [{"id": "e1", "source": "a", "target": "b"}];

    return <div style={{"width": "100vw", "height": "100vh"}}>
        <ReactFlow
            nodes={nodes}
            edges={edges}
            onNodesChange={lambda (changes: any) { nodes = applyNodeChanges(changes, nodes); }}
            onEdgesChange={lambda (changes: any) { edges = applyEdgeChanges(changes, edges); }}
            fitView
        >
            <Background />
            <Controls />
        </ReactFlow>
    </div>;
}
```

## Task 3 — Mount it

In `main.jac`'s `cl` block, temporarily render the spike (replace the guestbook `<ClientApp/>`):

```jac
cl {
    import from .client.CanvasSpike { CanvasSpike }

    def:pub app -> JsxElement {
        return <CanvasSpike/>;
    }
}
```

Leave the guestbook server imports in `main.jac` alone for now (they're removed in Phase 4 when real endpoints replace them) — removing them now would orphan `frontend.cl.jac`'s `sv import` and break the check.
If `jac check` complains about the now-unmounted `frontend.cl.jac`, delete `frontend.cl.jac`, `frontend.impl.jac`, and `components/MessageCard.jac` in this phase instead of waiting.

## Task 4 — Verify in a real browser

```bash
pkill -f "jac start" ; jac start --dev main.jac < /dev/null &
jac browse open localhost:8000
jac browse snapshot        # expect two nodes in the a11y tree
jac browse screenshot      # visual: two blocks + one edge + controls
jac browse close
```

Then interactively: drag node "a", confirm no console errors (`JAC_DEBUG=1` env var for raw Vite output if the build fails; compiled JS lives in `.jac/client/compiled/` for inspection).

## Fallback (ONLY if React Flow is broken after ~30 min)

Replace the ReactFlow subtree in `CanvasSpike.jac` with:
- a relatively-positioned container div,
- one absolutely-positioned div per node (`left/top` from `position`, `onMouseDown`/`Move`/`Up` drag handlers storing drag state in `has` fields),
- an absolutely-positioned full-size `<svg>` under the nodes with one `<line>` per edge (coordinates = node positions + half node size).

Keep `nodes`/`edges` shapes IDENTICAL to the React Flow dicts. Record the fallback in `context.md` under Architectural Decisions.

## Common failure modes (check before declaring the fallback)

| Symptom | Likely cause / fix |
|---|---|
| `JAC_CLIENT_001` missing npm dep | `jac install` didn't run after the toml patch — run `jac install` |
| `JAC_CLIENT_004` unresolved import | Package-name typo; must be exactly `"@xyflow/react"` in double quotes |
| Blank canvas, no errors | Missing CSS import, or container has zero height — both handled in the file above |
| All RPC/pages 404 after restart | Stale `jac start` holding the port — `pkill -f "jac start"` and restart |

## Gate — all must pass before Phase 3

- [ ] `jac check .` green
- [ ] `jac browse snapshot` shows both nodes; screenshot shows nodes + edge + controls
- [ ] Dragging a node updates it live (React Flow path) — or fallback canvas does the same
- [ ] `context.md` updated (note which canvas path won)
