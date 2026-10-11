#!/usr/bin/env python3
"""Compile the port's effect shaders to SPIR-V, independently of an editor build."""

import re
import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EFFECTS = ROOT / "servers/rendering/renderer_rd/shaders/effects"
ENVIRONMENT = ROOT / "servers/rendering/renderer_rd/shaders/environment"
STAGES = {"compute": "comp", "vertex": "vert", "fragment": "frag"}


def expand_includes(path: Path) -> str:
    source = path.read_text()
    return re.sub(
        r'^#include "([^"]+)"\s*$',
        lambda match: expand_includes(path.parent / match[1]),
        source,
        flags=re.M,
    )


def scene_shader_variants():
    shader = ROOT / "servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered.glsl"
    source = re.sub(
        r"^#(?:MATERIAL_UNIFORMS|GLOBALS|CODE\s*:.*)\s*$", "",
        expand_includes(shader), flags=re.M,
    )
    general = (
        "#define MAX_DIRECTIONAL_LIGHT_DATA_STRUCTS 4\n"
        "#define MAX_LIGHTMAP_TEXTURES 8\n#define MAX_LIGHTMAPS 8\n"
        "#define HDDAGI_OCT_SIZE 5\n#define MAX_ROUGHNESS_LOD 4.0\n"
        "#define MATERIAL_UNIFORM_SET 3\n"
    )
    modes = [
        "MOTION_VECTORS MESH_BLEND_MAIN_PASS_OUTPUT NORMAL_USED",
        "MOTION_VECTORS MESH_BLEND_MAIN_PASS_OUTPUT NORMAL_USED USE_LIGHTMAP "
        "MODE_SEPARATE_SPECULAR UBERSHADER MULTI_BOUNCE_OCCLUSION_ENABLED",
        "MOTION_VECTORS MESH_BLEND_MAIN_PASS_OUTPUT NORMAL_USED USE_MULTIVIEW",
        "MOTION_VECTORS MESH_BLEND_MAIN_PASS_OUTPUT NORMAL_USED TEXTURE_STREAMING "
        "TEXTURE_STREAMING_DEPTH_PREPASS UV_USED",
        "MODE_RENDER_DEPTH",
        "MODE_RENDER_DEPTH MODE_RENDER_NORMAL_ROUGHNESS NORMAL_USED",
        "MODE_RENDER_DEPTH MODE_RENDER_NORMAL_ROUGHNESS MODE_RENDER_VOXEL_GI NORMAL_USED",
        "MODE_RENDER_DEPTH MODE_RENDER_NORMAL_ROUGHNESS MOTION_VECTORS NORMAL_USED",
        "MODE_RENDER_DEPTH MODE_RENDER_NORMAL_ROUGHNESS MODE_RENDER_VOXEL_GI MOTION_VECTORS NORMAL_USED USE_MULTIVIEW",
        "MODE_RENDER_DEPTH MODE_RENDER_VISIBILITY NORMAL_USED",
        "MODE_RENDER_DEPTH MODE_RENDER_VISIBILITY MODE_RENDER_VISIBILITY_NO_AUX NORMAL_USED",
        "MODE_RENDER_DEPTH MODE_RENDER_VISIBILITY NORMAL_USED USE_MULTIVIEW",
        "MODE_RENDER_DEPTH MODE_RENDER_VISIBILITY NORMAL_USED UBERSHADER",
        "MOTION_VECTORS MESH_BLEND_MAIN_PASS_OUTPUT NORMAL_USED USE_HALF",
    ]
    split = re.split(r'^#\[(\w+)\]\s*$', source, flags=re.M)
    for index in range(1, len(split), 2):
        stage = STAGES[split[index]]
        for variant, mode in enumerate(modes):
            defines = general + "".join(f"#define {flag}\n" for flag in mode.split())
            yield shader, stage, variant, split[index + 1].replace("#VERSION_DEFINES", defines)


