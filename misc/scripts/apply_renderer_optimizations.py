#!/usr/bin/env python3
"""Apply the first safe renderer optimization tranche.

The script is intentionally idempotent and fails when upstream code no longer
matches the expected anchors. This avoids silently corrupting large generated
renderer sources from an automated workflow.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def replace_once(relative_path: str, old: str, new: str, description: str) -> bool:
    path = ROOT / relative_path
    text = path.read_text(encoding="utf-8")

    if old not in text:
        if new in text:
            print(f"[already] {description}")
            return False
        raise RuntimeError(
            f"Could not find expected source while applying: {description}\n"
            f"File: {relative_path}"
        )

    occurrences = text.count(old)
    if occurrences != 1:
        raise RuntimeError(
            f"Expected one occurrence for {description}, found {occurrences}.\n"
            f"File: {relative_path}"
        )

    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"[patched] {description}")
    return True


def remove_optional_block(relative_path: str, candidates: tuple[str, ...], description: str) -> bool:
    path = ROOT / relative_path
    text = path.read_text(encoding="utf-8")

    for block in candidates:
        if block in text:
            path.write_text(text.replace(block, "", 1), encoding="utf-8")
            print(f"[patched] {description}")
            return True

    print(f"[already] {description}")
    return False


def main() -> None:
    changed = False

    # The upstream shader accidentally tests depth_array_offset.y against itself,
    # leaving four times too many lanes active for the last mip reductions.
    changed |= replace_once(
        "servers/rendering/renderer_rd/shaders/effects/ss_effects_downsample.glsl",
        "\tstill_alive = p_gtid.x % 8 == depth_array_offset.x && depth_array_offset.y % 8 == depth_array_offset.y;",
        "\tstill_alive = p_gtid.x % 8 == depth_array_offset.x && p_gtid.y % 8 == depth_array_offset.y;",
        "fix 8x8 depth mip lane selection",
    )
    changed |= replace_once(
        "servers/rendering/renderer_rd/shaders/effects/ss_effects_downsample.glsl",
        "\tstill_alive = p_gtid.x % 16 == depth_array_offset.x && depth_array_offset.y % 16 == depth_array_offset.y;",
        "\tstill_alive = p_gtid.x % 16 == depth_array_offset.x && p_gtid.y % 16 == depth_array_offset.y;",
        "fix 16x16 depth mip lane selection",
    )

    scene_shader_cpp = "servers/rendering/renderer_rd/forward_clustered/scene_shader_forward_clustered.cpp"
    changed |= replace_once(
        scene_shader_cpp,
        "\t\tactions.usage_defines[\"ALPHA_TEXTURE_COORDINATE\"] = \"@ALPHA_ANTIALIASING_EDGE\";\n\t\tactions.usage_defines[\"PREMUL_ALPHA_FACTOR\"] = \"#define PREMUL_ALPHA_USED\\n\";",
        "\t\tactions.usage_defines[\"ALPHA_TEXTURE_COORDINATE\"] = \"@ALPHA_ANTIALIASING_EDGE\";\n\t\tactions.usage_defines[\"MESH_BLEND\"] = \"#define MESH_BLEND_USED\\n\";\n\t\tactions.usage_defines[\"DISCARD\"] = \"#define DISCARD_USED\\n\";\n\t\tactions.usage_defines[\"PREMUL_ALPHA_FACTOR\"] = \"#define PREMUL_ALPHA_USED\\n\";",
        "emit visibility-pass defines for per-pixel Mesh Blend and discard",
    )

    scene_shader = "servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered.glsl"
    old_visibility_early_exit = """#ifdef MODE_RENDER_VISIBILITY
\tuvec2 packed_ids = uvec2(uint(gl_PrimitiveID) + 1u, instance_index + 1u);
\tvisibility_id_output = uvec4(packed_ids, 0u, 0u);

#ifndef MODE_RENDER_VISIBILITY_NO_AUX
\tfloat material_mesh_blend = clamp(sc_get_material_mesh_blend(), -1.0, 1.0);
\tfloat blend_id = sc_instance_hash(packed_ids.y);
\tvec2 aux = vec2(material_mesh_blend, blend_id);
\tvisibility_aux_output = vec4(aux, 0.0, 0.0);
#endif
\treturn;
#endif

"""
    fast_visibility_path = """#if defined(MODE_RENDER_VISIBILITY) && !defined(MESH_BLEND_USED) && !defined(DISCARD_USED) && !defined(ALPHA_SCISSOR_USED) && !defined(ALPHA_HASH_USED) && !defined(ALPHA_ANTIALIASING_EDGE_USED)
\t// Most materials do not need their fragment function during the VB pass.
\t// Keep the original fast path and only execute fragment() for per-pixel
\t// Mesh Blend or alpha/discard-dependent materials.
\tuvec2 packed_ids = uvec2(uint(gl_PrimitiveID) + 1u, instance_index + 1u);
\tvisibility_id_output = uvec4(packed_ids, 0u, 0u);

#ifndef MODE_RENDER_VISIBILITY_NO_AUX
\tfloat material_mesh_blend = clamp(sc_get_material_mesh_blend(), -1.0, 1.0);
\tfloat blend_id = sc_instance_hash(packed_ids.y);
\tvec2 aux = vec2(material_mesh_blend, blend_id);
\tvisibility_aux_output = vec4(aux, 0.0, 0.0);
#endif
\treturn;
#endif

