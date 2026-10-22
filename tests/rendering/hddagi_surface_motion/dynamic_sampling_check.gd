extends SceneTree

const SIZE := Vector2i(65, 65)
const PREFIX := "rendering/global_illumination/hddagi/"
var checks := 0
var failures := 0
var out := "user://"
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var sampler: RID
var measurements: Array = []
var world: Node3D
var car: Node3D
var camera: Camera3D
var budget_observer: BudgetObserver

class BudgetObserver extends CompositorEffect:
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

	func _render_callback(_type: int, data: RenderData) -> void:
		mutex.lock()
		var capture := requested
		requested = false
		mutex.unlock()
		if not capture: return
		var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
		if not buffers or not buffers.has_texture(&"hddagi_screen_probe_debug", &"trace_debug") or not buffers.has_texture(&"hddagi_surface_history", &"surface_motion"):
			return
		var device := RenderingServer.get_rendering_device()
		var format := buffers.get_texture_format(&"hddagi_screen_probe_debug", &"trace_debug")
		var size := Vector2i(format.width, format.height)
		var source := RDShaderSource.new()
		source.source_compute = """#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0) uniform utexture2D debug_input;
layout(set=0,binding=1) uniform utexture2D surface_input;
layout(set=0,binding=2) uniform texture2D normal_input;
layout(set=0,binding=3) uniform utexture2D identity_input;
layout(set=0,binding=4) uniform sampler point_sampler;
layout(set=0,binding=5,std430) buffer Output {uint value[];} result;
layout(push_constant,std430) uniform Params {ivec2 size;} params;
void main() {
 ivec2 p=ivec2(gl_GlobalInvocationID.xy);
 if(any(greaterThanEqual(p,params.size))) return;
 uvec4 surface=texelFetch(usampler2D(surface_input,point_sampler),p,0);
 int index=(p.y*params.size.x+p.x)*5;
 result.value[index]=texelFetch(usampler2D(debug_input,point_sampler),p,0).r;
 result.value[index+1]=surface.x;
 result.value[index+2]=surface.y;
 result.value[index+3]=0u;
 result.value[index+4]=0u;
 ivec2 position=ivec2(surface.xy);
 ivec2 full_size=textureSize(sampler2D(normal_input,point_sampler),0);
 if(any(lessThan(position,ivec2(0)))||any(greaterThanEqual(position,full_size))) return;
 result.value[index+3]=texelFetch(usampler2D(identity_input,point_sampler),position,0).y;
 result.value[index+4]=texelFetch(sampler2D(normal_input,point_sampler),position,0).a>0.5?1u:0u;
}
"""
		var shader_rid := device.shader_create_from_spirv(device.shader_compile_spirv_from_source(source))
		var pipeline_rid := device.compute_pipeline_create(shader_rid)
		var sampler_rid := device.sampler_create(RDSamplerState.new())
		var output := device.storage_buffer_create(size.x * size.y * 20)
		var textures := [
			buffers.get_texture_slice(&"hddagi_screen_probe_debug", &"trace_debug", 0, 0, 1, 1),
			buffers.get_texture_slice(&"hddagi_screen_probes", &"screen_probe_surface", 0, 0, 1, 1),
			buffers.get_texture_slice(&"forward_clustered", &"normal_roughness", 0, 0, 1, 1),
			buffers.get_texture_slice(&"hddagi_surface_history", &"surface_motion", 0, 0, 1, 1), sampler_rid, output,
		]
		var uniforms: Array[RDUniform] = []
		for binding in 6:
			var entry := RDUniform.new()
			entry.binding = binding
			entry.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE if binding < 4 else (RenderingDevice.UNIFORM_TYPE_SAMPLER if binding == 4 else RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)
			entry.add_id(textures[binding])
			uniforms.append(entry)
		var set_rid := device.uniform_set_create(uniforms, shader_rid, 0)
		var list := device.compute_list_begin()
		device.compute_list_bind_compute_pipeline(list, pipeline_rid)
		device.compute_list_bind_uniform_set(list, set_rid, 0)
		device.compute_list_set_push_constant(list, PackedInt32Array([size.x, size.y]).to_byte_array(), 8)
		device.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		device.compute_list_end()
		var values := device.buffer_get_data(output).to_int32_array()
		for resource in [set_rid, output, sampler_rid, pipeline_rid, shader_rid]: device.free_rid(resource)
		mutex.lock()
		observation = {"size": size, "values": values}
		mutex.unlock()

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(out)
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("DYNAMIC_SAMPLING_OK " if ok else "DYNAMIC_SAMPLING_FAIL ", message)

