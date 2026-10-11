extends Node3D

const Observer = preload("res://observer.gd")
var checks := 0
var failures := 0

func _ready() -> void:
    var camera := Camera3D.new()
    add_child(camera)
    camera.look_at_from_position(Vector3(0, 1.5, 5), Vector3.ZERO)
    camera.current = true
    var observer := Observer.new()
    var compositor := Compositor.new()
    compositor.compositor_effects = [observer]
    camera.compositor = compositor
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-40, -25, 0)
    sun.shadow_enabled = true
    add_child(sun)
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.12, 0.12, 0.12)
    var world := WorldEnvironment.new()
    world.environment = environment
    add_child(world)
    var floor_mesh := MeshInstance3D.new()
    var floor_box := BoxMesh.new()
    floor_box.size = Vector3(6, 0.2, 6)
    floor_mesh.mesh = floor_box
    floor_mesh.position.y = -0.6
    var material := StandardMaterial3D.new()
    material.metallic = 0.8
    material.roughness = 0.2
    floor_mesh.material_override = material
    add_child(floor_mesh)
    var box := MeshInstance3D.new()
    box.mesh = BoxMesh.new()
    add_child(box)
    for samples in [Viewport.MSAA_DISABLED, Viewport.MSAA_2X]:
        get_viewport().msaa_3d = samples
        for combination in [
            {"ssgi": true, "ssil": false, "ssr": false, "mips": 1, "width": 320},
            {"ssgi": true, "ssil": false, "ssr": true, "mips": 2, "width": 320},
            {"ssgi": false, "ssil": false, "ssr": true, "mips": 1, "width": 160},
            {"ssgi": false, "ssil": true, "ssr": true, "mips": 6, "width": 320},
            {"ssgi": true, "ssil": false, "ssr": true, "mips": 2, "width": 320},
        ]:
            environment.ssgi_enabled = combination.ssgi
            environment.ssil_enabled = combination.ssil
            environment.ssr_enabled = combination.ssr
            for frame in range(8):
                await RenderingServer.frame_post_draw
                await get_tree().process_frame
            checks += 1
            var observed: Dictionary = observer.get_observation()
            var ok: bool = observed.get("width", 0) == combination.width and observed.get("mipmaps", 0) == combination.mips
            var image := get_viewport().get_texture().get_image()
            ok = ok and not image.is_empty()
            if ok:
                print("SSR_HISTORY_OK msaa=%d ssgi=%s ssil=%s ssr=%s format=%s" % [samples, combination.ssgi, combination.ssil, combination.ssr, observed])
            else:
                failures += 1
                print("SSR_HISTORY_FAIL msaa=%d expected=%s observed=%s" % [samples, combination, observed])
    print("SSR_HISTORY_RESULT checks=%d failures=%d" % [checks, failures])
    get_tree().quit(1 if failures else 0)
