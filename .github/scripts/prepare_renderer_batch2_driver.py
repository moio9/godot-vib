#!/usr/bin/env python3

from pathlib import Path

DRIVER = Path(".github/scripts/apply_renderer_batch2.py")


def insert_once(text: str, marker: str, addition: str, guard: str) -> str:
    if guard in text:
        return text
    if marker not in text:
        raise RuntimeError(f"Driver marker was not found: {marker}")
    return text.replace(marker, marker + addition, 1)


def main() -> None:
    text = DRIVER.read_text(encoding="utf-8")

    compact_marker = '    elif adapter == "compact-current":\n'
    compact_addition = '''        body = body.replace(
            r'r"void ([A-Za-z0-9_:]+)::ensure_visibility_textures',
            r'r"bool ([A-Za-z0-9_:]+)::ensure_visibility_textures',
        )
        body = body.replace(
            r'r"void \\1::ensure_visibility_textures',
            r'r"bool \\1::ensure_visibility_textures',
        )
'''
    text = insert_once(
        text,
        compact_marker,
        compact_addition,
        "grouped compact visibility allocator compatibility",
    )
    text = text.replace(
        compact_marker + compact_addition,
        compact_marker
        + "        # grouped compact visibility allocator compatibility\n"
        + compact_addition,
        1,
    )

    patch_marker = '    patch_path = Path("/tmp/renderer-source-patch.py")\n'
    compatibility = r"""    # Godot 4.7.2 compatibility for validated renderer patch programs.
    if branch == "opt/mesh-blend-rg16-edges":
        body = body.replace(
            'if "RB_TEX_VB_VIS" in text and "RD::DATA_FORMAT_R32G32_UINT" in text:',
            'if "RB_TEX_VB_VIS" in text and ("RD::DATA_FORMAT_R32G32_UINT" in text or "RenderingDevice::DATA_FORMAT_R32G32_UINT" in text):',
        )

    if branch == "opt/mesh-blend-packed-vb-aux":
        body = body.replace(
            "RD::DATA_FORMAT_R16G16_SFLOAT",
            "RenderingDevice::DATA_FORMAT_R16G16_SFLOAT",
        )
        body = body.replace(
            'new = "RD::DATA_FORMAT_R16_UINT"',
            'new = "RenderingDevice::DATA_FORMAT_R16_UINT"',
        )
        body = body.replace(
            'if "RB_TEX_VB_AUX" in content and "RD::DATA_FORMAT_R16_UINT" in content:',
            'if "RB_TEX_VB_AUX" in content and ("RD::DATA_FORMAT_R16_UINT" in content or "RenderingDevice::DATA_FORMAT_R16_UINT" in content):',
        )
        body = body.replace(
            'if "mesh_blend" in content.lower() and "mask" in content.lower() and "RD::DATA_FORMAT_R16_UINT" in content:',
            'if "mesh_blend" in content.lower() and "mask" in content.lower() and ("RD::DATA_FORMAT_R16_UINT" in content or "RenderingDevice::DATA_FORMAT_R16_UINT" in content):',
        )

    if branch == "opt/mesh-blend-reuse-vb-aux-mask":
        body = body.replace(
            r"(\.blend\(",
            r"((?:\.|->)blend\(",
        )
        usage_marker = "# VB_AUX is now sampled directly by the final blend pass;"
        if usage_marker not in body:
            raise RuntimeError("VB_AUX usage validation block was not found")
        body = body[: body.index(usage_marker)] + '''# Ensure the local VB_AUX usage declaration includes sampling.
aux_path = Path("servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.cpp")
aux_text = aux_path.read_text(encoding="utf-8")
call_token = "create_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_AUX"
call_index = aux_text.find(call_token)
if call_index < 0:
    raise RuntimeError("VB_AUX create_texture call was not found")
usage_index = aux_text.rfind("const uint32_t usage = ", 0, call_index)
if usage_index < 0:
    raise RuntimeError("VB_AUX local usage declaration was not found")
usage_end = aux_text.find(";", usage_index)
if usage_end < 0:
    raise RuntimeError("VB_AUX local usage declaration is unterminated")
sampling_flag = "RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT"
usage_decl = aux_text[usage_index:usage_end]
if sampling_flag not in usage_decl:
    aux_text = aux_text[:usage_end] + " | " + sampling_flag + aux_text[usage_end:]
aux_path.write_text(aux_text, encoding="utf-8")
'''

    if branch == "opt/mesh-blend-main-pass-metadata":
        body, replacement_count = re.subn(
            r'header_candidates = \[\]\n.*?header = header_candidates\[0\]\n',
            'header = Path("servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h")\n'
            'if not header.exists():\n'
            '    raise RuntimeError("The Forward+ color-pass flag header was not found")\n',
            body,
            count=1,
            flags=re.DOTALL,
        )
        if replacement_count != 1:
            raise RuntimeError(
                f"Expected one main-pass header discovery block, replaced {replacement_count}"
            )

        old_fb_pattern = r'''r"(?m)^(?P<indent>[\t ]*)RID\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*[^;]*get_color_pass_fb\((?P<flags>[A-Za-z_][A-Za-z0-9_]*)\)\s*;"'''
        new_fb_pattern = r'''r"(?m)^(?P<indent>[\t ]*)(?:RID\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*[^;]*get_color_pass_fb\((?P<flags>[A-Za-z_][A-Za-z0-9_]*)\)[^;]*;"'''
        if old_fb_pattern not in body:
            raise RuntimeError("The old opaque framebuffer regex was not found")
        body = body.replace(old_fb_pattern, new_fb_pattern, 1)

        old_output_check = 'if location_three_outputs != [("uint", "frag_mesh_blend_aux")]:'
        new_output_check = 'if location_three_outputs.count(("uint", "frag_mesh_blend_aux")) != 1:'
        if old_output_check not in body:
            raise RuntimeError("The old location-three output validation was not found")
        body = body.replace(old_output_check, new_output_check, 1)

        validation_marker = "# Final C++ source invariants."
        if validation_marker not in body:
            raise RuntimeError("Main-pass C++ invariants marker was not found")
        current_cpp_repair = '''# Repair the current Godot 4.7.2 no-MSAA C++ setup if the old script
# only updated the fallback condition but skipped the declaration/framebuffer path.
render_text = cpp.read_text(encoding="utf-8")
if "COLOR_PASS_FLAG_MESH_BLEND" not in render_text:
    framebuffer_match = re.search(
        r"(?m)^(?P<indent>[\\t ]*)color_framebuffer\\s*=\\s*.*get_color_pass_fb(?:_mesh_blend)?\\(color_pass_flags\\).*;$",
        render_text,
    )
    if framebuffer_match is None:
        raise RuntimeError("Current 4.7.2 color framebuffer assignment was not found")

    indent = framebuffer_match.group("indent")
    setup = (
        f"{indent}const bool mesh_blend_main_pass = _mesh_blend_enabled() && "
        f"p_render_data->reflection_probe.is_null() && "
        f"rb->get_msaa_3d() == RSE::VIEWPORT_MSAA_DISABLED;\\n"
        f"{indent}if (mesh_blend_main_pass) {{\\n"
        f"{indent}\\tcolor_pass_flags |= COLOR_PASS_FLAG_MESH_BLEND;\\n"
        f"{indent}\\trb->ensure_visibility_textures(false, true, false);\\n"
        f"{indent}\\tRID mesh_blend_main_aux = rb->get_texture(RB_SCOPE_BUFFERS, RB_TEX_VB_AUX);\\n"
        f"{indent}\\tif (mesh_blend_main_aux.is_valid()) {{\\n"
        f"{indent}\\t\\tRD::get_singleton()->texture_clear(mesh_blend_main_aux, Color(0, 0, 0, 0), 0, 1, 0, rb->get_view_count());\\n"
        f"{indent}\\t}}\\n"
        f"{indent}}}\\n"
    )
    acquisition = (
        f"{indent}color_framebuffer = (color_pass_flags & COLOR_PASS_FLAG_MESH_BLEND) ? "
        "rb_data->get_color_pass_fb_mesh_blend(color_pass_flags) : "
        "rb_data->get_color_pass_fb(color_pass_flags);"
    )
    render_text = (
        render_text[: framebuffer_match.start()]
        + setup
        + acquisition
        + render_text[framebuffer_match.end() :]
    )

    old_fallback = "\\tif (visibility_debug || _mesh_blend_enabled()) {"
    new_fallback = "\\tif (visibility_debug || (_mesh_blend_enabled() && !mesh_blend_main_pass)) {"
    if old_fallback in render_text:
        render_text = render_text.replace(old_fallback, new_fallback, 1)
    elif new_fallback not in render_text and "mesh_blend_requires_visibility_pass" not in render_text:
        raise RuntimeError("Current 4.7.2 Visibility fallback condition was not found")

    cpp.write_text(render_text, encoding="utf-8")

'''
        body = body.replace(validation_marker, current_cpp_repair + validation_marker, 1)

"""
    text = insert_once(
        text,
        patch_marker,
        compatibility,
        "Godot 4.7.2 compatibility for validated renderer patch programs",
    )

    DRIVER.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
