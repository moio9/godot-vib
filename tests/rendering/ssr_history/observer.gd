extends CompositorEffect

var observation: Dictionary = {}
var observation_mutex := Mutex.new()

func _init() -> void:
    effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT

func _render_callback(_callback_type: int, render_data: RenderData) -> void:
    var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
    if buffers and buffers.has_texture(&"rb_sslf", &"last_frame"):
        var format := buffers.get_texture_format(&"rb_sslf", &"last_frame")
        observation_mutex.lock()
        observation = {"width": format.width, "height": format.height, "mipmaps": format.mipmaps}
        observation_mutex.unlock()

func get_observation() -> Dictionary:
    observation_mutex.lock()
    var result := observation.duplicate()
    observation_mutex.unlock()
    return result