"""
    changed |= replace_once(
        scene_shader,
        old_visibility_early_exit,
        fast_visibility_path,
        "retain a fast VB path for materials without per-pixel work",
    )
    changed |= replace_once(
        scene_shader,
        "\tfloat mesh_blend_value = 0.0;",
        "\tfloat mesh_blend_value = sc_get_material_mesh_blend();",
        "use the legacy mesh_blend uniform as the per-pixel default",
    )

    visibility_output = """#ifdef MODE_RENDER_VISIBILITY
\t// The material fragment has now evaluated textures, procedural masks,
\t// alpha cutouts and discard. Store its final per-pixel Mesh Blend value.
\tuvec2 packed_ids = uvec2(uint(gl_PrimitiveID) + 1u, instance_index + 1u);
\tvisibility_id_output = uvec4(packed_ids, 0u, 0u);

#ifndef MODE_RENDER_VISIBILITY_NO_AUX
\tfloat material_mesh_blend = clamp(mesh_blend_value, -1.0, 1.0);
\tfloat blend_id = sc_instance_hash(packed_ids.y);
\tvec2 aux = vec2(material_mesh_blend, blend_id);
\tvisibility_aux_output = vec4(aux, 0.0, 0.0);
#endif
\treturn;
#endif

"""
    changed |= replace_once(
        scene_shader,
        "#endif // !USE_SHADOW_TO_OPACITY\n\n#if defined(NORMAL_MAP_USED)",
        "#endif // !USE_SHADOW_TO_OPACITY\n\n" + visibility_output + "#if defined(NORMAL_MAP_USED)",
        "write visibility metadata after fragment alpha/discard evaluation",
    )

    # Mesh Blend only samples depth. Bind it as a sampled texture instead of a
    # storage image so the regular main depth can be reused when MSAA is off.
    changed |= replace_once(
        "servers/rendering/renderer_rd/shaders/effects/mesh_blend_mask.glsl",
        "layout(r32f, set = 0, binding = 4) uniform readonly image2D mesh_depth;",
        "layout(set = 0, binding = 4) uniform sampler2D mesh_depth;",
        "sample Mesh Blend depth through a regular texture",
    )
    changed |= replace_once(
        "servers/rendering/renderer_rd/shaders/effects/mesh_blend_mask.glsl",
        "\tfloat depth_value = imageLoad(mesh_depth, sample_pixel).x;",
        "\tfloat depth_value = texelFetch(mesh_depth, sample_pixel, 0).x;",
        "replace Mesh Blend depth imageLoad with texelFetch",
    )

    mesh_blend_cpp = "servers/rendering/renderer_rd/effects/mesh_blend.cpp"
    changed |= replace_once(
        mesh_blend_cpp,
        "\tif (p_vb_depth.is_null()) {\n\t\treturn;\n\t}\n\n\tUniformSetCacheRD *uniform_cache = UniformSetCacheRD::get_singleton();\n\tERR_FAIL_NULL(uniform_cache);\n\n\tRD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();",
        "\tif (p_vb_depth.is_null()) {\n\t\treturn;\n\t}\n\n\tUniformSetCacheRD *uniform_cache = UniformSetCacheRD::get_singleton();\n\tERR_FAIL_NULL(uniform_cache);\n\tMaterialStorage *material_storage = MaterialStorage::get_singleton();\n\tERR_FAIL_NULL(material_storage);\n\n\tRID sampler_nearest = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);\n\n\tRD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();",
        "create a nearest sampler for Mesh Blend depth",
    )
    changed |= replace_once(
        mesh_blend_cpp,
        "\tRD::Uniform u_depth(RD::UNIFORM_TYPE_IMAGE, 4, Vector<RID>({ p_vb_depth }));",
        "\tRD::Uniform u_depth(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, Vector<RID>({ sampler_nearest, p_vb_depth }));",
        "bind Mesh Blend depth as sampler-with-texture",
    )

    force_blocks_forward = (
        "\tif (RendererSceneRenderRD::get_singleton()->is_mesh_blend_enabled()) {\n\t\tuse_main_depth_for_vb = false; // Mesh blend needs STORAGE usage on depth, main depth lacks it.\n\t}\n",
        "\tif (RendererSceneRenderRD::get_singleton()->is_mesh_blend_enabled()) {\n\t\tuse_main_depth_for_vb = false; // mesh blend needs STORAGE usage on depth, main depth lacks it.\n\t}\n",
    )
    changed |= remove_optional_block(
        "servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp",
        force_blocks_forward,
        "reuse main depth for Mesh Blend without MSAA",
    )

    force_blocks_base = (
        "\t\tif (_mesh_blend_enabled()) {\n\t\t\tuse_main_depth_for_vb = false; // mesh blend needs storage-capable depth\n\t\t}\n",
        "\t\tif (_mesh_blend_enabled()) {\n\t\t\tuse_main_depth_for_vb = false; // Mesh blend needs storage-capable depth.\n\t\t}\n",
    )
    changed |= remove_optional_block(
        "servers/rendering/renderer_rd/renderer_scene_render_rd.cpp",
        force_blocks_base,
        "allow lazily allocated VB textures to reuse main depth",
    )

    # Compile the optimization branch with the same Termux package job before
    # it is merged into 4.7.
    changed |= replace_once(
        ".github/workflows/termux_build.yml",
        '      - "sync/4.7.2"\n',
        '      - "sync/4.7.2"\n      - "work/renderer-optimizations"\n',
        "enable Termux CI on the renderer optimization branch",
    )

    print("Renderer optimization patch complete." if changed else "No changes were necessary.")


if __name__ == "__main__":
    main()
