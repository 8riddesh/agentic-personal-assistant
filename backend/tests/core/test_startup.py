from __future__ import annotations

import subprocess
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[2]


def test_heavy_libs_not_imported_by_main() -> None:
    """CORE-AC-09: importing app.main must not pull in pandas / matplotlib / seaborn / sklearn (512 MB free tier)."""
    code = (
        "import app.main, sys\n"
        "heavy = {'pandas', 'numpy', 'matplotlib', 'seaborn', 'sklearn', 'jinja2'} & set(sys.modules)\n"
        "assert not heavy, heavy\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", code], cwd=BACKEND_DIR, capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stderr


def test_lazy_app_attribute_builds_the_app(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    import app.main as main
    from tests.helpers import make_settings

    monkeypatch.setattr(main, "_app", None)
    monkeypatch.setattr(main, "get_settings", lambda: make_settings())
    built = main.app
    assert built.title == "Daily Assistant"
    assert main.app is built  # cached


def test_unknown_module_attribute_raises() -> None:
    import pytest

    import app.main as main

    with pytest.raises(AttributeError):
        main.does_not_exist  # noqa: B018
