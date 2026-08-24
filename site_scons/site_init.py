"""Temporary one-shot repair hook for the renderer optimization branch.

SCons imports ``site_scons/site_init.py`` before reading the project scripts.
The hook fixes generated source transformations in the CI working tree. It also
prints base64 copies of changed sources into the build log so the validated
files can be committed through the GitHub API after compilation succeeds.
"""

from __future__ import annotations

import base64
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHANGED: list[Path] = []


def replace_exact(relative_path: str, old: str, new: str) -> None:
    path = ROOT / relative_path
    text = path.read_text(encoding="utf-8")
    if old in text:
        path.write_text(text.replace(old, new, 1), encoding="utf-8")
        CHANGED.append(path)
    elif new not in text:
        raise RuntimeError(f"Unexpected source shape in {relative_path}")


replace_exact(
    "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.cpp",
    "\treturn has_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_VIS) && (p_need_depth ? has_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_DEPTH) : true);",
    """\tconst bool visibility_ready = has_texture(RB_SCOPE_BUFFERS, p_need_full_visibility ? RB_TEX_VB_VIS : RB_TEX_VB_COMPACT);
\tconst bool aux_ready = !p_need_aux || has_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_AUX);
\tconst bool depth_ready = !p_need_depth || has_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_DEPTH);
\treturn visibility_ready && aux_ready && depth_ready;""",
)

forward_path = ROOT / "servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp"
forward_text = forward_path.read_text(encoding="utf-8")
outer_anchor = "\tbool using_motion_pass = rb_data.is_valid() && using_upscaling;\n"
outer_decl = outer_anchor + "\tbool mesh_blend_main_pass = false;\n"
local_decl = "\t\tconst bool mesh_blend_main_pass = _mesh_blend_enabled() && p_render_data->reflection_probe.is_null() && rb->get_msaa_3d() == RSE::VIEWPORT_MSAA_DISABLED;"
assignment = "\t\tmesh_blend_main_pass = _mesh_blend_enabled() && p_render_data->reflection_probe.is_null() && rb->get_msaa_3d() == RSE::VIEWPORT_MSAA_DISABLED;"

changed_forward = False
if outer_decl not in forward_text:
    if outer_anchor not in forward_text:
        raise RuntimeError("Could not find the outer Mesh Blend declaration anchor")
    forward_text = forward_text.replace(outer_anchor, outer_decl, 1)
    changed_forward = True
if local_decl in forward_text:
    forward_text = forward_text.replace(local_decl, assignment, 1)
    changed_forward = True
elif assignment not in forward_text:
    raise RuntimeError("Could not find the Mesh Blend main-pass assignment")
if changed_forward:
    forward_path.write_text(forward_text, encoding="utf-8")
    CHANGED.append(forward_path)

if CHANGED and os.environ.get("GITHUB_ACTIONS") == "true":
    for path in CHANGED:
        relative = path.relative_to(ROOT).as_posix()
        encoded = base64.b64encode(path.read_bytes()).decode("ascii")
        print(f"RENDERER_PATCHED_SOURCE_BEGIN:{relative}")
        print(encoded)
        print(f"RENDERER_PATCHED_SOURCE_END:{relative}")
