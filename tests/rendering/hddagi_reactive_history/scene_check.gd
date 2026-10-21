extends SceneTree

var checks := 0
var failures := 0
var world: Node3D
var env: Environment
var light: OmniLight3D
var camera: Camera3D
var out := "user://"
var observer

func check(ok: bool, message: String) -> void:
	checks += 1
	print("REACTIVE_SCENE_OK " if ok else "REACTIVE_SCENE_FAIL ", message)
	if not ok:
		failures += 1

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(out)
	call_deferred("run")

func box(position: Vector3, size: Vector3, color: Color) -> void:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.position = position
	instance.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	instance.material_override = material
	world.add_child(instance)

func frames(count: int) -> void:
	for frame in count:
		await process_frame
		await RenderingServer.frame_post_draw

func capture(label: String) -> Image:
	await frames(2)
	var image := root.get_texture().get_image()
	check(image != null and not image.is_empty(), label + " rendered")
	check(observer.is_active(), label + " uses screen-probe SVGF resources")
	if image != null:
		image.save_png(out.path_join(label + ".png"))
	return image

func run() -> void:
	if not OS.get_cmdline_user_args().has("--baseline"):
		check(ProjectSettings.has_setting("rendering/global_illumination/hddagi/screen_probe_denoiser_reactive"), "reactive setting registered")
		check(ProjectSettings.get_setting("rendering/global_illumination/hddagi/screen_probe_denoiser_reactive", false), "reactive response enabled by default")
	world = Node3D.new()
	root.add_child(world)
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.01, 0.01, 0.01)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.dynamic_gi_enabled = true
	env.dynamic_gi_cascades = 1
	env.dynamic_gi_min_cell_size = 0.2
	env.dynamic_gi_read_sky_light = false
	env.dynamic_gi_screen_probes_enabled = true
	env.ss_shadow_enabled = false
	we.environment = env
	world.add_child(we)
	# The custom SSS pass expects a directional light even when this effect is disabled.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-70, -20, 0)
	sun.light_energy = 0.001
	sun.light_indirect_energy = 0.0
	world.add_child(sun)
	box(Vector3(0, -0.15, 0), Vector3(8, 0.3, 8), Color(0.7, 0.7, 0.7))
	box(Vector3(-3, 1.5, 0), Vector3(0.25, 3, 6), Color(0.8, 0.1, 0.05))
	box(Vector3(0, 1.5, -3), Vector3(6, 3, 0.25), Color(0.7, 0.7, 0.7))
	box(Vector3(0, 0.6, 0), Vector3(1.2, 1.2, 1.2), Color(0.6, 0.6, 0.6))
	light = OmniLight3D.new()
	light.position = Vector3(-1.8, 1.6, 0.2)
	light.omni_range = 7
	light.light_energy = 4
	light.shadow_enabled = true
	world.add_child(light)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.look_at_from_position(Vector3(4, 3.5, 6), Vector3(0, 0.8, 0))
	camera.current = true
	observer = preload("res://observer.gd").new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [observer]
	camera.compositor = compositor
	for mode in 2:
		env.dynamic_gi_screen_probe_mode = mode
		await frames(90)
		await capture("mode_%d_lit" % mode)
		light.light_energy = 0
		await frames(12)
		await capture("mode_%d_off" % mode)
		light.light_energy = 4
		await frames(12)
		await capture("mode_%d_relit" % mode)
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_denoiser_reactive", false)
	await frames(12)
	await capture("legacy_response")
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_denoiser_reactive", true)
	root.size = Vector2i(333, 197)
	camera.position += Vector3(0.4, 0.1, 0)
	await frames(16)
	await capture("resized_reactive")
	world.queue_free()
	await frames(4)
	# Drain the renderer before exit to verify resource cleanup.
	root.get_texture().get_image()
	print("HDDAGI_REACTIVE_SCENE_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
