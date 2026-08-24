"""Remove temporary renderer repair artifacts from the optimization PR.

This file runs once when SCons starts in GitHub Actions. It deletes only files
that were added by this branch relative to ``4.7`` and match the temporary
repair/trigger patterns, commits the cleanup, pushes it, and removes itself.
"""

from __future__ import annotations

import fnmatch
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args: str, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args),
        cwd=ROOT,
        check=check,
        text=True,
        capture_output=capture,
    )


if os.environ.get("GITHUB_ACTIONS") == "true":
    run("git", "fetch", "origin", "4.7", "--depth=1")
    diff = run("git", "diff", "--name-status", "origin/4.7...HEAD", capture=True).stdout

    added: list[str] = []
    for line in diff.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0] == "A":
            added.append(parts[-1])

    keep = {
        ".github/workflows/renderer_batch2_compile.yml",
    }

    explicit = {
        ".github/workflows/renderer_batch2_compile_fixed.yml",
        ".github/workflows/renderer_batch2_compile_v2.yml",
        ".github/workflows/renderer_compile_repair_final.yml",
        ".github/workflows/repair_renderer_on_comment.yml",
        ".github/workflows/repair_renderer_batch2_allocator.yml",
        ".github/workflows/repair_renderer_batch2_target_final.yml",
        "site_scons/site_init.py",
    }

    def is_temporary(path: str) -> bool:
        if path in keep:
            return False
        if path in explicit:
            return True
        lower = path.lower()
        name = Path(path).name.lower()
        if lower.startswith(".github/build-status/") and "renderer" in lower:
            return True
        if lower.startswith(".github/workflows/") and "renderer" in lower and "repair" in lower:
            return True
        if "renderer" in name and "trigger" in name:
            return True
        if fnmatch.fnmatch(name, "trigger_renderer_repair*.txt"):
            return True
        if fnmatch.fnmatch(name, "trusted_repair_trigger*.txt"):
            return True
        return False

    to_delete = sorted(path for path in added if is_temporary(path))
    if "site_scons/site_init.py" not in to_delete:
        to_delete.append("site_scons/site_init.py")

    for relative in to_delete:
        path = ROOT / relative
        if path.exists():
            path.unlink()

    run("git", "config", "user.name", "github-actions[bot]")
    run("git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
    run("git", "add", "-A")
    run("git", "diff", "--cached", "--check")

    changed = run("git", "diff", "--cached", "--quiet", check=False)
    if changed.returncode != 0:
        run("git", "commit", "-m", "Remove temporary renderer repair automation")
        run("git", "push", "origin", "HEAD:opt/renderer-batch2")