func uniform(kind: int, binding: int, resource: RID) -> RDUniform:
	var value := RDUniform.new()
	value.uniform_type = kind
	value.binding = binding
	value.add_id(resource)
	return value

func function_source(source: String, signature: String) -> String:
	var begin := source.find(signature)
	if begin < 0:
		return ""
	var brace := source.find("{", begin)
	var depth := 1
	var end := brace + 1
	while end < source.length() and depth > 0:
		if source[end] == "{": depth += 1
		if source[end] == "}": depth -= 1
		end += 1
	return source.substr(begin, end - begin)

func helper_shader_source() -> String:
	var directory := ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/shaders/environment/")
	var production := FileAccess.get_file_as_string(directory.path_join("hddagi_screen_probe.glsl"))
	var push_begin := production.find("layout(push_constant, std430) uniform Params {")
	var push_end := production.find("params;", push_begin) + "params;".length()
	var push := production.substr(push_begin, push_end - push_begin)
	var seed_code := function_source(production, "uint hash_uvec3(") + "\nconst uvec2 R2_WEYL_INCREMENT = uvec2(3242174889u, 2447445413u);\n"
	seed_code += function_source(production, "float uint_to_unit_float(") + "\n" + function_source(production, "vec2 sample_temporally_permuted_r2_sequence(")
	return """#version 450
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
const uint SCREEN_PROBE_FLAG_DYNAMIC_SAMPLING=1u<<10u;
const uint SCREEN_PROBE_FLAG_DYNAMIC_SAMPLING_HISTORY_VALID=1u<<11u;
layout(set=0,binding=0) uniform texture2D detail_hiz_buffer;
layout(set=0,binding=1) uniform texture2D detail_normal_roughness_buffer;
layout(set=0,binding=2) uniform texture2D dynamic_previous_signal_input;
layout(set=0,binding=3) uniform utexture2D directional_surface_history;
layout(set=0,binding=4) uniform utexture2D directional_previous_surface_history;
layout(set=0,binding=5) uniform texture2D directional_previous_depth_buffer;
layout(set=0,binding=6) uniform sampler linear_sampler;
layout(set=0,binding=7,std430) buffer Results {uint value[];} results;
layout(set=1,binding=0,std140) uniform SceneData {
 mat4 inv_projection[2];
 mat4 cam_transform;
 mat4 previous_cam_inv_transform;
 mat4 previous_projection[2];
 mat4 previous_inv_projection[2];
 mat4 projection[2];
} scene_data;
""" + push + "\n" + seed_code + "\n" + FileAccess.get_file_as_string(directory.path_join("hddagi_surface_history_inc.glsl")) + "\n" + FileAccess.get_file_as_string(directory.path_join("hddagi_screen_probe_dynamic_sampling_inc.glsl")) + """
void main() {
 ivec2 origin=params.screen_size/2;
 float depth=texelFetch(sampler2D(detail_hiz_buffer,linear_sampler),origin,0).r;
 results.value[0]=stochastic_dynamic_candidate_count(origin,depth,params.candidate_count);
 for(uint candidate=0u;candidate<8u;candidate++) {
  vec2 sample_value=stochastic_dynamic_candidate_sample(uvec2(3,5),candidate,params.candidate_count);
  vec2 legacy=sample_temporally_permuted_r2_sequence(uvec2(3,5),params.frame_index*params.candidate_count+candidate,0x44544330u);
  results.value[1u+candidate*2u]=floatBitsToUint(sample_value.x);
  results.value[2u+candidate*2u]=floatBitsToUint(sample_value.y);
  results.value[17u+candidate*2u]=floatBitsToUint(legacy.x);
  results.value[18u+candidate*2u]=floatBitsToUint(legacy.y);
 }
}
"""

