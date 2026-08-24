from pathlib import Path
import re


# Convert the auxiliary visibility attachment from two half floats (32 bpp) to
# one packed unsigned 16-bit value: low 8 bits group, high 8 bits signed weight.
creation_candidates = []
for path in Path("servers/rendering").rglob("*.cpp"):
    text = path.read_text(errors="ignore")
    if "RB_TEX_VB_AUX" in text and "DATA_FORMAT_R16G16_SFLOAT" in text:
        creation_candidates.append(path)
if len(creation_candidates) != 1:
    raise RuntimeError(f"Expected one VB_AUX texture creation file, found {creation_candidates}")
creation_path = creation_candidates[0]
text = creation_path.read_text(encoding="utf-8")
index = text.index("RB_TEX_VB_AUX")
start = max(0, index - 600)
end = min(len(text), index + 800)
window = text[start:end]
if window.count("RD::DATA_FORMAT_R16G16_SFLOAT") != 1:
    raise RuntimeError("VB_AUX format occurrence mismatch near texture creation")
window = window.replace("RD::DATA_FORMAT_R16G16_SFLOAT", "RD::DATA_FORMAT_R16_UINT")
creation_path.write_text(text[:start] + window + text[end:], encoding="utf-8")

scene_path = Path("servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered.glsl")
scene = scene_path.read_text(encoding="utf-8")
output_match = re.search(
    r"layout\s*\(\s*location\s*=\s*1\s*\)\s*out\s+vec2\s+([A-Za-z_]\w*)\s*;",
    scene,
)
if not output_match:
    raise RuntimeError("Could not locate vec2 visibility auxiliary output")
aux = output_match.group(1)
old_decl = output_match.group(0)
new_decl = old_decl.replace("out vec2", "out uint")
pack_function = """

uint pack_mesh_blend_data(float p_weight, uint p_group) {
\tuint encoded_weight = uint(round((clamp(p_weight, -1.0, 1.0) * 0.5 + 0.5) * 255.0));
\treturn (encoded_weight << 8) | min(p_group, 255u);
}"""
scene = scene[: output_match.start()] + new_decl + pack_function + scene[output_match.end() :]

block_pattern = re.compile(
    rf"#if defined\(MESH_BLEND_USED\) \|\| defined\(MESH_BLEND_GROUP_USED\)\n"
    rf"(?P<indent>\s*){re.escape(aux)} = (?P<builtin>vec2\([^;\n]+\));\n"
    rf"#else\n"
    rf"\s*{re.escape(aux)} = (?P<fallback>vec2\([^;\n]+\));\n"
    rf"#endif"
)
match = block_pattern.search(scene)
if not match:
    raise RuntimeError("Could not locate Mesh Blend builtin/fallback output block")
indent = match.group("indent")
builtin_rhs = match.group("builtin")
fallback_rhs = match.group("fallback")
replacement = f"""vec2 mesh_blend_values;
#if defined(MESH_BLEND_USED) || defined(MESH_BLEND_GROUP_USED)
{indent}mesh_blend_values = {builtin_rhs};
#else
{indent}mesh_blend_values = {fallback_rhs};
#endif
{indent}{aux} = pack_mesh_blend_data(mesh_blend_values.x, uint(round(clamp(mesh_blend_values.y, 0.0, 1.0) * 255.0)));"""
scene_path.write_text(scene[: match.start()] + replacement + scene[match.end() :], encoding="utf-8")

mask_path = Path("servers/rendering/renderer_rd/shaders/effects/mesh_blend_mask.glsl")
mask = mask_path.read_text(encoding="utf-8")
old_aux = "layout(rg16f, set = 0, binding = 1) uniform readonly image2D vb_aux;"
new_aux = "layout(r16ui, set = 0, binding = 1) uniform readonly uimage2D vb_aux;"
if mask.count(old_aux) != 1:
    raise RuntimeError(f"Mesh Blend aux declaration mismatch: {mask.count(old_aux)}")
mask = mask.replace(old_aux, new_aux)
old_read = """\tuvec4 ids = imageLoad(vb_vis, sample_pixel);
\tvec2 aux = imageLoad(vb_aux, sample_pixel).xy;
\tfloat depth_value = texelFetch(mesh_depth, sample_pixel, 0).x;

\tif (ids.x != 0u) {
\t\tfloat raw_weight = aux.x;
\t\tfloat weight = min(raw_weight, 1.0);
\t\tfloat id_quantized = floor(aux.y * 255.0 + 0.5) / 255.0;
\t\tvalue = vec2(id_quantized, weight);
\t}"""
new_read = """\tuint packed = imageLoad(vb_aux, sample_pixel).x;
\tfloat depth_value = texelFetch(mesh_depth, sample_pixel, 0).x;

\tif (packed != 0u) {
\t\tuint group_id = packed & 0xFFu;
\t\tuint encoded_weight = (packed >> 8) & 0xFFu;
\t\tfloat weight = (float(encoded_weight) / 255.0) * 2.0 - 1.0;
\t\tvalue = vec2(float(group_id) / 255.0, weight);
\t}"""
if mask.count(old_read) != 1:
    raise RuntimeError(f"Mesh Blend packed read block mismatch: {mask.count(old_read)}")
mask_path.write_text(mask.replace(old_read, new_read), encoding="utf-8")
