extends SceneTree

var checks := 0
var failures := 0
var out := "user://shadow_groups"
var world: Node3D
var character: Node3D
var camera: Camera3D
var observer
var meshes: Array[MeshInstance3D] = []
var sun: DirectionalLight3D
var environment: Environment

func check(ok: bool, label: String) -> void:
	checks += 1
	print("SHADOW_GROUP_OK " if ok else "SHADOW_GROUP_FAIL ", label)
	if not ok:
		failures += 1

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(out)
	call_deferred("run")

func frames(count := 5) -> void:
	for frame in count:
		await process_frame
		await RenderingServer.frame_post_draw

func box(parent: Node, pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	mesh.mesh = shape
	mesh.position = pos
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	mesh.material_override = material
	parent.add_child(mesh)
	return mesh

func capture(label: String) -> Image:
	await frames()
	var image := root.get_texture().get_image()
	check(image != null and not image.is_empty(), label + " rendered")
	image.save_png(out.path_join(label + ".png"))
	return image

func difference(a: Image, b: Image) -> float:
	var sum := 0.0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
	return sum / float(a.get_width() * a.get_height() / 4)

func benchmark() -> void:
	var viewport_rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	var results: Array[Dictionary] = []
	for enabled in [false, true, false]:
		character.shadow_group_enabled = enabled
		await frames(40)
		var times: Array[float] = []
		for frame in 120:
			await frames(1)
			var value := RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
			if value > 0.0:
				times.append(value)
		times.sort()
		results.append({"enabled": enabled, "samples": times.size(), "median_gpu_ms": times[times.size() / 2] if not times.is_empty() else 0.0})
	character.shadow_group_enabled = true
	RenderingServer.viewport_set_measure_render_time(viewport_rid, false)
	var file := FileAccess.open(out.path_join("benchmark.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"scope": "synthetic 640x400 scene, 512 map, one group", "results": results}, "  "))
	print("SHADOW_GROUP_BENCHMARK ", JSON.stringify(results))

func set_owners(node: Node, owner_root: Node) -> void:
	for child in node.get_children():
		child.owner = owner_root
		set_owners(child, owner_root)

func run() -> void:
	world = Node3D.new()
	root.add_child(world)
	var we := WorldEnvironment.new()
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.035, 0.045, 0.06)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.08
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.ss_shadow_enabled = false
	we.environment = environment
	world.add_child(we)
	# A non-shadow-casting light before the sun checks directional GPU index mapping.
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.0
	world.add_child(fill)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 80
	sun.shadow_bias = 0.1
	sun.shadow_normal_bias = 2.0
	world.add_child(sun)
	var floor_mesh := box(world, Vector3(0, -0.15, 0), Vector3(40, 0.3, 40), Color(0.65, 0.65, 0.65))
	floor_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	box(world, Vector3(-4, 2, -3), Vector3(0.4, 4, 6), Color(0.32, 0.48, 0.68))
	character = Node3D.new()
	character.name = "CarScene"
	world.add_child(character)
	meshes.append(box(character, Vector3(0, 0.65, 0), Vector3(2.4, 0.3, 4), Color(0.65, 0.12, 0.07)))
	meshes.append(box(character, Vector3(0, 1.7, -0.2), Vector3(2.0, 0.12, 2.5), Color(0.7, 0.18, 0.08)))
	var bridge := Node.new()
	bridge.name = "PlainNodeBridge"
	character.add_child(bridge)
	for x in [-0.9, 0.9]:
		for z in [-1.2, 1.0]:
			meshes.append(box(bridge, Vector3(x, 1.2, z), Vector3(0.08, 1.0, 0.08), Color(0.15, 0.15, 0.15)))
	# Thin pieces cast detail that is below the low-resolution CSM texel size.
	for index in 7:
		meshes.append(box(character, Vector3(-0.75 + index * 0.25, 1.2, 1.5), Vector3(0.035, 0.8, 0.035), Color(0.7, 0.7, 0.7)))
	camera = Camera3D.new()
	world.add_child(camera)
	camera.look_at_from_position(Vector3(5, 4, 7), Vector3(0, 0.7, 0))
	camera.current = true
	observer = preload("res://observer.gd").new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [observer]
	camera.compositor = compositor
	await frames(10)
	check(not observer.get_snapshot().get("active", true), "disabled scene allocates no atlas")
	var baseline := await capture("01_csm")
	character.shadow_group_enabled = true
	for mesh in meshes:
		check(mesh.get_shadow_group_id() == character.get_instance_id(), "descendant joins car scene group: " + str(mesh.position))
	observer.request_depth()
	var grouped := await capture("02_grouped")
	var snap: Dictionary = observer.get_snapshot()
	check(snap.get("active", false), "group atlas allocated")
	check(snap.get("size", Vector2i.ZERO) == Vector2i(2048, 1024), "configured map size")
	check(snap.get("depth_finite", false) and snap.get("occupied", 0) > 30, "real finite shadow depth in first tile")
	check(difference(baseline, grouped) > 0.0005, "dedicated maps visibly change shadow detail")
	var minimum_roof_ratio := 1.0
	for x in 7:
		for z in 7:
			var pixel := Vector2i(camera.unproject_position(Vector3(-0.6 + x * 0.2, 1.761, -0.8 + z * 0.2)))
			var original := baseline.get_pixelv(pixel).get_luminance()
			if original > 0.05:
				minimum_roof_ratio = minf(minimum_roof_ratio, grouped.get_pixelv(pixel).get_luminance() / original)
	check(minimum_roof_ratio > 0.95, "unoccluded roof stays lit without self-shadow stripes")
	if OS.get_cmdline_user_args().has("--bench"):
		await benchmark()
	# Save and instantiate a real car scene; each instance gets its own group.
	set_owners(character, character)
	var packed := PackedScene.new()
	check(packed.pack(character) == OK, "car scene packs")
	check(ResourceSaver.save(packed, out.path_join("car_scene.tscn")) == OK, "car scene saves")
	var saved := load(out.path_join("car_scene.tscn")) as PackedScene
	var copy := saved.instantiate() as Node3D
	check(copy.shadow_group_enabled, "scene root property survives serialization")
	check((copy.get_child(0) as Node3D).get_shadow_group_id() == copy.get_instance_id() and copy.get_instance_id() != character.get_instance_id(), "new scene instance has independent group ID")
	copy.free()
	# Nested roots create independent groups, and disabling restores the ancestor.
	var nested := Node3D.new()
	character.add_child(nested)
	nested.shadow_group_enabled = true
	meshes[0].reparent(nested)
	check(meshes[0].get_shadow_group_id() == nested.get_instance_id(), "reparent joins nested group")
	nested.shadow_group_enabled = false
	check(meshes[0].get_shadow_group_id() == character.get_instance_id(), "nested disable restores car group")
	var extra := box(character, Vector3(1.5, 1, 0), Vector3(0.1, 0.1, 0.5), Color.WHITE)
	check(extra.get_shadow_group_id() == character.get_instance_id(), "runtime child joins existing group")
	extra.queue_free()
	await frames()
	character.shadow_group_enabled = false
	var restored := await capture("03_restored")
	check(not observer.get_snapshot().get("active", true), "disabling last group releases atlas")
	check(difference(baseline, restored) < 0.00001, "CSM restored exactly after toggle and reparent")
	character.shadow_group_enabled = true
	# Ordinary caster off must also remove it from the dedicated map.
	for mesh in meshes:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await frames()
	check(not observer.get_snapshot().get("active", true), "all caster flags off releases atlas")
	for mesh in meshes:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	character.hide()
	# Plain Node containers intentionally interrupt Godot visibility inheritance.
	for mesh in meshes:
		mesh.hide()
	await frames()
	check(not observer.get_snapshot().get("active", true), "hidden scene releases atlas")
	character.show()
	for mesh in meshes:
		mesh.show()
	ProjectSettings.set_setting("rendering/lights_and_shadows/shadow_groups/map_size", 1024)
	await frames()
	check(observer.get_snapshot().get("size", Vector2i.ZERO) == Vector2i(4096, 2048), "runtime map resize")
	ProjectSettings.set_setting("rendering/lights_and_shadows/shadow_groups/map_size", 512)
	character.position += Vector3(1, 0, 0)
	character.rotation.y = 0.35
	root.size = Vector2i(653, 411)
	await capture("04_moved_resized")
	# Over-capacity groups keep their normal CSM shadows.
	var crowd: Array[Node3D] = []
	for index in 10:
		var group := Node3D.new()
		world.add_child(group)
		group.position = Vector3(-5 + index, 0, -4)
		group.shadow_group_enabled = true
		box(group, Vector3(0, 0.5, 0), Vector3(0.4, 1, 0.4), Color(0.8, 0.6, 0.1))
		crowd.append(group)
	await capture("05_capacity_fallback")
	for group in crowd:
		group.queue_free()
	await frames()
	# Separate viewport gets its own atlas, without corrupting the main camera.
	var viewport := SubViewport.new()
	viewport.size = Vector2i(253, 157)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	world.add_child(viewport)
	var second_camera := Camera3D.new()
	viewport.add_child(second_camera)
	second_camera.look_at_from_position(Vector3(-7, 5, 8), Vector3(0, 1, 0))
	second_camera.current = true
	await frames(10)
	check(not viewport.get_texture().get_image().is_empty(), "second viewport renders")
	await capture("06_two_viewports")
	viewport.queue_free()
	await frames()
	sun.shadow_enabled = false
	await frames()
	check(not observer.get_snapshot().get("active", true), "sun shadows disabled releases atlas")
	sun.shadow_enabled = true
	await frames()
	check(observer.get_snapshot().get("active", false), "sun shadows restored recreates atlas")
	# Off-screen caster, visible projected shadow: use only this group's map.
	character.shadow_group_enabled = false
	var offscreen := Node3D.new()
	world.add_child(offscreen)
	offscreen.position = Vector3(12, 6, 0)
	offscreen.shadow_group_enabled = true
	box(offscreen, Vector3.ZERO, Vector3(0.5, 0.5, 0.5), Color.WHITE)
	var direction := -sun.global_basis.z
	var ground_point := offscreen.global_position + direction * (-offscreen.global_position.y / direction.y)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.look_at_from_position(ground_point + Vector3.UP * 15, ground_point, Vector3.FORWARD)
	await frames()
	check(not camera.is_position_in_frustum(offscreen.global_position), "caster is outside camera frustum")
	check(observer.get_snapshot().get("active", false), "off-screen caster's projected shadow keeps group active")
	var offscreen_shadow := await capture("07_offscreen_shadow")
	sun.shadow_enabled = false
	var no_shadow := await capture("08_offscreen_without_shadow")
	var center := Vector2i(offscreen_shadow.get_width() / 2, offscreen_shadow.get_height() / 2)
	check(no_shadow.get_pixelv(center).get_luminance() - offscreen_shadow.get_pixelv(center).get_luminance() > 0.15, "dedicated off-screen caster shadows visible ground")
	world.queue_free()
	await frames()
	root.get_texture().get_image()
	print("SHADOW_GROUP_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
