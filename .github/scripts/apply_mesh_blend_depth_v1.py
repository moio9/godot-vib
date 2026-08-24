from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file_path = Path(path)
    text = file_path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}: {old!r}")
    file_path.write_text(text.replace(old, new, 1), encoding="utf-8")


# Correct the active lane predicates used while building the smaller shared
# linear-depth mip levels for SSAO and SSIL.
depth_shader = "servers/rendering/renderer_rd/shaders/effects/ss_effects_downsample.glsl"
replace_once(
    depth_shader,
    "still_alive = p_gtid.x % 8 == depth_array_offset.x && depth_array_offset.y % 8 == depth_array_offset.y;",
    "still_alive = p_gtid.x % 8 == depth_array_offset.x && p_gtid.y % 8 == depth_array_offset.y;",
)
replace_once(
    depth_shader,
    "still_alive = p_gtid.x % 16 == depth_array_offset.x && depth_array_offset.y % 16 == depth_array_offset.y;",
    "still_alive = p_gtid.x % 16 == depth_array_offset.x && p_gtid.y % 16 == depth_array_offset.y;",
)

# Mesh Blend only reads depth. Bind the resolved scene depth as a sampled
# texture instead of copying it into an R32F storage image every frame.
mask_shader = "servers/rendering/renderer_rd/shaders/effects/mesh_blend_mask.glsl"
replace_once(
    mask_shader,
    "layout(r32f, set = 0, binding = 4) uniform readonly image2D mesh_depth;",
    "layout(set = 0, binding = 4) uniform sampler2D mesh_depth;",
)
replace_once(
    mask_shader,
    "float depth_value = imageLoad(mesh_depth, sample_pixel).x;",
    "float depth_value = texelFetch(mesh_depth, sample_pixel, 0).x;",
)

mesh_cpp = "servers/rendering/renderer_rd/effects/mesh_blend.cpp"
replace_once(
    mesh_cpp,
    "\tif (p_vb_depth.is_null()) {\n\t\treturn;\n\t}\n\n\tUniformSetCacheRD *uniform_cache = UniformSetCacheRD::get_singleton();\n\tERR_FAIL_NULL(uniform_cache);\n\n\tRD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();",
    "\tif (p_vb_depth.is_null()) {\n\t\treturn;\n\t}\n\n\tUniformSetCacheRD *uniform_cache = UniformSetCacheRD::get_singleton();\n\tERR_FAIL_NULL(uniform_cache);\n\tMaterialStorage *material_storage = MaterialStorage::get_singleton();\n\tERR_FAIL_NULL(material_storage);\n\n\tRID sampler_nearest = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);\n\n\tRD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();",
)
replace_once(
    mesh_cpp,
    "\tRD::Uniform u_depth(RD::UNIFORM_TYPE_IMAGE, 4, Vector<RID>({ p_vb_depth }));",
    "\tRD::Uniform u_depth(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, Vector<RID>({ sampler_nearest, p_vb_depth }));",
)

# Keep the private D32 depth attachment for the late visibility raster pass,
# but stop allocating the sampled R32F VB_DEPTH copy.
buffers_cpp = "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.cpp"
replace_once(
    buffers_cpp,
    "\tif (p_create_depth && !has_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_DEPTH)) {\n\t\tconst RenderingDevice::DataFormat fmt = RenderingDevice::DATA_FORMAT_R32_SFLOAT;\n\t\tconst uint32_t usage = RenderingDevice::TEXTURE_USAGE_STORAGE_BIT | RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT;\n\t\tcreate_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_DEPTH, fmt, usage, RenderingDevice::TEXTURE_SAMPLES_1, internal_size);\n\t}\n\n",
    "",
)
replace_once(
    buffers_cpp,
    "\treturn has_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_VIS) && (p_create_depth ? has_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_DEPTH) : true);",
    "\treturn has_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_VIS) && (!p_with_aux || has_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_AUX));",
)

