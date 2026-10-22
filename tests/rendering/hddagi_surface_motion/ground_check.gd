extends "res://scene_check.gd"

func ground_sample(info: Dictionary, point: Vector3) -> float:
	var size: Vector2i = info.size
	var floats: PackedFloat32Array = info.floats
	var ids: PackedInt32Array = info.integers
	var minimum := Vector2(size)
	var maximum := Vector2.ZERO
	for x in [-0.5, 0.5]:
		for z in [-0.35, 0.35]:
			var pixel := camera.unproject_position(point + Vector3(x, 0, z))
			minimum = minimum.min(pixel)
			maximum = maximum.max(pixel)
	var roi := Rect2i(Vector2i(minimum), Vector2i(maximum - minimum)).intersection(Rect2i(Vector2i.ZERO, size))
	var sum := 0.0
	var count := 0
	for y in range(roi.position.y, roi.end.y):
		for x in range(roi.position.x, roi.end.x):
			var i := (y * size.x + x) * 6
			if ids[i] != 1: continue
			sum += floats[i+2]
			count += 1
	check(count > 10, "sample actual floor separately from emissive car")
	return sum / maxi(count, 1)

func snapshot(label: String) -> Dictionary:
	observer.request_capture()
	await frames(1)
	var info: Dictionary = observer.get_observation()
	check(not info.is_empty(), label + " reads GI output")
	root.get_texture().get_image().save_png(out.path_join(label + ".png"))
	var result := {"label": label, "old": ground_sample(info, Vector3(-2, 0.001, 1.8)), "new": ground_sample(info, Vector3(2, 0.001, 1.8))}
	results.append(result)
	print("GROUND_TRANSFER_SAMPLE ", JSON.stringify(result))
	return result

func run() -> void:
	root.size = Vector2i(640, 360)
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_denoiser", 1)
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_detail_trace", true)
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_candidate_count", 8)
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_radiance_cache", 1)
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_radiance_cache_multibounce", true)
	world = Node3D.new()
	root.add_child(world)
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.dynamic_gi_enabled = true
	env.dynamic_gi_cascades = 1
	env.dynamic_gi_min_cell_size = 0.2
	env.dynamic_gi_read_sky_light = false
	env.dynamic_gi_screen_probes_enabled = true
	env.dynamic_gi_screen_probe_mode = 0
	env.dynamic_gi_screen_probe_size = 2
	env.ss_shadow_enabled = false
	we.environment = env
	world.add_child(we)
	make_box(world, Vector3(0,-0.15,0), Vector3(24,0.3,24), Color.WHITE)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60,-30,0)
	sun.light_energy = 0.001
	sun.light_indirect_energy = 0.0
	world.add_child(sun)
	car = Node3D.new()
	car.position.x = -2
	world.add_child(car)
	var body := make_box(car, Vector3(0,0.7,0), Vector3(1.2,0.9,2.4), Color.RED, GeometryInstance3D.GI_MODE_DYNAMIC)
	var material := body.material_override as StandardMaterial3D
	material.emission_enabled = true
	material.emission = Color(8,0,0)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.look_at_from_position(Vector3(3.5,3,7), Vector3(0,0.4,0))
	camera.current = true
	observer = preload("res://observer.gd").new()
	if OS.get_cmdline_user_args().has("--raw"): observer.signal_name = &"input"
	var compositor := Compositor.new()
	compositor.compositor_effects = [observer]
	camera.compositor = compositor
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_directional_screen_radiance", false)
	await frames(60)
	var disabled := await snapshot("01_screen_radiance_off")
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_directional_screen_radiance", true)
	await frames(60)
	var stationary := await snapshot("02_stationary")
	if not baseline:
		check(stationary.old > 0.0000001 and stationary.old > disabled.old * 3.0 + 0.0000001, "dynamic car contributes GI to stationary ground in Stochastic mode")
	car.position.x = 2
	var moved := await snapshot("03_first_moving_frame")
	await frames(45)
	var settled := await snapshot("04_settled")
	if not baseline:
		check(moved.old < stationary.old * 0.25 + 0.0000001, "old ground lighting clears on first moving frame")
		check(moved.new > settled.new * 0.15 and moved.new > 0.0000001, "ground lighting follows moving source instead of staying at old position")
		check(settled.old < stationary.old * 0.10 + 0.0000001, "no persistent baked or temporal light remains at old position")
	root.msaa_3d = Viewport.MSAA_2X
	await frames(10, Vector3(-0.04,0,0))
	await snapshot("05_msaa_moving")
	root.msaa_3d = Viewport.MSAA_DISABLED
	# Isolate indirect occlusion from source color and ordinary shadow maps.
	material.emission_enabled = false
	material.albedo_color = Color.BLACK
	env.background_color = Color.WHITE
	env.dynamic_gi_read_sky_light = true
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_directional_screen_radiance", false)
	car.position.x = -2
	await frames(90)
	var occluded := await snapshot("06_indirect_occlusion")
	car.position.x = 2
	var moved_occlusion := await snapshot("07_indirect_occlusion_moving")
	await frames(45)
	var settled_occlusion := await snapshot("08_indirect_occlusion_settled")
	if not baseline:
		check(occluded.old < occluded.new * 0.95, "opaque unvoxelized car blocks sky radiance on nearby ground")
		check(moved_occlusion.old > occluded.old + (occluded.new - occluded.old) * 0.65, "indirect ground shadow clears its previous position immediately")
		check(moved_occlusion.new < occluded.new * 0.95, "indirect ground shadow moves with the car")
		check(settled_occlusion.old > occluded.old + (occluded.new - occluded.old) * 0.80, "no persistent indirect shadow remains behind the car")
	# Exercise the new trace descriptors without SVGF as their allocator.
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_directional_screen_radiance", true)
	ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_denoiser", 0)
	await frames(5, Vector3(-0.04,0,0))
	check(not root.get_texture().get_image().is_empty(), "screen radiance renders without SVGF")
	world.queue_free()
	await frames(4)
	FileAccess.open(out.path_join("measurements.json"), FileAccess.WRITE).store_string(JSON.stringify(results, "\t"))
	print("GROUND_TRANSFER_RESULT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