def dynamic_gi_variants() -> dict[str, list[str]]:
    """Use the same stage modes as the renderer, including optional GI paths."""
    renderer = ROOT / "servers/rendering/renderer_rd"
    gi = (renderer / "environment/gi.cpp").read_text()

    def modes(source: str, variable: str) -> list[str]:
        return [json.loads('"' + value + '"') for value in re.findall(
            rf'{variable}\.push_back\("((?:[^"\\]|\\.)*)"\)', source,
        )]

    common = (
        "#define LIGHTPROBE_OCT_SIZE 5\n#define OCCLUSION_OCT_SIZE 14\n"
        "#define OCCLUSION_OCT_SIZE_HALF 7\n#define OCCLUSION_SUBPIXELS 4\n"
        "#define SH_SIZE 16\n#define SCREEN_PROBE_DIRECTIONAL_SIZE 8\n"
    )
    variants = {}
    for shader, variable in (
        ("hddagi_preprocess.glsl", "preprocess_modes"),
        ("hddagi_direct_light.glsl", "direct_light_modes"),
        ("hddagi_integrate.glsl", "integrate_modes"),
        ("hddagi_screen_probe.glsl", "screen_probe_modes"),
        ("hddagi_screen_probe_irradiance_cache.glsl", "irradiance_cache_modes"),
        ("hddagi_filter.glsl", "filter_modes"),
        ("gi.glsl", "gi_modes"),
    ):
        variants[shader] = [common + mode for mode in modes(gi, variable)]
        if not variants[shader]:
            raise SystemExit(f"Missing renderer shader modes for {shader}")
    for shader in ("hddagi_integrate.glsl", "hddagi_screen_probe.glsl"):
        variants[shader] += [mode + "#define USE_RADIANCE_OCTMAP_ARRAY\n" for mode in variants[shader]]
    variants["hddagi_debug.glsl"] = [common]
    debug_start = gi.rfind("Vector<String> versions;", 0, gi.index("hddagi_shader.debug_probes.initialize"))
    debug_end = gi.index("hddagi_shader.debug_probes.initialize", debug_start)
    variants["hddagi_debug_probes.glsl"] = [common + mode for mode in modes(gi[debug_start:debug_end], "versions")]
    svgf = (renderer / "environment/hddagi_screen_probe_svgf.cpp").read_text()
    variants["hddagi_screen_probe_svgf.glsl"] = modes(svgf, "modes")
    for shader in ("hddagi_screen_probe_montage.glsl", "hddagi_screen_probe_reflection_debug.glsl"):
        variants[shader] = ["", "#define USE_MULTIVIEW\n"]
    resolve = (renderer / "effects/resolve.cpp").read_text()
    variants["resolve.glsl"] = [mode for mode in modes(resolve, "resolve_modes") if mode]
    ss_effects = (renderer / "effects/ss_effects.cpp").read_text()
    variants["screen_space_reflection_hiz.glsl"] = modes(ss_effects, "ssr_hiz_modes")
    fog_defines = "#define MAX_DIRECTIONAL_LIGHT_DATA_STRUCTS 4\n#define MAX_SKY_LOD 4.0\n"
    variants["volumetric_fog_process.glsl"] = [
        fog_defines + sky + memory + atomics + "".join(f"#define {flag}\n" for flag in mode.split())
        for sky in ("", "#define USE_RADIANCE_OCTMAP_ARRAY\n")
        for memory in ("", "#define USE_VULKAN_MEMORY_MODEL\n")
        for atomics in ("", "#define NO_IMAGE_ATOMICS\n")
        for mode in ("MODE_DENSITY", "MODE_DENSITY ENABLE_HDDAGI", "MODE_FILTER", "MODE_FOG", "MODE_COPY")
    ]
    return variants


def reflection_shader_variants():
    """Check the shared probe code in Mobile and the Compatibility shader."""
    mobile = ROOT / "servers/rendering/renderer_rd/shaders/forward_mobile/scene_forward_mobile.glsl"
    compatibility = ROOT / "drivers/gles3/shaders/scene.glsl"
    general = (
        "#define MAX_DIRECTIONAL_LIGHT_DATA_STRUCTS 4\n"
        "#define MAX_LIGHTMAP_TEXTURES 8\n#define MAX_ROUGHNESS_LOD 4.0\n"
        "#define MATERIAL_UNIFORM_SET 3\n"
    )
    gles_general = (
        "#version 300 es\nprecision highp float;\nprecision highp int;\n"
        "#define MAX_GLOBAL_SHADER_UNIFORMS 256\n#define MAX_LIGHT_DATA_STRUCTS 32\n"
        "#define MAX_DIRECTIONAL_LIGHT_DATA_STRUCTS 4\n#define MAX_FORWARD_LIGHTS 8u\n"
        "#define MAX_ROUGHNESS_LOD 4.0\n#define MAX_DECALS 8\n#define BASE_PASS\n"
    )
    for shader, modes in (
        (mobile, ["NORMAL_USED", "NORMAL_USED USE_HALF", "NORMAL_USED LIGHT_CLEARCOAT_USED"]),
        (compatibility, ["NORMAL_USED", "NORMAL_USED SECOND_REFLECTION_PROBE", "NORMAL_USED SECOND_REFLECTION_PROBE LIGHT_CLEARCOAT_USED"]),
    ):
        source = re.sub(r"^#(?:MATERIAL_UNIFORMS|GLOBALS|CODE\s*:.*)\s*$", "", expand_includes(shader), flags=re.M)
        split = re.split(r'^#\[(\w+)\]\s*$', source, flags=re.M)
        for index in range(1, len(split), 2):
            if split[index] not in STAGES:
                continue
            for variant, mode in enumerate(modes):
                defines = "".join(f"#define {flag}\n" for flag in mode.split())
                vulkan = shader == mobile
                stage_source = split[index + 1]
                stage_source = stage_source.replace("#VERSION_DEFINES", general + defines) if vulkan else gles_general + defines + stage_source
                yield shader, STAGES[split[index]], variant, stage_source, vulkan