scene_cpp = "servers/rendering/renderer_rd/renderer_scene_render_rd.cpp"
replace_once(
    scene_cpp,
    "\tbool need_aux = _mesh_blend_enabled();\n\t// Mesh blend requires storage-capable depth; always use VB depth.\n\trb->ensure_visibility_textures(need_aux, true);",
    "\tbool need_aux = _mesh_blend_enabled();\n\t// Keep the VB raster depth attachment, but sample the resolved main scene\n\t// depth directly in the Mesh Blend compute pass.\n\trb->ensure_visibility_textures(need_aux, true);",
)
replace_once(
    scene_cpp,
    "\t\tRID vb_depth_slice = rb->get_texture_slice(RB_SCOPE_BUFFERS, RB_TEX_VB_DEPTH, v, 0);",
    "\t\tRID scene_depth = rb->get_depth_texture(v);",
)
replace_once(
    scene_cpp,
    "\t\tif (vb_vis_slice.is_null() || vb_aux_slice.is_null() || vb_depth_slice.is_null() ||\n\t\t\t\tmask_slice.is_null() || edge_ping.is_null() || edge_pong.is_null() || color_source.is_null()) {\n\t\t\tif (v == 0) {\n\t\t\t\tWARN_PRINT_ONCE(vformat(\"Mesh blend: null textures for view %d: vis=%d aux=%d depth=%d mask=%d edge=%d color=%d\",\n\t\t\t\t\t\tv, vb_vis_slice.is_valid(), vb_aux_slice.is_valid(), vb_depth_slice.is_valid(),\n\t\t\t\t\t\tmask_slice.is_valid(), edge_ping.is_valid(), color_source.is_valid()));\n\t\t\t}\n\t\t\tcontinue;\n\t\t}\n\t\tmesh_blend->generate_mask(vb_vis_slice, vb_aux_slice, vb_depth_slice, mask_slice, edge_ping, size, depth_tolerance, neighbor_blend);",
    "\t\tif (vb_vis_slice.is_null() || vb_aux_slice.is_null() || scene_depth.is_null() ||\n\t\t\t\tmask_slice.is_null() || edge_ping.is_null() || edge_pong.is_null() || color_source.is_null()) {\n\t\t\tif (v == 0) {\n\t\t\t\tWARN_PRINT_ONCE(vformat(\"Mesh blend: null textures for view %d: vis=%d aux=%d depth=%d mask=%d edge=%d color=%d\",\n\t\t\t\t\t\tv, vb_vis_slice.is_valid(), vb_aux_slice.is_valid(), scene_depth.is_valid(),\n\t\t\t\t\t\tmask_slice.is_valid(), edge_ping.is_valid(), color_source.is_valid()));\n\t\t\t}\n\t\t\tcontinue;\n\t\t}\n\t\tmesh_blend->generate_mask(vb_vis_slice, vb_aux_slice, scene_depth, mask_slice, edge_ping, size, depth_tolerance, neighbor_blend);",
)

forward_cpp = "servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp"
replace_once(
    forward_cpp,
    "\tif (RendererSceneRenderRD::get_singleton()->is_mesh_blend_enabled()) {\n\t\tuse_main_depth_for_vb = false; // Mesh blend needs STORAGE usage on depth, main depth lacks it.\n\t}",
    "\tif (RendererSceneRenderRD::get_singleton()->is_mesh_blend_enabled()) {\n\t\t// This late pass clears its private depth attachment. Mesh Blend samples\n\t\t// the resolved main depth separately, so no storage depth copy is needed.\n\t\tuse_main_depth_for_vb = false;\n\t}",
)
replace_once(
    forward_cpp,
    "\n\t// When VB depth is a separate texture, copy depth from the main depth after the pass.\n\tif (!use_main_depth_for_vb) {\n\t\tRendererSceneRenderRD *rsrr = RendererSceneRenderRD::get_singleton();\n\t\trsrr->copy_depth_to_vb_depth(rb, p_render_data);\n\t}\n",
    "\n\t// Mesh Blend samples rb->get_depth_texture() directly; no full-screen\n\t// main-depth-to-VB-depth copy is required here.\n",
)

# Termux should compile renderer pull requests before they are merged.
termux = Path(".github/workflows/termux_build.yml")
termux_text = termux.read_text(encoding="utf-8")
if "  pull_request:\n    branches:\n      - \"4.7\"" not in termux_text:
    needle = "on:\n  workflow_dispatch:\n  push:\n"
    replacement = (
        "on:\n"
        "  workflow_dispatch:\n"
        "  pull_request:\n"
        "    branches:\n"
        "      - \"4.7\"\n"
        "    paths:\n"
        "      - \"core/**\"\n"
        "      - \"drivers/**\"\n"
        "      - \"editor/**\"\n"
        "      - \"main/**\"\n"
        "      - \"modules/**\"\n"
        "      - \"platform/**\"\n"
        "      - \"scene/**\"\n"
        "      - \"servers/**\"\n"
        "      - \"thirdparty/**\"\n"
        "      - \"SConstruct\"\n"
        "      - \"version.py\"\n"
        "      - \".github/workflows/termux_build.yml\"\n"
        "  push:\n"
    )
    if termux_text.count(needle) != 1:
        raise RuntimeError("Unable to add Termux pull_request trigger")
    termux.write_text(termux_text.replace(needle, replacement, 1), encoding="utf-8")

# Both automation helpers are one-shot files.
Path(".github/workflows/apply_mesh_blend_depth_v1.yml").unlink(missing_ok=True)
Path(".github/scripts/apply_mesh_blend_depth_v1.py").unlink(missing_ok=True)
