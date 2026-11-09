"""CORE-AC-10: a module may import another module only through that module's package root (plan §3.1).

import-linter (`lint-imports` in CI) enforces *which* modules may depend on which; it cannot express "package root
only", so this test walks the real import graph with grimp.
"""

from __future__ import annotations

import grimp

MODULES_PKG = "app.modules"


def _module_of(name: str) -> str | None:
    parts = name.split(".")
    if name.startswith(MODULES_PKG + ".") and len(parts) >= 3:
        return parts[2]
    return None


def test_boundaries_root_only() -> None:
    graph = grimp.build_graph("app")
    violations: list[str] = []
    for importer in sorted(graph.modules):
        owner = _module_of(importer)
        if owner is None:  # app.main (composition root) and app/__init__ are exempt
            continue
        for imported in graph.find_modules_directly_imported_by(importer):
            target = _module_of(imported)
            if target is None or target == owner:
                continue
            if imported != f"{MODULES_PKG}.{target}":
                violations.append(f"{importer} -> {imported}")
    assert not violations, "cross-module imports must target the package root:\n" + "\n".join(violations)
