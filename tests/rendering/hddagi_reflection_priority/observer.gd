extends CompositorEffect

var mutex := Mutex.new()
var requested := false
var observation: Dictionary = {}

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT

func request_capture() -> void:
	mutex.lock()
	requested = true
	observation = {}
	mutex.unlock()

func get_observation() -> Dictionary:
	mutex.lock()
	var result := observation.duplicate()
	mutex.unlock()
	return result

func _render_callback(_type: int, render_data: RenderData) -> void:
	mutex.lock()
	var capture := requested
	requested = false
	mutex.unlock()
	if not capture:
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var result := {}
	if buffers and buffers.has_texture(&"rbgi", &"ambient_reflection_blend"):
		var format := buffers.get_texture_format(&"rbgi", &"ambient_reflection_blend")
		# Copy coverage through a compute buffer: the GI image has storage usage,
		# but intentionally need not permit texture transfer/readback.
		var rd := RenderingServer.get_rendering_device()
		var source := RDShaderSource.new()
		source.source_compute = """#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(set=0, binding=0, rg8) uniform readonly image2D coverage_image;
layout(set=0, binding=1, std430) buffer Output { float coverage[]; } output_data;
void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(coverage_image);
    if (any(greaterThanEqual(p, size))) return;
    output_data.coverage[p.y * size.x + p.x] = imageLoad(coverage_image, p).g;
}
"""
		var shader := rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(source))
		var pipeline := rd.compute_pipeline_create(shader)
		var output_buffer := rd.storage_buffer_create(format.width * format.height * 4)
		var input_uniform := RDUniform.new()
		input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		input_uniform.binding = 0
		input_uniform.add_id(buffers.get_texture(&"rbgi", &"ambient_reflection_blend"))
		var output_uniform := RDUniform.new()
		output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		output_uniform.binding = 1
		output_uniform.add_id(output_buffer)
		var uniforms := rd.uniform_set_create([input_uniform, output_uniform], shader, 0)
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, uniforms, 0)
		rd.compute_list_dispatch(list, ceili(format.width / 8.0), ceili(format.height / 8.0), 1)
		rd.compute_list_end()
		result = {"size": Vector2i(format.width, format.height),
			"blend": rd.buffer_get_data(output_buffer).to_float32_array()}
		rd.free_rid(uniforms)
		rd.free_rid(output_buffer)
		rd.free_rid(pipeline)
		rd.free_rid(shader)
	mutex.lock()
	observation = result
	mutex.unlock()
