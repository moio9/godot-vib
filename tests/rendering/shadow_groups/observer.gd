extends CompositorEffect

var mutex := Mutex.new()
var snapshot: Dictionary = {}
var read_requested := false

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT

func request_depth() -> void:
	mutex.lock()
	read_requested = true
	mutex.unlock()

func _render_callback(_type: int, render_data: RenderData) -> void:
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var active := buffers != null and buffers.has_texture(&"shadow_groups", &"atlas")
	var result := {"active": active}
	mutex.lock()
	var read := read_requested
	read_requested = false
	mutex.unlock()
	if active:
		var rd := RenderingServer.get_rendering_device()
		var texture := buffers.get_texture(&"shadow_groups", &"atlas")
		var format := rd.texture_get_format(texture)
		result["size"] = Vector2i(format.width, format.height)
		if read:
			var depth := rd.texture_get_data(texture, 0).to_float32_array()
			var occupied := 0
			var finite := true
			# Inspect the first allocated tile; the unused tiles are not sampled.
			for y in range(0, format.height / 2, 7):
				for x in range(0, format.width / 4, 7):
					var value := depth[y * format.width + x]
					finite = finite and is_finite(value)
					occupied += int(value > 0.0)
			result["depth_finite"] = finite
			result["occupied"] = occupied
	mutex.lock()
	if result.has("occupied"):
		snapshot = result
	else:
		var saved_occupied: int = snapshot.get("occupied", -1)
		var saved_finite: bool = snapshot.get("depth_finite", false)
		snapshot = result
		if saved_occupied >= 0:
			snapshot["occupied"] = saved_occupied
			snapshot["depth_finite"] = saved_finite
	mutex.unlock()

func get_snapshot() -> Dictionary:
	mutex.lock()
	var result := snapshot.duplicate()
	mutex.unlock()
	return result
