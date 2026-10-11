#!/usr/bin/env python3
"""Compile the port's effect shaders to SPIR-V, independently of an editor build."""

import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EFFECTS = ROOT / "servers/rendering/renderer_rd/shaders/effects"
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
        "#define SDFGI_OCT_SIZE 8\n#define MAX_ROUGHNESS_LOD 4.0\n"
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
    print(f"Compiled {count} graphics shader stages/variants to SPIR-V.")


if __name__ == "__main__":
    main()
