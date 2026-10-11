extends Node3D

var output := ""
var metrics := {}
var checks := 0
var failures := 0

func check_result(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("REGRESSION_FAIL " + message)

func difference(first: String, second: String) -> float:
	var a := Image.load_from_file(output.path_join(first + ".png"))
	var b := Image.load_from_file(output.path_join(second + ".png"))
	var total := 0.0
	var count := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var av := a.get_pixel(x, y)
			var bv := b.get_pixel(x, y)
			total += (absf(av.r - bv.r) + absf(av.g - bv.g) + absf(av.b - bv.b)) / 3.0
			count += 1
	return total / count

func box(parent: Node3D, position_value: Vector3, dimensions: Vector3, color: Color) -> void:
	var mesh := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = dimensions
	mesh.mesh = shape
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	mesh.material_override = material
	mesh.position = position_value
	parent.add_child(mesh)

func make_world(parent: Node3D, alternate := false) -> Dictionary:
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.15, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.65, 0.75)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.6
	env.ss_shadow_thickness = 0.02
	env.ss_shadow_max_distance = 1.5
	env.ss_shadow_steps = 96
	env.ss_shadow_light_radius = 0.0
	env.ss_shadow_strength = 0.8
	env.ss_shadow_history_weight = 0.4
	env.ssgi_radius = 12
	env.ssgi_intensity = 1.0
	world.environment = env
	parent.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	parent.add_child(sun)
	box(parent, Vector3(0, -0.2, 0), Vector3(18, 0.4, 18), Color(0.6, 0.6, 0.6))
	if alternate:
		box(parent, Vector3(0, 1.5, 0), Vector3(5, 3, 1), Color(0.15, 0.65, 0.2))
	else:
		box(parent, Vector3(-1.3, 0.75, 0), Vector3(1.4, 1.5, 1.4), Color(0.8, 0.12, 0.07))
		box(parent, Vector3(1.4, 0.45, -1.2), Vector3(1.2, 0.9, 1.2), Color(0.15, 0.35, 0.8))
		box(parent, Vector3(0.8, 1.5, 1.0), Vector3(0.35, 3.0, 0.35), Color(0.3, 0.3, 0.3))
	var camera := Camera3D.new()
	camera.position = Vector3(4, 3.2, 6)
	camera.fov = 65
	camera.near = 0.1
	camera.far = 100
	parent.add_child(camera)
	camera.look_at(Vector3(0, 0.6, 0))
	camera.current = true
	return {"environment": env, "camera": camera}

