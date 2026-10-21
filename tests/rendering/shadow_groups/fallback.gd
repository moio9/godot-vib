extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func frames() -> void:
	for frame in 6:
		await process_frame
		await RenderingServer.frame_post_draw

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.1, 0.1, 0.1)
	world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	world.add_child(sun)
	var group := Node3D.new()
	world.add_child(group)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.position.y = 0.5
	group.add_child(box)
	var floor_mesh := MeshInstance3D.new()
	var shape := PlaneMesh.new()
	shape.size = Vector2(10, 10)
	floor_mesh.mesh = shape
	world.add_child(floor_mesh)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.look_at_from_position(Vector3(3, 3, 5), Vector3.ZERO)
	camera.current = true
	await frames()
	var before := root.get_texture().get_image()
	group.shadow_group_enabled = true
	await frames()
	var after := root.get_texture().get_image()
	var passed: bool = before.get_data() == after.get_data() and box.get_shadow_group_id() == group.get_instance_id()
	world.queue_free()
	await frames()
	root.get_texture().get_image()
	print("SHADOW_GROUP_FALLBACK_RESULT checks=2 failures=", 0 if passed else 1)
	quit(0 if passed else 1)