func float_texture(format: int, color: Color, modifier := Callable(), size := SIZE) -> RID:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RF if format == RenderingDevice.DATA_FORMAT_R32_SFLOAT else Image.FORMAT_RGBAF)
	image.fill(color)
	if modifier.is_valid():
		for y in size.y:
			for x in size.x:
				image.set_pixel(x, y, modifier.call(x, y, color))
	var texture_format := RDTextureFormat.new()
	texture_format.width = size.x
	texture_format.height = size.y
	texture_format.format = format
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(texture_format, RDTextureView.new(), [image.get_data()])

func metadata_texture(depth: float, identity: int, size := SIZE) -> RID:
	var data := PackedByteArray()
	data.resize(size.x * size.y * 8)
	for i in size.x * size.y:
		data.encode_float(i * 8, depth)
		data.encode_u32(i * 8 + 4, identity)
	var texture_format := RDTextureFormat.new()
	texture_format.width = size.x
	texture_format.height = size.y
	texture_format.format = RenderingDevice.DATA_FORMAT_R32G32_UINT
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(texture_format, RDTextureView.new(), [data])

func append_matrix(data: PackedFloat32Array, matrix: Projection) -> void:
	for column in 4:
		for row in 4:
			data.append(matrix[column][row])

func raster_depth(projection: Projection, distance: float) -> float:
	var clip := projection * Vector4(0, 0, -distance, 1)
	return clip.z / clip.w

func dispatch(kind: String, orthographic := false, base := 2, target := 4, frame := 17) -> PackedInt32Array:
	var projection := Projection.create_depth_correction(true) * (Projection.create_orthogonal(-6, 6, -6, 6, 0.1, 100) if orthographic else Projection.create_perspective(70, 1, 0.1, 100))
	var distance := 40.0 if kind == "far" else (27.5 if kind == "fade" else 5.0)
	var depth := raster_depth(projection, distance)
	if kind == "invalid_depth": depth = NAN
	var flags := (1 << 10) | (1 << 11)
	if kind == "disabled": flags &= ~(1 << 10)
	if kind == "history_no_flag": flags &= ~(1 << 11)
	var normal_size := Vector2i(32, 32) if kind == "normal_size" else SIZE
	var dynamic_receiver := kind in ["dynamic", "far", "fade", "disabled", "target", "radius_invalid", "radius_zero_dynamic", "distance_invalid", "invalid_depth"]
	var nearby := kind in ["ground", "depth_separated"]
	var normal_modifier := func(x: int, y: int, c: Color) -> Color:
		if nearby and x >= 35 and x <= 46 and abs(y - 32) <= 3:
			return Color(c.r, c.g, c.b, 0.8)
		return c
	var depth_modifier := func(x: int, y: int, c: Color) -> Color:
		if kind == "depth_separated" and x >= 35 and x <= 46 and abs(y - 32) <= 3:
			return Color(raster_depth(projection, 20), 0, 0)
		return c
	var previous_camera := Transform3D.IDENTITY
	if kind == "history_reprojected": previous_camera.origin.x = -0.8
	if kind == "history_outside": previous_camera.origin.x = 100
	var previous_clip := projection * Vector4(previous_camera.origin.x, 0, -distance, 1)
	var history_pixel := Vector2i((Vector2(previous_clip.x, previous_clip.y) / previous_clip.w * 0.5 + Vector2(0.5, 0.5)) * Vector2(SIZE))
	var history_enabled := kind.begins_with("history_") and kind != "history_zero"
	var signal_modifier := func(x: int, y: int, c: Color) -> Color:
		if kind == "history_reprojected":
			return Color(c.r, c.g, c.b, 1.0 if absi(x - history_pixel.x) <= 1 and absi(y - history_pixel.y) <= 1 else 0.0)
		return c
	var resources: Array[RID] = [
		float_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, Color(depth, 0, 0), depth_modifier),
		float_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(0.5, 0.5, 1, 0.8 if dynamic_receiver else 0.4), normal_modifier, normal_size),
		float_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(0, 0, 0, NAN if kind == "history_nan" else (1.0 if history_enabled else 0.0)), signal_modifier),
		metadata_texture(NAN if kind == "history_invalid_vertex_depth" else depth, 0 if kind == "history_unknown" else 7),
		metadata_texture(depth, 8 if kind == "history_other_id" else 7, Vector2i(32, 32) if kind == "history_size" else SIZE),
		float_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, Color(raster_depth(projection, 2) if kind == "history_occluded" else depth, 0, 0)),
	]
	var data := PackedFloat32Array()
	for unused in 2: append_matrix(data, projection.inverse())
	append_matrix(data, Projection.IDENTITY)
	append_matrix(data, Projection(previous_camera))
	for unused in 2: append_matrix(data, projection)
	for unused in 2: append_matrix(data, projection.inverse())
	for unused in 2: append_matrix(data, projection)
	var scene_buffer := rd.uniform_buffer_create(data.size() * 4, data.to_byte_array())
	var result_buffer := rd.storage_buffer_create(33 * 4)
	var uniforms: Array[RDUniform] = []
	for i in 6: uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE, i, resources[i]))
	uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER, 6, sampler))
	uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 7, result_buffer))
	var set_rid := rd.uniform_set_create(uniforms, shader, 0)
	var scene_set := rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 0, scene_buffer)], shader, 1)
	var push := PackedInt32Array([SIZE.x, SIZE.y, SIZE.x, SIZE.y, 4, 0, frame, flags]).to_byte_array()
	push.append_array(PackedFloat32Array([0, 0.04, 0.01, 0.8]).to_byte_array())
	push.append_array(PackedInt32Array([base, 0, 0, 0]).to_byte_array())
	push.append_array(PackedFloat32Array([0, 0, 0, 0]).to_byte_array())
	push.append_array(PackedInt32Array([target]).to_byte_array())
	push.append_array(PackedFloat32Array([NAN if kind == "distance_invalid" else 30.0, NAN if kind == "radius_invalid" else (0.0 if kind.begins_with("radius_zero") else 2.0)]).to_byte_array())
	push.append_array(PackedInt32Array([0]).to_byte_array())
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set_rid, 0)
	rd.compute_list_bind_uniform_set(list, scene_set, 1)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var result := rd.buffer_get_data(result_buffer).to_int32_array()
	for resource in [set_rid, scene_set, scene_buffer, result_buffer]: rd.free_rid(resource)
	for resource in resources: rd.free_rid(resource)
	measurements.append({"case": kind, "orthographic": orthographic, "base": base, "target": target, "count": result[0]})
	return result

