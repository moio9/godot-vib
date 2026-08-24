from pathlib import Path
import re


# Register per-fragment shader outputs in the spatial shader language.
shader_types = Path("servers/rendering/shader_types.cpp")
text = shader_types.read_text(encoding="utf-8")
if 'built_ins["MESH_BLEND"]' in text:
    raise RuntimeError("MESH_BLEND builtin already exists")
lines = text.splitlines(keepends=True)
insert_at = None
prototype = None
for index, line in enumerate(lines):
    if 'functions["fragment"].built_ins["AO"]' in line and "TYPE_FLOAT" in line:
        insert_at = index + 1
        prototype = line
        break
if prototype is None:
    for index, line in enumerate(lines):
        if 'functions["fragment"].built_ins["ROUGHNESS"]' in line and "TYPE_FLOAT" in line:
            insert_at = index + 1
            prototype = line
            break
if prototype is None:
    raise RuntimeError("Could not locate a float fragment output builtin prototype")
blend_line = prototype.replace('["AO"]', '["MESH_BLEND"]').replace('["ROUGHNESS"]', '["MESH_BLEND"]')
group_line = prototype.replace('["AO"]', '["MESH_BLEND_GROUP"]').replace('["ROUGHNESS"]', '["MESH_BLEND_GROUP"]').replace("TYPE_FLOAT", "TYPE_UINT")
lines[insert_at:insert_at] = [blend_line, group_line]
shader_types.write_text("".join(lines), encoding="utf-8")

# Tell the clustered spatial compiler how to rename and track the outputs.
compiler = Path("servers/rendering/renderer_rd/forward_clustered/scene_shader_forward_clustered.cpp")
text = compiler.read_text(encoding="utf-8")
if 'actions.renames["MESH_BLEND"]' in text:
    raise RuntimeError("MESH_BLEND compiler rename already exists")
lines = text.splitlines(keepends=True)
rename_index = None
for index, line in enumerate(lines):
    if 'actions.renames["AO"]' in line:
        rename_index = index + 1
        indent = line[: len(line) - len(line.lstrip())]
        break
if rename_index is None:
    raise RuntimeError("Could not locate AO rename entry")
lines[rename_index:rename_index] = [
    f'{indent}actions.renames["MESH_BLEND"] = "mesh_blend_output_value";\n',
    f'{indent}actions.renames["MESH_BLEND_GROUP"] = "mesh_blend_group_output_value";\n',
]
text = "".join(lines)
lines = text.splitlines(keepends=True)
usage_index = None
for index, line in enumerate(lines):
    if 'actions.usage_defines["AO"]' in line:
        usage_index = index + 1
        indent = line[: len(line) - len(line.lstrip())]
        break
if usage_index is None:
    raise RuntimeError("Could not locate AO usage define entry")
lines[usage_index:usage_index] = [
    f'{indent}actions.usage_defines["MESH_BLEND"] = "#define MESH_BLEND_USED\\n";\n',
    f'{indent}actions.usage_defines["MESH_BLEND_GROUP"] = "#define MESH_BLEND_GROUP_USED\\n";\n',
]
compiler.write_text("".join(lines), encoding="utf-8")

# Store values produced by material code and route them to the visibility
# auxiliary target. Existing material-uniform behavior remains the fallback.
shader = Path("servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered.glsl")
text = shader.read_text(encoding="utf-8")
marker = "#CODE : FRAGMENT"
if text.count(marker) != 1:
    raise RuntimeError(f"Expected one fragment code marker, found {text.count(marker)}")
text = text.replace(
    marker,
    "float mesh_blend_output_value = 0.0;\nuint mesh_blend_group_output_value = 0u;\n\n" + marker,
)

output_matches = re.findall(
    r"layout\s*\(\s*location\s*=\s*1\s*\)\s*out\s+vec2\s+([A-Za-z_]\w*)\s*;",
    text,
)
if len(output_matches) != 1:
    raise RuntimeError(f"Expected one location-1 vec2 output, found {output_matches}")
aux_output = output_matches[0]
assignment = re.compile(
    rf"(?m)^(?P<indent>\s*){re.escape(aux_output)}\s*=\s*(?P<rhs>vec2\([^;\n]+\));"
)
matches = list(assignment.finditer(text))
if len(matches) != 1:
    raise RuntimeError(f"Expected one {aux_output} assignment, found {len(matches)}")
match = matches[0]
indent = match.group("indent")
original_rhs = match.group("rhs")
replacement = (
    "#if defined(MESH_BLEND_USED) || defined(MESH_BLEND_GROUP_USED)\n"
    f"{indent}{aux_output} = vec2(clamp(mesh_blend_output_value, -1.0, 1.0), float(min(mesh_blend_group_output_value, 255u)) / 255.0);\n"
    "#else\n"
    f"{indent}{aux_output} = {original_rhs};\n"
    "#endif"
)
text = text[: match.start()] + replacement + text[match.end() :]
shader.write_text(text, encoding="utf-8")
