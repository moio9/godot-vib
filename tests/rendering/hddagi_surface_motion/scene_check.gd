extends SceneTree
var checks := 0
var failures := 0
var out := "user://"
var baseline := false
var car_scene := ""
var world: Node3D
var car: Node3D
var camera: Camera3D
var env: Environment
var observer
var car_center := Vector3(0, 0.8, 0)
var camera_offset := Vector3(2.5, 1.5, 3.5)
var results: Array = []
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): out = arg.trim_prefix("--out=")
		if arg.begins_with("--car="): car_scene = arg.trim_prefix("--car=")
		if arg == "--baseline": baseline = true
	DirAccess.make_dir_recursive_absolute(out)
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("MOVING_SCENE_OK " if ok else "MOVING_SCENE_FAIL ", message)
func make_box(parent: Node3D, position: Vector3, size: Vector3, color: Color, mode := GeometryInstance3D.GI_MODE_STATIC) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = position
	node.gi_mode = mode
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	node.material_override = material
	parent.add_child(node)
	return node
func strip_gameplay(node: Node) -> void:
	node.set_script(null)
	node.process_mode = Node.PROCESS_MODE_DISABLED
	if node is Light3D: node.visible = false
	if node is GeometryInstance3D: node.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	for child in node.get_children(): strip_gameplay(child)
func collect_bounds(node: Node, transform: Transform3D, bounds: Array) -> void:
	if node is Node3D: transform = transform * node.transform
	if node is MeshInstance3D and node.mesh:
		var box: AABB = transform * node.get_aabb()
		bounds.append(box)
	for child in node.get_children(): collect_bounds(child, transform, bounds)
func frames(count: int, velocity := Vector3.ZERO) -> void:
	for frame in count:
		if velocity != Vector3.ZERO:
			car.position += velocity
			camera.position += velocity
		await process_frame
		await RenderingServer.frame_post_draw
func capture(label: String, velocity := Vector3.ZERO) -> Dictionary:
	observer.request_capture()
	await frames(1, velocity)
	var info: Dictionary = observer.get_observation()
	check(not info.is_empty(), label + " samples actual GI buffers")
	var image := root.get_texture().get_image()
	image.save_png(out.path_join(label + ".png"))
	if info.is_empty(): return {}
	var size: Vector2i = info.size
	var floats: PackedFloat32Array = info.floats
	var ids: PackedInt32Array = info.integers
	var center := camera.unproject_position(car.global_position + car_center)
	var roi := Rect2i(Vector2i(center) - Vector2i(24, 14), Vector2i(48, 28)).intersection(Rect2i(Vector2i.ZERO, size))
	var sum := 0.0
	var count := 0
	var dynamic_count := 0
	var identities := {}
	for y in range(roi.position.y, roi.end.y):
		for x in range(roi.position.x, roi.end.x):
			var i := (y * size.x + x) * 6
			var value := floats[i+2] * 0.2126 + floats[i+3] * 0.7152 + floats[i+4] * 0.0722
			if not is_finite(value): continue
			sum += value
			count += 1
			if floats[i+5] > 0.5: dynamic_count += 1
			if ids[i] != 0: identities[ids[i]] = true
	var result := {"label": label, "gi_mean": sum / maxi(count, 1), "dynamic_fraction": float(dynamic_count) / maxi(count, 1), "surface_ids": identities.keys(), "metadata": info.metadata}
	print("MOVING_SCENE_SAMPLE ", JSON.stringify(result))
	results.append(result)
	if not baseline:
		check(info.metadata and not identities.is_empty(), label + " carries stable surface identities")
		if "moving" in label: check(float(result.dynamic_fraction) > 0.5, label + " actually observes the moving car")
	return result
func run() -> void:
	root.size = Vector2i(640, 360)
	ProjectSettings.set_setting("rendering/debug/visibility_buffer/test_pattern", 0)
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_denoiser", 1)
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_detail_trace", true)
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_directional_screen_radiance", true)
	world = Node3D.new()
	root.add_child(world)
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.08, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.dynamic_gi_enabled = true
	env.dynamic_gi_cascades = 1
	env.dynamic_gi_min_cell_size = 0.2
	env.dynamic_gi_read_sky_light = false
	env.dynamic_gi_screen_probes_enabled = true
	env.dynamic_gi_screen_probe_size = 4
	env.ss_shadow_enabled = false
	we.environment = env
	world.add_child(we)
	make_box(world, Vector3(0, -0.15, 0), Vector3(30, 0.3, 30), Color(0.65, 0.65, 0.65))
	make_box(world, Vector3(-3.5, 2.0, 0), Vector3(0.3, 4, 30), Color(0.7, 0.12, 0.05))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-65, -35, 0)
	sun.light_energy = 2.0
	sun.shadow_enabled = true
	world.add_child(sun)
	car = Node3D.new()
	world.add_child(car)
	if car_scene.is_empty():
		make_box(car, Vector3(0, 0.7, 0), Vector3(2, 0.6, 4.2), Color(0.55, 0.55, 0.55), GeometryInstance3D.GI_MODE_DYNAMIC)
		make_box(car, Vector3(0, 1.2, -0.3), Vector3(1.5, 0.6, 2), Color(0.5, 0.5, 0.5), GeometryInstance3D.GI_MODE_DYNAMIC)
	else:
		var packed := load(car_scene) as PackedScene
		check(packed != null, "Brake authored car loads")
		if not packed:
			quit(1)
			return
		var authored := packed.instantiate()
		strip_gameplay(authored)
		car.add_child(authored)
		var boxes: Array = []
		collect_bounds(authored, Transform3D.IDENTITY, boxes)
		check(not boxes.is_empty(), "Brake authored geometry retained")
		if not boxes.is_empty():
			var merged: AABB = boxes[0]
			for box in boxes: merged = merged.merge(box)
			car_center = merged.get_center()
			car.position.y = -merged.position.y + 0.05
			print("BRAKE_CAR_BOUNDS ", merged)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.look_at_from_position(car.global_position + car_center + camera_offset, car.global_position + car_center)
	camera.current = true
	observer = load(get_script().resource_path.get_base_dir().path_join("observer.gd")).new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [observer]
	camera.compositor = compositor
	for mode in [0, 1]:
		env.dynamic_gi_screen_probe_mode = mode
		await frames(75)
		await capture("mode_%d_still" % mode)
		await frames(4, Vector3(0, 0, -0.75))
		var moving := await capture("mode_%d_moving" % mode, Vector3(0, 0, -0.75))
		await frames(45)
		var settled := await capture("mode_%d_settled" % mode)
		if not moving.is_empty() and not settled.is_empty():
			check(float(moving.gi_mean) > 0.000001, "mode %d moving car receives indirect light" % mode)
			check(float(moving.gi_mean) > float(settled.gi_mean) * 0.4, "mode %d moving GI does not collapse versus settled car" % mode)
		root.msaa_3d = Viewport.MSAA_2X
		await frames(12, Vector3(0.03, 0, 0))
		await capture("mode_%d_msaa_moving" % mode, Vector3(0.03, 0, 0))
		root.msaa_3d = Viewport.MSAA_DISABLED
	root.size = Vector2i(513, 289)
	await frames(8, Vector3(0, 0, 0.04))
	await capture("resized_moving", Vector3(0, 0, 0.04))
	env.dynamic_gi_screen_probes_enabled = false
	await frames(3)
	world.queue_free()
	await frames(4)
	FileAccess.open(out.path_join("measurements.json"), FileAccess.WRITE).store_string(JSON.stringify(results, "\t"))
	print("MOVING_SCENE_RESULT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