func run_helper_checks() -> void:
	rd = RenderingServer.create_local_rendering_device()
	check(rd != null, "local Vulkan device is available")
	if rd == null: return
	var source := RDShaderSource.new()
	source.source_compute = helper_shader_source()
	var spirv := rd.shader_compile_spirv_from_source(source)
	check(spirv.compile_error_compute.is_empty(), "exact production dynamic-sampling helpers compile " + spirv.compile_error_compute)
	if not spirv.compile_error_compute.is_empty():
		rd.free()
		return
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	sampler = rd.sampler_create(RDSamplerState.new())
	for orthographic in [false, true]:
		var expected := {"dynamic": 4, "static": 2, "ground": 4, "depth_separated": 2, "far": 2, "fade": 3, "disabled": 2, "normal_size": 2, "invalid_depth": 2, "radius_invalid": 2, "radius_zero_dynamic": 4, "radius_zero_static": 2, "distance_invalid": 2, "history_valid": 4, "history_reprojected": 4, "history_zero": 2, "history_no_flag": 2, "history_unknown": 2, "history_other_id": 2, "history_invalid_vertex_depth": 2, "history_occluded": 2, "history_nan": 2, "history_size": 2, "history_outside": 2}
		for kind in expected:
			var result := dispatch(kind, orthographic)
			check(result[0] == expected[kind], ("orthographic " if orthographic else "perspective ") + kind + " ray budget=%d expected=%d" % [result[0], expected[kind]])
		for target in range(1, 9):
			var result := dispatch("target", orthographic, 2, target)
			check(result[0] == maxi(2, target), "target %d never lowers base ray budget" % target)
		for base in range(1, 9):
			var result := dispatch("dynamic", orthographic, base, 8, 1009)
			var unchanged := true
			for candidate in base:
				unchanged = unchanged and result[1 + candidate * 2] == result[17 + candidate * 2] and result[2 + candidate * 2] == result[18 + candidate * 2]
			check(result[0] == 8 and unchanged, "base %d keeps every original sample bit-for-bit when adding rays" % base)
		var four := dispatch("dynamic", orthographic, 2, 4)
		var eight := dispatch("dynamic", orthographic, 2, 8)
		check(four.slice(1, 17) == eight.slice(1, 17), "additional ray identities do not change with allocated count")
		var extras_independent := true
		for candidate in range(2, 8):
			extras_independent = extras_independent and (eight[1 + candidate * 2] != eight[17 + candidate * 2] or eight[2 + candidate * 2] != eight[18 + candidate * 2])
		check(extras_independent, "additional rays use an independent stream")
	for resource in [sampler, pipeline, shader]: rd.free_rid(resource)
	rd.free()

