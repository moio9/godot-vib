extends Node3D
var checks := 0
var failures := 0
func check_result(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("LIFECYCLE_FAIL " + message)
func settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
func make_world(parent: Node) -> void:
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.ss_shadow_enabled = false
	parent.add_child(world)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1, 4)
	parent.add_child(camera)
	camera.current = true
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	parent.add_child(box)
func _ready() -> void:
	make_world(self)
	var area := AreaLight3D.new()
	area.position = Vector3(0, 2, 2)
	add_child(area)
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_AREA_LIGHT_ATLAS
	var textures: Array[ImageTexture] = []
	for format in [Image.FORMAT_L8, Image.FORMAT_RGBA8, Image.FORMAT_RGBAH]:
		var image := Image.create(32, 32, false, format)
		image.fill(Color(0.8, 0.8, 0.8))
		var texture := ImageTexture.create_from_image(image)
		textures.append(texture)
		area.area_texture = texture
		await settle(4)
		var atlas := get_viewport().get_texture().get_image()
		var peak := 0.0
		for y in range(0, atlas.get_height() / 2, 2):
			for x in range(0, atlas.get_width() / 2, 2):
				peak = maxf(peak, atlas.get_pixel(x, y).r)
		check_result(peak > 0.4, "AreaLight atlas must contain the texture: format=%d peak=%f" % [format, peak])
		print("LIFECYCLE_AREA_TEXTURE format=", format, " peak=", peak)
	get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	for cycle in 3:
		var other := SubViewport.new()
		other.size = Vector2i(320, 180)
		other.own_world_3d = true
		other.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(other)
		make_world(other)
		var probe := ReflectionProbe.new()
		probe.size = Vector3(10, 10, 10)
		probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
		other.add_child(probe)
		await settle(10)
		print("LIFECYCLE_REFLECTION_RELEASE cycle=", cycle)
		other.queue_free()
		await settle(2)
	check_result(RenderingServer.get_current_rendering_method() == "forward_plus", "Forward+ required")
	print("LIFECYCLE_RESULT checks=", checks, " failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)
