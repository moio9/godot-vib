extends SceneTree

const Observer = preload("res://observer.gd")
var checks := 0
var failures := 0
var output := "user://"
var view: Viewport
var world: Node3D
var env: Environment
var probe: ReflectionProbe
var emitter: MeshInstance3D
var emitter_material: StandardMaterial3D
var observer

func check(ok: bool, message: String) -> void:
	checks += 1
	print("HDDAGI_PROBE_OK " if ok else "HDDAGI_PROBE_FAIL ", message)
	if not ok:
		failures += 1

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			output = arg.trim_prefix("--out=").path_join("")
	DirAccess.make_dir_recursive_absolute(output)
	call_deferred("run")

func box(size: Vector3, position: Vector3, color: Color, layers: int, gi_mode: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = position
	node.layers = layers
	node.gi_mode = gi_mode
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.BLACK
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 1.0
	node.material_override = material
	world.add_child(node)
	return node

func capture(label: String, frames := 32) -> Dictionary:
	for frame in frames:
		await process_frame
		await RenderingServer.frame_post_draw
	observer.request_capture()
	await process_frame
	await RenderingServer.frame_post_draw
	await process_frame
	await RenderingServer.frame_post_draw
	var img := view.get_texture().get_image()
	img.save_png(output.path_join(label + ".png"))
	var result: Dictionary = observer.get_observation()
	result["image"] = img
	print("HDDAGI_PROBE_CAPTURE ", label, " color=", average(img), " coverage=", coverage(result))
	return result

func average(img: Image) -> Color:
	var result := Color(0, 0, 0, 0)
	for y in range(120, 144):
		for x in range(112, 144):
			result += img.get_pixel(x, y)
	return result / (24.0 * 32.0)

func coverage(snapshot: Dictionary) -> float:
	if not snapshot.has("blend"):
		return -1.0
	var size: Vector2i = snapshot.size
	var data: PackedFloat32Array = snapshot.blend
	var result := 0.0
	for y in range(120, 144):
		for x in range(112, 144):
			var sx := x * size.x / 256
			var sy := y * size.y / 256
			result += data[sy * size.x + sx]
	return result / (24.0 * 32.0)

func difference(a: Dictionary, b: Dictionary) -> float:
	var ca := average(a.image)
	var cb := average(b.image)
	return (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0

func run() -> void:
	view = root
	world = Node3D.new()
	view.add_child(world)
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.ss_shadow_enabled = false
	env.dynamic_gi_cascades = 1
	env.dynamic_gi_min_cell_size = 0.2
	env.dynamic_gi_read_sky_light = false
	env.dynamic_gi_bounce_feedback = 0.0
	env.dynamic_gi_energy = 1.0
	env.dynamic_gi_filter_probes = false
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees.x = 90.0
	sun.light_energy = 1.0
	sun.light_cull_mask = 3
	sun.layers = 3
	sun.light_indirect_energy = 0.0
	world.add_child(sun)
	var camera := Camera3D.new()
	camera.cull_mask = 1
	world.add_child(camera)
	camera.look_at_from_position(Vector3(0, 3, 4), Vector3.ZERO)
	camera.current = true
	observer = Observer.new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [observer]
	camera.compositor = compositor
	var receiver := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	receiver.mesh = plane
	receiver.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.metallic = 1.0
	material.roughness = 0.0
	material.disable_ambient_light = false
	receiver.material_override = material
	world.add_child(receiver)
	emitter = box(Vector3(8, 6, 1), Vector3(0, 3, -4), Color(0, 1, 0), 1, GeometryInstance3D.GI_MODE_STATIC)
	emitter_material = emitter.material_override
	# Only the ReflectionProbe sees the red enclosure; HDDAGI sees the green wall.
	var enclosure := box(Vector3(40, 40, 40), Vector3.ZERO, Color(1, 0, 0), 2, GeometryInstance3D.GI_MODE_DISABLED)
	(enclosure.material_override as StandardMaterial3D).cull_mode = BaseMaterial3D.CULL_FRONT
	probe = ReflectionProbe.new()
	probe.size = Vector3(20, 20, 20)
	probe.blend_distance = 0.0
	probe.max_distance = 100.0
	probe.cull_mask = 2
	probe.reflection_mask = 1
	probe.position.y = 1.0
	probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
	probe.intensity = 1.0
	probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
	world.add_child(probe)
	var probe_only := await capture("probe_only", 48)
	check(average(probe_only.image).r > 0.1, "ReflectionProbe supplies red reflection without HDDAGI")
	probe.intensity = 0.0
	env.dynamic_gi_enabled = true
	var gi_only := await capture("gi_only", 64)
	check(average(gi_only.image).g > 0.1, "HDDAGI supplies green reflection")
	check(coverage(gi_only) > 0.99, "Reflected wall has full HDDAGI coverage: %f" % coverage(gi_only))
	probe.intensity = 1.0
	var gi_with_probe := await capture("gi_with_probe")
	check(difference(gi_only, gi_with_probe) < 0.01, "Probe preserves valid HDDAGI reflection: delta=%f" % difference(gi_only, gi_with_probe))
	probe.intensity = 2.0
	var gi_with_bright_probe := await capture("gi_with_bright_probe")
	check(difference(gi_only, gi_with_bright_probe) < 0.01, "High probe intensity cannot overwrite covered HDDAGI")
	view.msaa_3d = Viewport.MSAA_8X
	probe.intensity = 0.0
	var msaa_gi := await capture("msaa_gi")
	probe.intensity = 1.0
	var msaa_probe := await capture("msaa_gi_with_probe")
	check(average(msaa_gi.image).g > 0.1 and difference(msaa_gi, msaa_probe) < 0.01, "MSAA preserves HDDAGI priority")
	view.msaa_3d = Viewport.MSAA_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color.a = 0.9
	probe.intensity = 0.0
	var transparent_gi := await capture("transparent_gi")
	probe.intensity = 1.0
	var transparent_probe := await capture("transparent_gi_with_probe")
	check(average(transparent_gi.image).g > 0.01 and difference(transparent_gi, transparent_probe) < 0.01, "Transparent forward GI preserves priority")
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.albedo_color.a = 1.0
	probe.intensity = 1.0
	emitter_material.emission = Color.BLACK
	probe.intensity = 0.0
	env.dynamic_gi_enabled = false
	await process_frame
	await process_frame
	env.dynamic_gi_enabled = true
	var dark_gi := await capture("dark_gi", 64)
	probe.intensity = 1.0
	var dark_with_probe := await capture("dark_with_probe")
	check(coverage(dark_with_probe) > 0.99, "Black reflected surface remains covered")
	check(difference(dark_gi, dark_with_probe) < 0.01, "Valid dark reflection is not mistaken for missing GI")
	emitter.visible = false
	env.dynamic_gi_enabled = false
	await process_frame
	await process_frame
	env.dynamic_gi_enabled = true
	var missing_gi := await capture("missing_gi_with_probe", 64)
	check(coverage(missing_gi) >= 0.0 and coverage(missing_gi) < 0.01, "Removing reflected geometry creates an uncovered ray: %f" % coverage(missing_gi))
	check(difference(probe_only, missing_gi) < 0.02, "Probe fills missing HDDAGI: delta=%f" % difference(probe_only, missing_gi))
	# A ray miss on a slightly rough surface has partial coverage from GI probes.
	material.roughness = 0.15
	probe.intensity = 0.15
	env.dynamic_gi_enabled = false
	var partial_reference := await capture("rough_probe_only")
	emitter.position = Vector3(4, 3, 0)
	emitter.rotation_degrees.y = 90.0
	emitter_material.emission = Color(0, 1, 0)
	emitter.visible = true
	env.dynamic_gi_enabled = true
	probe.intensity = 0.0
	var partial_gi := await capture("partial_gi", 64)
	probe.intensity = 0.15
	var partial_probe := await capture("partial_gi_with_probe")
	var fraction := coverage(partial_probe)
	var gi_color := average(partial_gi.image).srgb_to_linear()
	var probe_color := average(partial_probe.image).srgb_to_linear()
	var reference_color := average(partial_reference.image).srgb_to_linear()
	check(fraction > 0.1 and fraction < 0.9, "Rough reflection has partial HDDAGI coverage: %f" % fraction)
	check(gi_color.g > 0.01 and absf(gi_color.g - probe_color.g) < 0.002, "Partial coverage preserves existing green GI")
	check(absf(probe_color.r - reference_color.r * (1.0 - fraction)) < 0.01, "Probe contributes only the uncovered fraction")
	observer.enabled = false
	camera.compositor = null
	for frame in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	world.queue_free()
	await process_frame
	print("HDDAGI_PROBE_RESULT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
