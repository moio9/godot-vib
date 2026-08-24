#!/usr/bin/env python3

import re
from pathlib import Path

CPP = Path("servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp")


def function_extent(text: str, signature_pattern: str) -> tuple[int, int]:
    match = re.search(signature_pattern, text)
    if match is None:
        raise RuntimeError(f"Function signature not found: {signature_pattern}")
    open_brace = text.find("{", match.end())
    if open_brace < 0:
        raise RuntimeError("Function opening brace was not found")
    depth = 0
    for index in range(open_brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return match.start(), index + 1
    raise RuntimeError("Function closing brace was not found")


def main() -> None:
    text = CPP.read_text(encoding="utf-8")
    text = text.replace(
        "get_color_pass_fb_mesh_blend(color_pass_flags)",
        "get_color_pass_fb(color_pass_flags)",
    )

    start, end = function_extent(
        text,
        r"RID\s+RenderForwardClustered::RenderBufferDataForwardClustered::get_color_pass_fb\s*\(uint32_t\s+p_color_pass_flags\)",
    )
    function = text[start:end]

    if "RID mesh_blend_aux;" not in function:
        depth_decl = re.search(r"(?m)^(?P<indent>[\t ]*)RID\s+depth\s*=", function)
        if depth_decl is None:
            raise RuntimeError("Color-pass depth attachment declaration was not found")
        indent = depth_decl.group("indent")
        block = (
            f"{indent}RID mesh_blend_aux;\n"
            f"{indent}if (p_color_pass_flags & COLOR_PASS_FLAG_MESH_BLEND) {{\n"
            f"{indent}\trender_buffers->ensure_visibility_textures(false, true, false);\n"
            f"{indent}\tmesh_blend_aux = render_buffers->get_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_AUX);\n"
            f"{indent}}}\n\n"
        )
        function = function[: depth_decl.start()] + block + function[depth_decl.start() :]

    packed = "color, specular, velocity_buffer, mesh_blend_aux, depth"
    if function.count(packed) < 2:
        unpacked = "color, specular, velocity_buffer, depth"
        if function.count(unpacked) < 2:
            raise RuntimeError("Both Forward+ color framebuffer cache calls were not found")
        function = function.replace(unpacked, packed)

    text = text[:start] + function + text[end:]
    CPP.write_text(text, encoding="utf-8")

    final = CPP.read_text(encoding="utf-8")
    required = (
        "COLOR_PASS_FLAG_MESH_BLEND",
        packed,
        "const bool mesh_blend_main_pass = _mesh_blend_enabled()",
        "RSE::VIEWPORT_MSAA_DISABLED",
        "texture_clear(mesh_blend_main_aux",
        "mesh_blend_requires_visibility_pass",
    )
    missing = [value for value in required if value not in final]
    if missing:
        raise RuntimeError("Incomplete Forward+ Mesh Blend path: " + ", ".join(missing))
    if final.count(packed) < 2:
        raise RuntimeError("Mesh Blend AUX is not attached in both framebuffer variants")


if __name__ == "__main__":
    main()
