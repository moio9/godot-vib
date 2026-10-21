extends CompositorEffect

var mutex := Mutex.new()
var active := false

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT

func _render_callback(_type: int, render_data: RenderData) -> void:
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var valid := buffers != null and buffers.has_texture(&"hddagi_screen_probe_denoiser", &"output")
	mutex.lock()
	active = valid
	mutex.unlock()

func is_active() -> bool:
	mutex.lock()
	var result := active
	mutex.unlock()
	return result
