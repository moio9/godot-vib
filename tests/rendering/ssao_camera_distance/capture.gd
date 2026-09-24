extends Node3D


func _ready() -> void:
	var output_dir := ""
	var algorithm := -1
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			output_dir = argument.trim_prefix("--capture-dir=")
		elif argument.begins_with("--algorithm="):
			algorithm = int(argument.trim_prefix("--algorithm="))
	if output_dir.is_empty():
		return
	if algorithm >= 0:
		$WorldEnvironment.environment.ssao_algorithm = algorithm

	var error := DirAccess.make_dir_recursive_absolute(output_dir)
	if error != OK:
		push_error("Could not create capture directory: %s" % output_dir)
		get_tree().quit(1)
		return

	var camera: Camera3D = $Camera3D
	var viewport := get_viewport()
	var distances := [3.0, 8.0, 16.0]
	for distance in distances:
		camera.position = Vector3(0.0, 1.4 + distance * 0.1, distance)
		camera.look_at(Vector3(0.0, 0.7, 0.0))
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var label := str(int(distance))
		error = viewport.get_texture().get_image().save_png(output_dir.path_join("scene_%s.png" % label))
		if error != OK:
			push_error("Could not save scene capture at %s m" % label)
			get_tree().quit(1)
			return

		viewport.debug_draw = Viewport.DEBUG_DRAW_SSAO
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		error = viewport.get_texture().get_image().save_png(output_dir.path_join("ssao_%s.png" % label))
		if error != OK:
			push_error("Could not save SSAO capture at %s m" % label)
			get_tree().quit(1)
			return
		viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED

	get_tree().quit()
