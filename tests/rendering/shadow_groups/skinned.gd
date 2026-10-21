extends SceneTree

var checks := 0
var failures := 0
var out := "user://shadow_groups_skin"

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(out)
	call_deferred("run")

func frames() -> void:
	for frame in 10:
		await process_frame
		await RenderingServer.frame_post_draw

func check(passed: bool, label: String) -> void:
	checks += 1
	print("SHADOW_GROUP_SKIN_OK " if passed else "SHADOW_GROUP_SKIN_FAIL ", label)
	failures += int(not passed)

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var we := WorldEnvironment.new()
	we.environment = Environment.new()
	we.environment.background_mode = Environment.BG_COLOR
	we.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	we.environment.ambient_light_color = Color.WHITE
	we.environment.ambient_light_energy = 0.05
	we.environment.ss_shadow_enabled = false
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 30
	world.add_child(sun)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(12, 12)
	floor_mesh.mesh = plane
	floor_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(floor_mesh)
	var group := Node3D.new()
	group.name = "CharacterScene"
	group.shadow_group_enabled = true
	group.position.y = 1.0
	world.add_child(group)
	var skeleton := Skeleton3D.new()
	skeleton.name = "Rig"
	skeleton.add_bone("root")
	skeleton.set_bone_rest(0, Transform3D.IDENTITY)
	group.add_child(skeleton)
	var shape := BoxMesh.new()
	shape.size = Vector3(0.5, 0.5, 0.5)
	var arrays := shape.surface_get_arrays(0)
	var vertices := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var bones := PackedInt32Array()
	bones.resize(vertices * 4)
	var weights := PackedFloat32Array()
	weights.resize(vertices * 4)
	for vertex in vertices:
		weights[vertex * 4] = 1.0
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var skinned_mesh := ArrayMesh.new()
	skinned_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var model := MeshInstance3D.new()
	model.mesh = skinned_mesh
	model.custom_aabb = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))
	var skin := Skin.new()
	skin.add_bind(0, Transform3D.IDENTITY)
	model.skin = skin
	model.skeleton = NodePath("../Rig")
	group.add_child(model)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.look_at_from_position(Vector3(3.5, 4.5, 6), Vector3(0, 0.3, 0))
	camera.current = true
	var observer = preload("res://observer.gd").new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [observer]
	camera.compositor = compositor
	await frames()
	var before := root.get_texture().get_image()
	before.save_png(out.path_join("rest.png"))
	check(observer.get_snapshot().get("active", false), "skinned mesh uses dedicated atlas")
	var direction := -sun.global_basis.z
	var old_shadow := group.global_position + direction * (-group.global_position.y / direction.y)
	var new_center := group.global_position + Vector3(1.5, 0, 0)
	var new_shadow := new_center + direction * (-new_center.y / direction.y)
	skeleton.set_bone_pose_position(0, Vector3(1.5, 0, 0))
	await frames()
	var after := root.get_texture().get_image()
	after.save_png(out.path_join("posed.png"))
	var old_pixel := Vector2i(camera.unproject_position(old_shadow))
	var new_pixel := Vector2i(camera.unproject_position(new_shadow))
	check(after.get_pixelv(old_pixel).get_luminance() - before.get_pixelv(old_pixel).get_luminance() > 0.2, "old shadow location clears after bone motion")
	check(before.get_pixelv(new_pixel).get_luminance() - after.get_pixelv(new_pixel).get_luminance() > 0.2, "dedicated shadow follows deformed skin")
	group.queue_free()
	await frames()
	check(not observer.get_snapshot().get("active", true), "freeing skinned group releases atlas")
	world.queue_free()
	await frames()
	root.get_texture().get_image()
	print("SHADOW_GROUP_SKIN_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