func frames(count: int) -> void:
	for frame in count:
		await process_frame
		await RenderingServer.frame_post_draw

func make_box(parent: Node3D, position: Vector3, size: Vector3, dynamic: bool) -> void:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.position = position
	instance.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC if dynamic else GeometryInstance3D.GI_MODE_STATIC
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.6, 0.6, 0.6)
	material.roughness = 0.8
	instance.material_override = material
	parent.add_child(instance)

func scene_capture(label: String) -> Dictionary:
	# Read timings before the observer's explicit GPU readback. These measure
	# this controlled debug scene, not full-game frame rate.
	var timings: Array[float] = []
	for frame in 24:
		await frames(1)
		var time := RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
		if is_finite(time) and time > 0.0: timings.append(time)
	budget_observer.request_capture()
	await frames(1)
	var info := budget_observer.get_observation()
	check(not info.is_empty(), label + " reads actual production trace-count debug bits")
	if info.is_empty(): return {}
	var values: PackedInt32Array = info.values
	var valid := 0
	var boosted := 0
	var dynamic_count := 0
	var dynamic_boosted := 0
	var nearby_floor_boosted := 0
	var unaffected_floor_base := 0
	var counts_valid := true
	var ids := {}
	for i in range(0, values.size(), 5):
		if (values[i] & 1) == 0 or values[i + 3] == 0: continue
		var count := (values[i] >> 12) & 15
		valid += 1
		counts_valid = counts_valid and count >= 2 and count <= 4
		if count > 2: boosted += 1
		ids[values[i + 3]] = true
		if values[i + 4] != 0:
			dynamic_count += 1
			if count == 4: dynamic_boosted += 1
		else:
			var screen := Vector2(values[i + 1], values[i + 2]) + Vector2(0.5, 0.5)
			var floor_point = Plane(Vector3.UP, 0).intersects_ray(camera.project_ray_origin(screen), camera.project_ray_normal(screen))
			if floor_point is Vector3:
				var distance := Vector2(floor_point.x - car.position.x, floor_point.z - car.position.z).length()
				if distance < 2.5 and count == 4: nearby_floor_boosted += 1
				if distance > 4.0 and count == 2: unaffected_floor_base += 1
	check(valid > 100 and counts_valid, label + " has valid bounded ray budgets on visible receiver identities")
	timings.sort()
	var result := {"label": label, "valid_probes": valid, "boosted_probes": boosted, "dynamic_probes": dynamic_count, "dynamic_boosted": dynamic_boosted, "nearby_floor_boosted": nearby_floor_boosted, "unaffected_floor_base": unaffected_floor_base, "surface_ids": ids.keys(), "gpu_debug_scene_median_ms": timings[timings.size() / 2] if not timings.is_empty() else 0.0}
	measurements.append(result)
	print("DYNAMIC_SAMPLING_SCENE_SAMPLE ", JSON.stringify(result))
	root.get_texture().get_image().save_png(out.path_join(label + ".png"))
	return result

