extends Node

var checks := 0
var failures := 0

func _ready() -> void:
    var version := Engine.get_version_info()
    var match_version := "GODOT_VERSION_MAJOR == %d && GODOT_VERSION_MINOR == %d && GODOT_VERSION_PATCH == %d" % [version.major, version.minor, version.patch]
    await check_shader("numeric_values", """
shader_type canvas_item;
void fragment() {
    COLOR = vec4(float(GODOT_VERSION_MAJOR == %d), float(GODOT_VERSION_MINOR == %d), float(GODOT_VERSION_PATCH != %d), 1.0);
    COLOR.r = 1.0 - COLOR.r;
}
""" % [version.major, version.minor, version.patch])
    await check_shader("excluded_unsupported_code", """
shader_type canvas_item;
void fragment() {
#if %s
    COLOR = vec4(0.0, 1.0, 0.0, 1.0);
#else
    COLOR = nonexistent_function_in_other_engine_version();
#endif
}
""" % match_version)
    await check_shader("shader_include", """
shader_type canvas_item;
#include "res://version.gdshaderinc"
void fragment() {
    COLOR = version_include_color();
}
""")
    await check_shader("existing_renderer_defines", """
shader_type canvas_item;
void fragment() {
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
    COLOR = vec4(0.0, 1.0, 0.0, 1.0);
#else
    COLOR = vec4(1.0, 0.0, 0.0, 1.0);
#endif
}
""")
    print("SHADER_VERSION_RESULT checks=%d failures=%d" % [checks, failures])
    get_tree().quit(1 if failures else 0)

func check_shader(case_name: String, code: String) -> void:
    var shader := Shader.new()
    shader.code = code
    var material := ShaderMaterial.new()
    material.shader = shader
    var viewport := SubViewport.new()
    viewport.size = Vector2i(16, 16)
    viewport.disable_3d = true
    viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    add_child(viewport)
    var rect := ColorRect.new()
    rect.size = Vector2(16, 16)
    rect.material = material
    viewport.add_child(rect)
    for _frame in range(3):
        await RenderingServer.frame_post_draw
    var pixel := viewport.get_texture().get_image().get_pixel(8, 8)
    checks += 1
    if pixel.g > 0.9 and pixel.r < 0.1 and pixel.b < 0.1:
        print("SHADER_VERSION_OK case=%s" % case_name)
    else:
        failures += 1
        print("SHADER_VERSION_FAIL case=%s pixel=%s" % [case_name, pixel])
    viewport.free()
    await RenderingServer.frame_post_draw
