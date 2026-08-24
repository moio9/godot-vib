#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
V3_PATH = ROOT / ".github/workflows/renderer_batch2_apply_v3.yml"


def run(command: list[str], *, cwd: Path = ROOT) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def run_bash(script: str) -> None:
    subprocess.run(
        ["bash", "-c", "set -euo pipefail\n" + script],
        cwd=ROOT,
        check=True,
    )


def normalize_v3_nested_literal(text: str) -> str:
    start_marker = "          post_code = r'''\n"
    end_marker = "\n'''\n          text = text.replace(marker, marker + post_code, 1)"
    start = text.find(start_marker)
    if start < 0:
        raise RuntimeError("Nested post_code literal was not found in V3")
    end = text.find(end_marker, start)
    if end < 0:
        raise RuntimeError("Nested post_code literal terminator was not found in V3")

    replacement = (
        "          post_code = (\n"
        "              \"\\n#ifdef MODE_RENDER_VISIBILITY\\n\"\n"
        "              \"\\tfloat material_mesh_blend = clamp(sc_get_material_mesh_blend(), -1.0, 1.0);\\n\"\n"
        "              \"\\tfloat blend_id = sc_instance_hash(packed_ids.y);\\n\"\n"
        "              \"\\tfrag_visibility_aux = vec2(material_mesh_blend, blend_id);\\n\"\n"
        "              \"#ifdef MESH_BLEND_OUTPUT_USED\\n\"\n"
        "              \"\\tfrag_visibility_aux.x = clamp(mesh_blend_output, 0.0, 1.0);\\n\"\n"
        "              \"#endif\\n\"\n"
        "              \"#ifdef MESH_BLEND_GROUP_OUTPUT_USED\\n\"\n"
        "              \"\\tfrag_visibility_aux.y = float(min(mesh_blend_group_output, 255u)) / 255.0;\\n\"\n"
        "              \"#endif\\n\"\n"
        "              \"\\treturn;\\n\"\n"
        "              \"#endif\\n\"\n"
        "          )"
    )
    return text[:start] + replacement + text[end + 4 :]