func run_scene_checks() -> void:
	root.size = Vector2i(640, 360)
	root.use_taa = false
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.debug_draw = Viewport.DEBUG_DRAW_HDDAGI_SCREEN_PROBES
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	var settings := {"screen_probe_candidate_count": 2, "screen_probe_dynamic_candidate_count": 4, "screen_probe_dynamic_sampling_distance": 30.0, "screen_probe_dynamic_sampling_radius": 2.0, "screen_probe_denoiser": 1, "screen_probe_denoiser_quality": 2, "screen_probe_detail_trace": true, "screen_probe_directional_screen_radiance": true, "screen_probe_radiance_cache": 0, "screen_probe_radiance_cache_multibounce": false}
	for setting in settings:
		ProjectSettings.set_setting(PREFIX + setting, settings[setting])
	ProjectSettings.set_setting("rendering/lights_and_shadows/contact_shadow/enabled", false)
	world = Node3D.new()
	root.add_child(world)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.12, 0.12, 0.12)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_energy = 0
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.dynamic_gi_enabled = true
	environment.dynamic_gi_cascades = 1
	environment.dynamic_gi_min_cell_size = 0.2
	environment.dynamic_gi_read_sky_light = true
	environment.dynamic_gi_screen_probes_enabled = true
	environment.dynamic_gi_screen_probe_mode = 0
	environment.dynamic_gi_screen_probe_size = 4
	environment.ss_shadow_enabled = false
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world.add_child(world_environment)
	make_box(world, Vector3(0, -0.15, -15), Vector3(90, 0.3, 110), false)
	car = Node3D.new()
	world.add_child(car)
	make_box(car, Vector3(0, 0.7, 0), Vector3(2, 0.7, 4), true)
	make_box(car, Vector3(0, 1.2, -0.3), Vector3(1.5, 0.6, 2), true)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-65, -30, 0)
	sun.light_energy = 1.5
	sun.shadow_enabled = false
	sun.shadow_contact_shadows_allow = false
	world.add_child(sun)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.look_at_from_position(Vector3(4, 3, 8), Vector3(0, 0.5, 0))
	camera.current = true
	budget_observer = BudgetObserver.new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [budget_observer]
	camera.compositor = compositor
	ProjectSettings.set_setting(PREFIX + "screen_probe_dynamic_sampling", false)
	await frames(90)
	var disabled := await scene_capture("01_disabled_near")
	if not disabled.is_empty(): check(disabled.dynamic_probes > 0 and disabled.boosted_probes == 0, "disabled feature preserves two rays on car and scenery")
	ProjectSettings.set_setting(PREFIX + "screen_probe_dynamic_sampling", true)
	await frames(90)
	var near := await scene_capture("02_enabled_near")
	if not near.is_empty():
		check(near.dynamic_probes > 0 and near.dynamic_boosted == near.dynamic_probes, "near car receives four real traced candidates")
		check(near.nearby_floor_boosted > 0, "ground beside the visible car receives additional candidates")
		check(near.unaffected_floor_base > 100, "unaffected static floor keeps the original budget")
	car.position.x = 3
	await frames(1)
	var moved := await scene_capture("03_moved_car")
	if not moved.is_empty(): check(moved.dynamic_probes > 0 and moved.dynamic_boosted == moved.dynamic_probes and moved.nearby_floor_boosted > 0, "extra rays follow translated geometry and its new ground neighborhood")
	camera.position.x += 3
	await frames(45)
	var stopped := await scene_capture("04_followed_and_stopped")
	if not stopped.is_empty(): check(stopped.dynamic_probes > 0 and stopped.dynamic_boosted == stopped.dynamic_probes, "camera follow and stopping retain the local quality budget")
	root.msaa_3d = Viewport.MSAA_2X
	await frames(30)
	var msaa := await scene_capture("05_msaa_near")
	if not msaa.is_empty(): check(msaa.dynamic_probes > 0 and msaa.dynamic_boosted == msaa.dynamic_probes, "MSAA resolves dynamic classification for the budget")
	root.msaa_3d = Viewport.MSAA_DISABLED
	car.position = Vector3(0, 0, -40)
	camera.look_at_from_position(Vector3(4, 3, 8), Vector3(0, 0.5, 0))
	await frames(240)
	var far := await scene_capture("06_far_car")
	if not far.is_empty(): check(far.dynamic_probes > 0 and far.dynamic_boosted == 0 and far.boosted_probes == 0, "far dynamic geometry and distant ground keep two candidates")
	car.visible = false
	await frames(240)
	var empty := await scene_capture("07_no_dynamic_geometry")
	if not empty.is_empty(): check(empty.dynamic_probes == 0 and empty.boosted_probes == 0, "scene without dynamic actors has no persistent extra sampling")
	world.queue_free()
	await frames(4)
	root.get_texture().get_image()

func run() -> void:
	if OS.get_cmdline_user_args().has("--scene"):
		await run_scene_checks()
	else:
		await run_helper_checks()
	FileAccess.open(out.path_join("measurements.json"), FileAccess.WRITE).store_string(JSON.stringify(measurements, "\t"))
	print("DYNAMIC_SAMPLING_RESULT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