def main() -> None:
    shaders = list(EFFECTS.glob("motion_blur*.glsl"))
    shaders += list(EFFECTS.glob("ssgi*.glsl"))
    shaders += list(EFFECTS.glob("mesh_blend*.glsl"))
    shaders += [EFFECTS / name for name in (
        "ssao.glsl", "ssil.glsl", "ssil_interleave.glsl",
        "ss_effects_downsample.glsl", "screen_space_shadows.glsl", "ss_shadow.glsl",
    )]
    variants = {
        "ssao.glsl": ["", "#define SSAO_BASE\n", "#define ADAPTIVE\n"],
        "ssil.glsl": ["", "#define SSIL_BASE\n", "#define ADAPTIVE\n"],
        "ssil_interleave.glsl": ["", "#define MODE_SMART\n", "#define MODE_HALF\n"],
        "ss_effects_downsample.glsl": [
            "", "#define USE_HALF_SIZE\n", "#define GENERATE_MIPS\n",
            "#define GENERATE_MIPS\n#define USE_HALF_SIZE\n",
            "#define USE_HALF_BUFFERS\n",
            "#define USE_HALF_BUFFERS\n#define USE_HALF_SIZE\n",
            "#define GENERATE_MIPS\n#define GENERATE_FULL_MIPS\n",
            "#define GENERATE_MIPS\n#define GENERATE_TWO_MIPS\n",
        ],
    }
    gi_variants = dynamic_gi_variants()
    variants.update(gi_variants)
    shaders += [(ENVIRONMENT if (ENVIRONMENT / name).exists() else EFFECTS) / name for name in gi_variants]
    count = 0
    motion_blur_header = (ROOT / "servers/rendering/renderer_rd/effects/motion_blur.h").read_text()
    tile_size = re.search(r"int tile_size = (\d+);", motion_blur_header)[1]
    with tempfile.TemporaryDirectory(prefix="godot-graphics-shaders-") as directory:
        temp = Path(directory)
        for shader in sorted(shaders):
            split = re.split(r'^#\[(\w+)\]\s*$', expand_includes(shader), flags=re.M)
            for index in range(1, len(split), 2):
                stage = STAGES[split[index]]
                for variant, defines in enumerate(variants.get(shader.name, [""])):
                    if shader.name.startswith("motion_blur"):
                        defines += f"#define TILE_SIZE {tile_size}\n"
                    source = split[index + 1].replace("#VERSION_DEFINES", defines)
                    path = temp / f"{shader.stem}-{variant}.{stage}"
                    path.write_text(source)
                    result = subprocess.run(
                        ["glslangValidator", "-V", "--target-env", "vulkan1.2", "-S", stage,
                         "-o", str(temp / "shader.spv"), str(path)],
                        capture_output=True, text=True,
                    )
                    if result.returncode:
                        raise SystemExit(f"{shader.name} {stage} variant {variant}:\n{result.stdout}{result.stderr}")
                    count += 1
        for shader, stage, variant, source in scene_shader_variants():
            path = temp / f"{shader.stem}-{variant}.{stage}"
            path.write_text(source)
            result = subprocess.run(
                ["glslangValidator", "-V", "--target-env", "vulkan1.2", "-S", stage,
                 "-o", str(temp / "scene.spv"), str(path)],
                capture_output=True, text=True,
            )
            if result.returncode:
                raise SystemExit(f"{shader.name} {stage} variant {variant}:\n{result.stdout}{result.stderr}")
            count += 1
        reflection_count = 0
        for shader, stage, variant, source, vulkan in reflection_shader_variants():
            path = temp / f"reflection-{shader.stem}-{variant}.{stage}"
            path.write_text(source)
            args = ["glslangValidator", "-S", stage]
            if vulkan:
                args += ["-V", "--target-env", "vulkan1.2", "-o", str(temp / "reflection.spv")]
            result = subprocess.run(args + [str(path)], capture_output=True, text=True)
            if result.returncode:
                raise SystemExit(f"{shader.name} {stage} variant {variant}:\n{result.stdout}{result.stderr}")
            reflection_count += 1
    print(f"Compiled {count} graphics shader stages/variants to SPIR-V and checked {reflection_count} Mobile/Compatibility reflection stages.")


if __name__ == "__main__":
    main()
