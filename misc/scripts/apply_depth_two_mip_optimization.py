from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file_path = Path(path)
    text = file_path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected 1 occurrence, found {count}: {old!r}")
    file_path.write_text(text.replace(old, new), encoding="utf-8")


replace_once(
    "servers/rendering/renderer_rd/effects/ss_effects.h",
    "\t\tSS_EFFECTS_DOWNSAMPLE_FULL_MIPS,\n\t\tSS_EFFECTS_MAX",
    "\t\tSS_EFFECTS_DOWNSAMPLE_FULL_MIPS,\n\t\tSS_EFFECTS_DOWNSAMPLE_TWO_MIPS,\n\t\tSS_EFFECTS_MAX",
)

replace_once(
    "servers/rendering/renderer_rd/effects/ss_effects.cpp",
    "\t\tdownsampler_modes.push_back(\"\\n#define GENERATE_MIPS\\n#define GENERATE_FULL_MIPS\");\n\n\t\tss_effects.downsample_shader.initialize(downsampler_modes);",
    "\t\tdownsampler_modes.push_back(\"\\n#define GENERATE_MIPS\\n#define GENERATE_FULL_MIPS\");\n\t\tdownsampler_modes.push_back(\"\\n#define GENERATE_MIPS\\n#define GENERATE_TWO_MIPS\\n\");\n\n\t\tss_effects.downsample_shader.initialize(downsampler_modes);",
)

replace_once(
    "servers/rendering/renderer_rd/effects/ss_effects.cpp",
    "\t\t} else {\n\t\t\t// Only need the first two mipmaps, but the cost to generate the next two is trivial\n\t\t\t// TODO investigate the benefit of a shader version to generate only 2 mips\n\t\t\tdownsample_mode = SS_EFFECTS_DOWNSAMPLE_MIPMAP;\n\t\t\tuse_mips = true;\n\t\t}\n",
    "\t\t} else {\n\t\t\tdownsample_mode = SS_EFFECTS_DOWNSAMPLE_TWO_MIPS;\n\t\t\tuse_mips = true;\n\t\t}\n",
)

replace_once(
    "servers/rendering/renderer_rd/effects/ss_effects.cpp",
    "\t\t// Note, use_full_mips is true if either SSAO or SSIL uses half size, but the other full size and we're using mips.\n\t\t// That means we're filling all 5 levels.\n\t\t// In this scenario `depth_index` will be 0.\n\t\tfor (int i = 0; i < (use_full_mips ? 4 : 3); i++) {",
    "\t\t// Note, use_full_mips is true if either SSAO or SSIL uses half size, but the other full size and we're using mips.\n\t\t// That means we're filling all 5 levels.\n\t\t// In this scenario `depth_index` will be 0.\n\t\tconst int generated_mip_count = use_full_mips ? 4 : (downsample_mode == SS_EFFECTS_DOWNSAMPLE_TWO_MIPS ? 1 : 3);\n\t\tfor (int i = 0; i < generated_mip_count; i++) {",
)

shader_path = Path("servers/rendering/renderer_rd/shaders/effects/ss_effects_downsample.glsl")
shader = shader_path.read_text(encoding="utf-8")
old = """#ifdef GENERATE_MIPS
layout(r16f, set = 2, binding = 0) uniform restrict writeonly image2DArray dest_image1;
layout(r16f, set = 2, binding = 1) uniform restrict writeonly image2DArray dest_image2;
layout(r16f, set = 2, binding = 2) uniform restrict writeonly image2DArray dest_image3;
#ifdef GENERATE_FULL_MIPS
layout(r16f, set = 2, binding = 3) uniform restrict writeonly image2DArray dest_image4;
#endif
#endif"""
new = """#ifdef GENERATE_MIPS
layout(r16f, set = 2, binding = 0) uniform restrict writeonly image2DArray dest_image1;
#ifndef GENERATE_TWO_MIPS
layout(r16f, set = 2, binding = 1) uniform restrict writeonly image2DArray dest_image2;
layout(r16f, set = 2, binding = 2) uniform restrict writeonly image2DArray dest_image3;
#ifdef GENERATE_FULL_MIPS
layout(r16f, set = 2, binding = 3) uniform restrict writeonly image2DArray dest_image4;
#endif
#endif
#endif"""
if shader.count(old) != 1:
    raise RuntimeError(f"depth shader output declarations mismatch: {shader.count(old)}")
shader = shader.replace(old, new)

old = """\t\tdepth_buffer[depth_array_index][buffer_coord.x][buffer_coord.y] = avg;
\t}

\tbool still_alive = p_gtid.x % 4 == depth_array_offset.x && p_gtid.y % 4 == depth_array_offset.y;"""
new = """\t\tdepth_buffer[depth_array_index][buffer_coord.x][buffer_coord.y] = avg;
\t}

#ifdef GENERATE_TWO_MIPS
\treturn;
#else
\tbool still_alive = p_gtid.x % 4 == depth_array_offset.x && p_gtid.y % 4 == depth_array_offset.y;"""
if shader.count(old) != 1:
    raise RuntimeError(f"depth shader early-return insertion mismatch: {shader.count(old)}")
shader = shader.replace(old, new)

old = """#endif
}
#else
#ifndef USE_HALF_BUFFERS"""
new = """#endif
#endif // GENERATE_TWO_MIPS
}
#else
#ifndef USE_HALF_BUFFERS"""
if shader.count(old) != 1:
    raise RuntimeError(f"depth shader conditional close mismatch: {shader.count(old)}")
shader_path.write_text(shader.replace(old, new), encoding="utf-8")
