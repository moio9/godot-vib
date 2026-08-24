from pathlib import Path
import re


def replace_exact(path: str, old: str, new: str, expected: int = 1) -> None:
    file_path = Path(path)
    text = file_path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != expected:
        raise RuntimeError(f"{path}: expected {expected} occurrence(s), found {count}: {old!r}")
    file_path.write_text(text.replace(old, new), encoding="utf-8")


# Fix the Y predicates used while producing deeper linear-depth mips. The old
# expressions compared depth_array_offset.y with itself, leaving redundant
# invocations alive and causing duplicate stores.
replace_exact(
    "servers/rendering/renderer_rd/shaders/effects/ss_effects_downsample.glsl",
    "still_alive = p_gtid.x % 8 == depth_array_offset.x && depth_array_offset.y % 8 == depth_array_offset.y;",
    "still_alive = p_gtid.x % 8 == depth_array_offset.x && p_gtid.y % 8 == depth_array_offset.y;",
)
replace_exact(
    "servers/rendering/renderer_rd/shaders/effects/ss_effects_downsample.glsl",
    "still_alive = p_gtid.x % 16 == depth_array_offset.x && depth_array_offset.y % 16 == depth_array_offset.y;",
    "still_alive = p_gtid.x % 16 == depth_array_offset.x && p_gtid.y % 16 == depth_array_offset.y;",
)

# Mesh Blend only reads depth. Sample it as a texture instead of requiring a
# storage image, which permits direct reuse of the main depth without MSAA.
replace_exact(
    "servers/rendering/renderer_rd/shaders/effects/mesh_blend_mask.glsl",
    "layout(r32f, set = 0, binding = 4) uniform readonly image2D mesh_depth;",
    "layout(set = 0, binding = 4) uniform sampler2D mesh_depth;",
)
replace_exact(
    "servers/rendering/renderer_rd/shaders/effects/mesh_blend_mask.glsl",
    "float depth_value = imageLoad(mesh_depth, sample_pixel).x;",
    "float depth_value = texelFetch(mesh_depth, sample_pixel, 0).x;",
)

mesh_cpp = Path("servers/rendering/renderer_rd/effects/mesh_blend.cpp")
text = mesh_cpp.read_text(encoding="utf-8")
old = """\tUniformSetCacheRD *uniform_cache = UniformSetCacheRD::get_singleton();
\tERR_FAIL_NULL(uniform_cache);

\tRD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();"""
new = """\tUniformSetCacheRD *uniform_cache = UniformSetCacheRD::get_singleton();
\tERR_FAIL_NULL(uniform_cache);
\tMaterialStorage *material_storage = MaterialStorage::get_singleton();
\tERR_FAIL_NULL(material_storage);

\tRID sampler_nearest = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

\tRD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();"""
start = text.index("void MeshBlend::generate_mask(")
end = text.index("void MeshBlend::jump_flood(", start)
body = text[start:end]
if body.count(old) != 1:
    raise RuntimeError(f"mesh_blend.cpp generate_mask prologue mismatch: {body.count(old)}")
body = body.replace(old, new)
old_depth = "\tRD::Uniform u_depth(RD::UNIFORM_TYPE_IMAGE, 4, Vector<RID>({ p_vb_depth }));"
new_depth = "\tRD::Uniform u_depth(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, Vector<RID>({ sampler_nearest, p_vb_depth }));"
if body.count(old_depth) != 1:
    raise RuntimeError(f"mesh_blend.cpp depth binding mismatch: {body.count(old_depth)}")
body = body.replace(old_depth, new_depth)
mesh_cpp.write_text(text[:start] + body + text[end:], encoding="utf-8")

# Mesh Blend can reuse the main depth attachment when MSAA is disabled. The
# existing MSAA guard still selects the dedicated visibility depth attachment.
forward_cpp = Path("servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp")
text = forward_cpp.read_text(encoding="utf-8")
pattern = re.compile(
    r"\tbool use_main_depth_for_vb = RendererSceneRenderRD::get_singleton\(\)->is_visibility_buffer_reusing_main_depth\(\);\n"
    r"\tif \(RendererSceneRenderRD::get_singleton\(\)->is_mesh_blend_enabled\(\)\) \{\n"
    r"\t\tuse_main_depth_for_vb = false; // Mesh blend needs STORAGE usage on depth, main depth lacks it\.\n"
    r"\t\}\n"
)
replacement = (
    "\tbool use_main_depth_for_vb = RendererSceneRenderRD::get_singleton()->is_visibility_buffer_reusing_main_depth() || "
    "RendererSceneRenderRD::get_singleton()->is_mesh_blend_enabled();\n"
)
text, count = pattern.subn(replacement, text)
if count != 1:
    raise RuntimeError(f"render_forward_clustered.cpp depth reuse block mismatch: {count}")
forward_cpp.write_text(text, encoding="utf-8")

# Validate optimization branches and pull requests with the dedicated Termux
# package build instead of waiting until changes reach 4.7.
termux_workflow = Path(".github/workflows/termux_build.yml")
text = termux_workflow.read_text(encoding="utf-8")
old = """on:
  workflow_dispatch:
  push:
    branches:
      - \"4.7\"
"""
new = """on:
  workflow_dispatch:
  pull_request:
    branches:
      - \"4.7\"
  push:
    branches:
      - \"4.7\"
      - \"opt/**\"
"""
if text.count(old) != 1:
    raise RuntimeError(f"termux workflow trigger mismatch: {text.count(old)}")
termux_workflow.write_text(text.replace(old, new), encoding="utf-8")