func settle(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw

func capture(label: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(output.path_join(label + ".png"))
	if error != OK:
		push_error("CAPTURE_FAILED " + label)
		get_tree().quit(2)
	var minimum := 1.0
	var maximum := 0.0
	var average := 0.0
	var samples := 0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var pixel := image.get_pixel(x, y)
			var value := (pixel.r + pixel.g + pixel.b) / 3.0
			minimum = minf(minimum, value)
			maximum = maxf(maximum, value)
			average += value
			samples += 1
	metrics[label] = {"min": minimum, "max": maximum, "mean": average / samples}

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			output = argument.trim_prefix("--out=")
	if output.is_empty():
		push_error("Specify -- --out=/absolute/capture/directory")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var setup := make_world(self)
	var env: Environment = setup.environment
	var camera: Camera3D = setup.camera
	var viewport := get_viewport()
	viewport.use_taa = false
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	print("REGRESSION_VERSION ", Engine.get_version_info().string)
	print("REGRESSION_BINARY_SHA256 ", FileAccess.get_sha256(OS.get_executable_path()))
	print("REGRESSION_RENDERER ", RenderingServer.get_current_rendering_method())
	for aa in [Viewport.MSAA_DISABLED, Viewport.MSAA_8X]:
		viewport.msaa_3d = aa
		var prefix := "msaa%d_" % aa
		env.ssao_enabled = true
		env.ss_shadow_enabled = false
		env.ssgi_enabled = false
		env.ssil_enabled = false
		viewport.debug_draw = Viewport.DEBUG_DRAW_SSAO
		for distance in [3.0, 8.0, 16.0]:
			camera.position = Vector3(0, 1.4 + distance * 0.1, distance)
			camera.look_at(Vector3(0, 0.7, 0))
			await settle(4)
			capture(prefix + "ssao_%d" % int(distance))
		camera.position = Vector3(4, 3.2, 6)
		camera.look_at(Vector3(0, 0.6, 0))
		env.ssao_enabled = false
		env.ss_shadow_enabled = true
		env.ss_shadow_history_weight = 0.4
		viewport.debug_draw = Viewport.DEBUG_DRAW_SSS
		await settle(8)
		capture(prefix + "sss_static")
		for i in range(24):
			camera.position.x = lerpf(4.0, -4.0, float(i) / 23.0)
			camera.look_at(Vector3(0, 0.6, 0))
			await settle(1)
		capture(prefix + "sss_pan_history")
		env.ss_shadow_history_weight = 0.0
		await settle(1)
		capture(prefix + "sss_pan_no_history")
		env.ss_shadow_history_weight = 0.4
		camera.position = Vector3(3, 2.4, -5)
		camera.look_at(Vector3(0, 0.6, 0))
		await settle(1)
		capture(prefix + "sss_cut_history")
		env.ss_shadow_history_weight = 0.0
		await settle(1)
		capture(prefix + "sss_cut_no_history")
		env.ss_shadow_enabled = false
		env.ssgi_enabled = true
		viewport.debug_draw = Viewport.DEBUG_DRAW_SSGI
		await settle(8)
		for i in range(12):
			camera.position.x = lerpf(3.0, -3.0, float(i) / 11.0)
			camera.look_at(Vector3(0, 0.6, 0))
			await settle(1)
		capture(prefix + "ssgi_pan")
		viewport.debug_draw = Viewport.DEBUG_DRAW_MOTION_VECTORS
		camera.position.x += 0.3
		camera.look_at(Vector3(0, 0.6, 0))
		await settle(1)
		capture(prefix + "motion_vectors")
		env.ssgi_enabled = false
		env.ssil_enabled = true
		viewport.debug_draw = Viewport.DEBUG_DRAW_SSIL
		await settle(8)
		capture(prefix + "ssil")
		env.ssao_enabled = true
		env.ssgi_enabled = true
		env.ss_shadow_enabled = true
		env.ss_shadow_history_weight = 0.4
		viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED
		await settle(8)
		capture(prefix + "combined")
	# Rendering a second world must not contaminate this viewport's shadow history.
	env.ssao_enabled = false
	env.ssgi_enabled = false
	env.ssil_enabled = false
	env.ss_shadow_enabled = true
	env.ss_shadow_history_weight = 0.9
	viewport.debug_draw = Viewport.DEBUG_DRAW_SSS
	await settle(30)
	capture("sss_single_viewport")
	var other := SubViewport.new()
	other.size = Vector2i(640, 360)
	other.own_world_3d = true
	other.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(other)
	var other_root := Node3D.new()
	other.add_child(other_root)
	var alternate := make_world(other_root, true)
	alternate.environment.ss_shadow_enabled = true
	alternate.environment.ss_shadow_history_weight = 0.9
	await settle(10)
	capture("sss_two_viewports")
	# Resizing recreates history textures; the first frame must be initialized.
	viewport.scaling_3d_scale = 0.75
	await settle(3)
	capture("sss_resized")
	check_result(RenderingServer.get_current_rendering_method() == "forward_plus", "Forward+ required")
	check_result(absf(metrics.msaa0_ssgi_pan.mean - metrics.msaa3_ssgi_pan.mean) < 0.005, "SSGI must retain consistent energy with MSAA 8x")
	for aa in [0, 3]:
		var label := "msaa%d_" % aa
		var cut_error := difference(label + "sss_cut_history", label + "sss_cut_no_history")
		check_result(cut_error < 0.002, "SSS history after camera cut: %f" % cut_error)
		for distance in [3, 8, 16]:
			var ao: Dictionary = metrics[label + "ssao_%d" % distance]
			check_result(ao.max - ao.min > 0.02, "SSAO mask must contain occlusion")
	var viewport_error := difference("sss_single_viewport", "sss_two_viewports")
	check_result(viewport_error < 0.003, "SSS cross-viewport contamination: %f" % viewport_error)
	check_result(metrics.sss_resized.max - metrics.sss_resized.min > 0.02, "SSS mask must survive resize")
	var file := FileAccess.open(output.path_join("metrics.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics, "  "))
	print("REGRESSION_CAPTURE_COMPLETE ", metrics.size())
	print("REGRESSION_RESULT checks=", checks, " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)