def extract_step(workflow_text: str, name: str) -> str:
    lines = workflow_text.splitlines()
    start = next(
        (i for i, line in enumerate(lines) if line.strip() == f"- name: {name}"),
        None,
    )
    if start is None:
        raise RuntimeError(f"Step not found in V3 workflow: {name}")

    run_index = next(
        (i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |"),
        None,
    )
    if run_index is None:
        raise RuntimeError(f"Run block not found for V3 step: {name}")

    run_indent = len(lines[run_index]) - len(lines[run_index].lstrip())
    block: list[str] = []
    for line in lines[run_index + 1 :]:
        if line.strip():
            indent = len(line) - len(line.lstrip())
            if indent <= run_indent:
                break
        block.append(line)

    nonempty = [line for line in block if line.strip()]
    if not nonempty:
        raise RuntimeError(f"Empty run block for V3 step: {name}")
    prefix = min(len(line) - len(line.lstrip()) for line in nonempty)
    return "\n".join(line[prefix:] if line.strip() else "" for line in block) + "\n"


def extract_patch_program(source: str) -> str:
    match = re.search(
        r"python3 - <<'PY'\n(?P<body>.*?)\n[ \t]+PY(?:\n|$)",
        source,
        flags=re.DOTALL,
    )
    if match is None:
        raise RuntimeError("Python patch heredoc was not found")

    lines = match.group("body").splitlines()
    first = next((line for line in lines if line.strip()), "")
    if not first:
        raise RuntimeError("Python patch heredoc is empty")
    prefix = re.match(r"^[ \t]*", first).group(0)
    return "\n".join(
        line[len(prefix) :] if prefix and line.startswith(prefix) else line
        for line in lines
    ) + "\n"


def git_show(ref: str, path: str) -> str:
    return subprocess.check_output(
        ["git", "show", f"origin/{ref}:{path}"],
        cwd=ROOT,
        text=True,
    )


def apply_patch_workflow(branch: str, workflow: str, adapter: str = "none") -> None:
    print(f"\n===== {branch}:{workflow} =====", flush=True)
    body = extract_patch_program(git_show(branch, workflow))

    if adapter == "mask-call-flex":
        body = body.replace(
            r"\s*vb_vis\s*",
            r"\s*[A-Za-z_][A-Za-z0-9_]*\s*",
        )
    elif adapter == "compact-current":
        body = body.replace(
            r'r"void [A-Za-z0-9_:]+::ensure_visibility_textures',
            r'r"bool [A-Za-z0-9_:]+::ensure_visibility_textures',
        )
        body = body.replace(
            "void ensure_visibility_textures",
            "bool ensure_visibility_textures",
        )
        body = body.replace(
            "RD::DATA_FORMAT_R32G32_UINT",
            "RenderingDevice::DATA_FORMAT_R32G32_UINT",
        )
        body = body.replace(
            "RD::DATA_FORMAT_R8_UINT",
            "RenderingDevice::DATA_FORMAT_R8_UINT",
        )
    elif adapter != "none":
        raise RuntimeError(f"Unknown patch adapter: {adapter}")

    patch_path = Path("/tmp/renderer-source-patch.py")
    patch_path.write_text(body, encoding="utf-8")
    run(["python3", str(patch_path)])
    run(["git", "diff", "--check"])


def verify_bounded_jump_flood() -> None:
    path = ROOT / "servers/rendering/renderer_rd/renderer_scene_render_rd.cpp"
    text = path.read_text(encoding="utf-8")
    required = (
        "while (spread < int(edge_radius_pixels))",
        "while (spread >= 1)",
        "mesh_blend->jump_flood(current_edge, next_edge, mask_slice, size, spread)",
    )
    missing = [needle for needle in required if needle not in text]
    if missing:
        raise RuntimeError(
            "Current Mesh Blend jump flood is not radius-bounded; missing: "
            + ", ".join(missing)
        )
    if "MAX(size.x, size.y)" in text or "MAX(size.width, size.height)" in text:
        raise RuntimeError("A full-screen Mesh Blend jump-flood spread remains")
    print("Mesh Blend jump flood is already bounded by edge_radius_pixels.", flush=True)


def main() -> None:
    if not V3_PATH.exists():
        raise RuntimeError(f"Missing V3 workflow container: {V3_PATH}")

    workflow_text = normalize_v3_nested_literal(V3_PATH.read_text(encoding="utf-8"))

    for stage in (
        "Normalize current source names",
        "Apply validated shared-depth and edge-correctness patch",
        "Add functional per-pixel Mesh Blend shader API",
    ):
        print(f"\n===== {stage} =====", flush=True)
        run_bash(extract_step(workflow_text, stage))

    apply_patch_workflow(
        "opt/mesh-blend-mask-bandwidth",
        ".github/workflows/optimize_mesh_blend_mask_bandwidth.yml",
        "mask-call-flex",
    )
    apply_patch_workflow(
        "opt/mesh-blend-compact-visibility-attachment",
        ".github/workflows/optimize_mesh_blend_visibility_attachment.yml",
        "compact-current",
    )

    print("\n===== Verify bounded Mesh Blend jump flood =====", flush=True)
    verify_bounded_jump_flood()

    for branch, workflow in (
        (
            "opt/mesh-blend-rg16-edges",
            ".github/workflows/optimize_mesh_blend_edge_format.yml",
        ),
        (
            "opt/mesh-blend-packed-mask",
            ".github/workflows/optimize_mesh_blend_mask_format.yml",
        ),
        (
            "opt/mesh-blend-packed-vb-aux",
            ".github/workflows/optimize_mesh_blend_vb_aux.yml",
        ),
        (
            "opt/mesh-blend-reuse-vb-aux-mask",
            ".github/workflows/optimize_mesh_blend_mask_alias.yml",
        ),
        (
            "opt/mesh-blend-main-pass-metadata",
            ".github/workflows/optimize_mesh_blend_main_pass_metadata.yml",
        ),
    ):
        apply_patch_workflow(branch, workflow)

    for stage in (
        "Remove tracked generated files",
        "Verify optimized source invariants",
    ):
        print(f"\n===== {stage} =====", flush=True)
        run_bash(extract_step(workflow_text, stage))

    run(["git", "diff", "--check"])
    print("Renderer optimization source batch applied successfully.", flush=True)


if __name__ == "__main__":
    main()
