extends CompositorEffect
var mutex := Mutex.new()
var requested := false
var observation: Dictionary = {}
var signal_name := &"output"
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
func _render_callback(_type: int, data: RenderData) -> void:
	mutex.lock()
	var capture := requested
	requested = false
	mutex.unlock()
	if not capture: return
	var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
	if not buffers or not buffers.has_texture(&"hddagi_screen_probe_denoiser", &"output"): return
	var rd := RenderingServer.get_rendering_device()
	var has_metadata := buffers.has_texture(&"hddagi_surface_history", &"surface_motion")
	var size := buffers.get_internal_size()
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = """#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(set=0,binding=0) uniform texture2D gi_output;
layout(set=0,binding=1) uniform texture2D normal_input;
layout(set=0,binding=2) uniform utexture2D surface_input;
layout(set=0,binding=3) uniform sampler nearest_sampler;
layout(set=0,binding=4,std430) buffer Output { uint values[]; } output_data;
layout(push_constant,std430) uniform Params { ivec2 size; } params;
void main() {
 ivec2 p=ivec2(gl_GlobalInvocationID.xy);
 if(any(greaterThanEqual(p,params.size))) return;
 ivec2 gi_size=textureSize(sampler2D(gi_output,nearest_sampler),0);
 ivec2 gp=clamp(p*gi_size/params.size,ivec2(0),gi_size-1);
 vec3 gi=texelFetch(sampler2D(gi_output,nearest_sampler),gp,0).rgb;
 float dynamic=texelFetch(sampler2D(normal_input,nearest_sampler),p,0).a;
 ivec2 ms=textureSize(usampler2D(surface_input,nearest_sampler),0);
 uvec2 surface=texelFetch(usampler2D(surface_input,nearest_sampler),clamp(p,ivec2(0),ms-1),0).xy;
 int index=(p.y*params.size.x+p.x)*6;
 output_data.values[index]=surface.y;
 output_data.values[index+1]=surface.x;
 output_data.values[index+2]=floatBitsToUint(gi.r);
 output_data.values[index+3]=floatBitsToUint(gi.g);
 output_data.values[index+4]=floatBitsToUint(gi.b);
 output_data.values[index+5]=floatBitsToUint(dynamic);
}
"""
	var shader := rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(shader_source))
	var pipeline := rd.compute_pipeline_create(shader)
	var sampler := rd.sampler_create(RDSamplerState.new())
	var output := rd.storage_buffer_create(size.x * size.y * 24)
	var fallback := RID()
	var metadata := RID()
	if has_metadata:
		metadata = buffers.get_texture_slice(&"hddagi_surface_history", &"surface_motion", 0, 0, 1, 1)
	else:
		var format := RDTextureFormat.new()
		format.width = 1
		format.height = 1
		format.format = RenderingDevice.DATA_FORMAT_R32G32_UINT
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		fallback = rd.texture_create(format, RDTextureView.new(), [PackedInt32Array([0, 0]).to_byte_array()])
		metadata = fallback
	var uniforms: Array[RDUniform] = []
	var rids := [buffers.get_texture_slice(&"hddagi_screen_probe_denoiser", signal_name, 0, 0, 1, 1), buffers.get_texture_slice(&"forward_clustered", &"normal_roughness", 0, 0, 1, 1), metadata, sampler, output]
	for binding in 5:
		var u := RDUniform.new()
		u.binding = binding
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE if binding < 3 else (RenderingDevice.UNIFORM_TYPE_SAMPLER if binding == 3 else RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)
		u.add_id(rids[binding])
		uniforms.append(u)
	var set_rid := rd.uniform_set_create(uniforms, shader, 0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set_rid, 0)
	rd.compute_list_set_push_constant(list, PackedInt32Array([size.x, size.y]).to_byte_array(), 8)
	rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	rd.compute_list_end()
	var bytes := rd.buffer_get_data(output)
	var result := {"size": size, "metadata": has_metadata, "integers": bytes.to_int32_array(), "floats": bytes.to_float32_array()}
	for rid in [set_rid, output, sampler, pipeline, shader, fallback]:
		if rid.is_valid(): rd.free_rid(rid)
	mutex.lock()
	observation = result
	mutex.unlock()
