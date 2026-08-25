#!/usr/bin/env python3

from __future__ import annotations

import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, description: str) -> str:
    if old in text:
        return text.replace(old, new, 1)
    if new in text:
        return text
    raise RuntimeError(f"Could not apply repair: {description}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: repair_renderer_scene.py <godot-source-root>")

    root = Path(sys.argv[1]).resolve()
    source_path = root / "servers/rendering/renderer_rd/renderer_scene_render_rd.cpp"
    if not source_path.is_file():
        raise RuntimeError(f"Godot source file not found: {source_path}")

    text = source_path.read_text(encoding="utf-8")

    copy_start = text.find("void RendererSceneRenderRD::copy_depth_to_vb_depth(")
    copy_end = text.find("void RendererSceneRenderRD::_ensure_mesh_blend_textures", copy_start)
    if copy_start < 0 or copy_end < 0:
        raise RuntimeError("Could not locate copy_depth_to_vb_depth")

    copy_function = text[copy_start:copy_end]
    copy_function = replace_once(
        copy_function,
        "\tERR_FAIL_NULL(rb);",
        "\tERR_FAIL_COND(rb.is_null());",
        "RenderSceneBuffersRD Ref null guard",
    )
    text = text[:copy_start] + copy_function + text[copy_end:]

    blend_start = text.find("void RendererSceneRenderRD::_process_mesh_blend(const RenderDataRD *p_render_data)")
    blend_end = text.find("// ", blend_start)
    while blend_end >= 0 and "VISIBILITY FILL" not in text[blend_end : blend_end + 160]:
        blend_end = text.find("// ", blend_end + 3)
    if blend_start < 0 or blend_end < 0:
        raise RuntimeError("Could not locate _process_mesh_blend")

    blend_function = text[blend_start:blend_end]
    blend_function = replace_once(
        blend_function,
        """\t\tif (vb_vis_slice.is_null() || vb_aux_slice.is_null() || vb_depth_slice.is_null() ||
\t\t\t\tmask_slice.is_null() || edge_ping.is_null() || edge_pong.is_null() || color_source.is_null()) {""",
        """\t\tif (vb_vis_slice.is_null() || vb_aux_slice.is_null() || vb_depth_slice.is_null() ||
\t\t\t\tedge_ping.is_null() || edge_pong.is_null() || color_source.is_null()) {""",
        "obsolete mask_slice null check",
    )
    blend_function = replace_once(
        blend_function,
        """\t\t\t\tWARN_PRINT_ONCE(vformat(\"Mesh blend: null textures for view %d: vis=%d aux=%d depth=%d mask=%d edge=%d color=%d\",
\t\t\t\t\t\tv, vb_vis_slice.is_valid(), vb_aux_slice.is_valid(), vb_depth_slice.is_valid(),
\t\t\t\t\t\tmask_slice.is_valid(), edge_ping.is_valid(), color_source.is_valid()));""",
        """\t\t\t\tWARN_PRINT_ONCE(vformat(\"Mesh blend: null textures for view %d: vis=%d aux=%d depth=%d edge=%d color=%d\",
\t\t\t\t\t\tv, vb_vis_slice.is_valid(), vb_aux_slice.is_valid(), vb_depth_slice.is_valid(),
\t\t\t\t\t\tedge_ping.is_valid(), color_source.is_valid()));""",
        "obsolete mask_slice warning argument",
    )
    blend_function = replace_once(
        blend_function,
        "\n\tint spread = 1;\n\twhile (spread < int(edge_radius_pixels)) {",
        "\n\t\tint spread = 1;\n\t\twhile (spread < int(edge_radius_pixels)) {",
        "Jump Flood spread indentation",
    )
    blend_function = replace_once(
        blend_function,
        "mesh_blend->jump_flood(current_edge, next_edge, tex_aux, size, spread);",
        "mesh_blend->jump_flood(current_edge, next_edge, vb_aux_slice, size, spread);",
        "Jump Flood packed VB_AUX input",
    )
    blend_function = replace_once(
        blend_function,
        "mesh_blend->blend(color_source, blend_depth, tex_aux, current_edge, framebuffer, size, effective_radius, view_slot, use_world_radius, neighbor_blend);",
        "mesh_blend->blend(color_source, blend_depth, vb_aux_slice, current_edge, framebuffer, size, effective_radius, view_slot, use_world_radius, neighbor_blend);",
        "final Mesh Blend packed VB_AUX input",
    )

    if "mask_slice" in blend_function or "tex_aux" in blend_function:
        raise RuntimeError("Stale Mesh Blend mask aliases remain in _process_mesh_blend")
    if "jump_flood(current_edge, next_edge, vb_aux_slice" not in blend_function:
        raise RuntimeError("Jump Flood is not using packed VB_AUX")
    if "blend(color_source, blend_depth, vb_aux_slice" not in blend_function:
        raise RuntimeError("Final Mesh Blend pass is not using packed VB_AUX")

    text = text[:blend_start] + blend_function + text[blend_end:]
    source_path.write_text(text, encoding="utf-8")

    temporary_hook = root / "site_scons/site_init.py"
    if temporary_hook.exists():
        temporary_hook.unlink()

    print(f"Repaired {source_path.relative_to(root)}")
    print("Removed temporary SCons hook" if not temporary_hook.exists() else "Temporary hook still exists")


if __name__ == "__main__":
    main()
