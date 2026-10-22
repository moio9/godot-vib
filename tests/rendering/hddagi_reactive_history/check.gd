extends SceneTree

const SIZE := Vector2i(13, 11)
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var sampler: RID
var frame_buffer: RID
var frame_set: RID
var checks := 0
var failures := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	print("REACTIVE_OK " if ok else "REACTIVE_FAIL ", message)
	if not ok:
		failures += 1

func _initialize() -> void:
	call_deferred("run")

func uniform(kind: int, binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = kind
	u.binding = binding
	u.add_id(rid)
	return u

func texture(format: int, color: Color, modifier := Callable()) -> RID:
	var image_format := Image.FORMAT_RGBAF
	if format == RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT:
		image_format = Image.FORMAT_RGBAH
	elif format == RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM:
		image_format = Image.FORMAT_RGBA8
	elif format == RenderingDevice.DATA_FORMAT_R32_SFLOAT:
		image_format = Image.FORMAT_RF
	var image := Image.create(SIZE.x, SIZE.y, false, image_format)
	image.fill(color)
	if modifier.is_valid():
		for y in SIZE.y:
			for x in SIZE.x:
				image.set_pixel(x, y, modifier.call(x, y, color))
	var fmt := RDTextureFormat.new()
	fmt.width = SIZE.x
	fmt.height = SIZE.y
	fmt.format = format
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return rd.texture_create(fmt, RDTextureView.new(), [image.get_data()])

func dispatch(kind: String, reactive: bool) -> Image:
	var current := 0.125
	var previous := 0.015625
	var variance := 0.0
	var signal_modifier := Callable()
	var depth_modifier := Callable()
	var normal_modifier := Callable()
	var motion_modifier := Callable()
	var current_influence := 1.0
	var previous_influence := 1.0
	var dynamic_motion := true
	var influence_mode := kind.begins_with("mask_")
	if kind in ["static_correlated_noise", "mask_static_far", "mask_current_dynamic", "mask_vacated_dynamic", "mask_stopped_dynamic"]:
		# A coherent 8% fluctuation is deliberately indistinguishable from a
		# faint shadow by RGB alone. Only independently supplied motion and
		# endpoint influence may authorize destructive temporal rejection.
		current = 0.001794
		previous = 0.00195
		variance = 1.0
		dynamic_motion = kind not in ["static_correlated_noise", "mask_stopped_dynamic"]
		current_influence = 1.0 if kind in ["mask_current_dynamic", "mask_stopped_dynamic"] else 0.0
		previous_influence = 1.0 if kind in ["mask_vacated_dynamic", "mask_stopped_dynamic"] else 0.0
		if kind == "mask_vacated_dynamic":
			current = 0.00195
			previous = 0.001794
	elif kind in ["young_shadow_1", "young_shadow_2"]:
		current = 0.0
		previous = 0.125
	elif kind == "off":
		current = 0.0
		previous = 0.125
	elif kind in ["soft_shadow_enter", "soft_shadow_leave"]:
		current = 0.00177 if kind == "soft_shadow_enter" else 0.00195
		previous = 0.00195 if kind == "soft_shadow_enter" else 0.00177
		variance = 1.0
	elif kind == "noisy_soft_shadow":
		current = 0.00175
		previous = 0.00195
		variance = 1.0
		signal_modifier = func(x: int, y: int, c: Color) -> Color:
			var scale := 1.0 + float((x % 3) + 3 * (y % 3) - 4) * 0.025
			return Color(c.r * scale, c.g * scale, c.b * scale, c.a)
	elif kind in ["faint_shadow_enter", "faint_shadow_leave"]:
		current = 0.000002 if kind == "faint_shadow_enter" else 0.00001
		previous = 0.00001 if kind == "faint_shadow_enter" else 0.000002
		variance = 1.0
	elif kind == "sloped_floor":
		variance = 1.0
		depth_modifier = func(_x: int, y: int, _c: Color) -> Color:
			var ndc_y := (float(y) + 0.5) / SIZE.y * 2.0 - 1.0
			return Color(2.0 / (1.0 - 4.0 * ndc_y), 0, 0, 1)
		normal_modifier = func(_x: int, _y: int, c: Color) -> Color:
			return Color(0.5, 0.9472136, 0.7236068, c.a)
	elif kind == "stable" or kind == "noise":
		current = previous
		if kind == "noise":
			variance = 1.0
			signal_modifier = func(x: int, y: int, c: Color) -> Color:
				return Color(c.r * (0.0 if (x + y) % 2 == 0 else 2.0), c.g * (0.0 if (x + y) % 2 == 0 else 2.0), c.b * (0.0 if (x + y) % 2 == 0 else 2.0), 1)
	elif kind == "isolated":
		signal_modifier = func(x: int, y: int, c: Color) -> Color:
			return c if x == 6 and y == 5 else Color(previous, previous, previous, 1)
	elif kind == "depth_edge":
		depth_modifier = func(x: int, y: int, c: Color) -> Color:
			return c if x == 6 and y == 5 else Color(8, 0, 0, 1)
	elif kind == "normal_edge":
		normal_modifier = func(x: int, y: int, c: Color) -> Color:
			return c if x == 6 and y == 5 else Color(1, 0.5, 0.5, 0.5)
	elif kind == "dynamic_edge":
		motion_modifier = func(x: int, y: int, c: Color) -> Color:
			return c if x == 6 and y == 5 else Color(0, 0, 0, 2)
	var resources: Array[RID] = []
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(current, current, current, current_influence), signal_modifier))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(0.5, 0.5, 1, 0.5), normal_modifier))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, Color(2, 0, 0, 1), depth_modifier))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(0, 0, 0, 0), motion_modifier))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(previous, previous, previous, previous_influence)))
	var moment := previous * 64.0
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(moment, moment * moment + variance, 0, 0)))
	var history_frames := 1.0 if kind == "young_shadow_1" else (2.0 if kind == "young_shadow_2" else 30.0)
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(0.5, 0.5, 1, history_frames / 255.0), normal_modifier if kind == "sloped_floor" else Callable()))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, Color(2, 0, 0, 1)))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Color(0, 0, 0, 0)))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Color(0, 0, 0, 0)))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, Color(0, 0, 0, 0)))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, Color(0, 0, 0, 0)))
	var uniforms: Array[RDUniform] = []
	for i in 8:
		uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE, i, resources[i]))
	uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER, 8, sampler))
	for i in 4:
		uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 9 + i, resources[8 + i]))
	var metadata_format := RDTextureFormat.new()
	metadata_format.width = SIZE.x
	metadata_format.height = SIZE.y
	metadata_format.format = RenderingDevice.DATA_FORMAT_R32G32_UINT
	metadata_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var metadata_data := PackedByteArray()
	metadata_data.resize(SIZE.x * SIZE.y * 8)
	var metadata := rd.texture_create(metadata_format, RDTextureView.new(), [metadata_data])
	uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE, 13, metadata))
	uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE, 14, metadata))
	resources.append(metadata)
	var motion_format := RDTextureFormat.new()
	motion_format.width = 1
	motion_format.height = 1
	motion_format.format = RenderingDevice.DATA_FORMAT_R32_UINT
	motion_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var motion_flag := rd.texture_create(motion_format, RDTextureView.new(), [PackedInt32Array([1 if dynamic_motion else 0]).to_byte_array()])
	uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE, 15, motion_flag))
	resources.append(motion_flag)
	var set_rid := rd.uniform_set_create(uniforms, shader, 0)
	var control := 0 if kind == "cut" else 1
	if reactive:
		control |= 8
	if kind == "specular":
		control |= 2
	if influence_mode:
		control |= 32
	var push := PackedInt32Array([control, 0, 0, 0]).to_byte_array()
	push.append_array(PackedFloat32Array([500000, 0.9, 0.005, 2, 8, 0.005, 0.00004, 30]).to_byte_array())
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set_rid, 0)
	rd.compute_list_bind_uniform_set(list, frame_set, 1)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, 2, 2, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var result := Image.create_from_data(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH, rd.texture_get_data(resources[8], 0))
	rd.free_rid(set_rid)
	for rid in resources:
		rd.free_rid(rid)
	return result

func run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		check(false, "local Vulkan rendering device available")
		quit(1)
		return
	var shader_path := ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/shaders/environment/hddagi_screen_probe_svgf.glsl")
	var code := FileAccess.get_file_as_string(shader_path).replace("#[compute]", "")
	code = code.replace('#include "hddagi_surface_history_inc.glsl"', FileAccess.get_file_as_string(shader_path.get_base_dir().path_join("hddagi_surface_history_inc.glsl")))
	for mode in ["MODE_TEMPORAL", "MODE_HISTORY_FIX", "MODE_ATROUS", "MODE_SPECULAR_RECONSTRUCT"]:
		var source := RDShaderSource.new()
		source.source_compute = code.replace("#VERSION_DEFINES", "#define " + mode)
		var spirv := rd.shader_compile_spirv_from_source(source)
		check(spirv.compile_error_compute.is_empty(), mode + " compiles " + spirv.compile_error_compute)
		if not spirv.compile_error_compute.is_empty():
			rd.free()
			quit(1)
			return
		if mode == "MODE_TEMPORAL":
			shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	sampler = rd.sampler_create(RDSamplerState.new())
	var data := PackedFloat32Array()
	for matrix in 5:
		for column in 4:
			for row in 4:
				var value := 1.0 if column == row else 0.0
				if matrix < 2 and column == 2 and row == 2:
					value = -1.0
				data.append(value)
	data.append_array(PackedFloat32Array([0, 0, 0, 0]))
	frame_buffer = rd.uniform_buffer_create(data.size() * 4, data.to_byte_array())
	frame_set = rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 0, frame_buffer)], shader, 1)
	for kind in ["on", "off", "young_shadow_1", "young_shadow_2", "faint_shadow_enter", "faint_shadow_leave", "soft_shadow_enter", "soft_shadow_leave", "noisy_soft_shadow", "sloped_floor", "stable", "noise", "isolated", "depth_edge", "normal_edge", "dynamic_edge", "cut", "specular", "static_correlated_noise", "mask_static_far", "mask_current_dynamic", "mask_vacated_dynamic", "mask_stopped_dynamic"]:
		var baseline := dispatch(kind, false)
		var adaptive := dispatch(kind, true)
		var old_value := baseline.get_pixel(6, 5).r
		var new_value := adaptive.get_pixel(6, 5).r
		print("REACTIVE_SAMPLE ", kind, " baseline=", old_value, " reactive=", new_value)
		if kind == "on":
			check(absf(new_value - 0.125) < absf(old_value - 0.125) * 0.65, "light-on residual reduced by at least 35 percent")
		elif kind == "off":
			check(new_value < old_value * 0.65, "light-off residual reduced by at least 35 percent")
		elif kind in ["young_shadow_1", "young_shadow_2"]:
			check(new_value < 0.000001, kind + " clears even recent illumination history")
		elif kind in ["faint_shadow_enter", "faint_shadow_leave"]:
			var expected := 0.000002 if kind == "faint_shadow_enter" else 0.00001
			check(absf(new_value - expected) < 0.0000002, kind + " removes faint floor shadow history despite old stochastic variance")
		elif kind == "sloped_floor":
			check(absf(new_value - 0.125) < 0.0001, "coherent lighting reacts on an oblique floor using plane distance")
		elif kind in ["soft_shadow_enter", "soft_shadow_leave"]:
			var expected := 0.00177 if kind == "soft_shadow_enter" else 0.00195
			check(absf(new_value - expected) < 0.000002, kind + " reacts to low-contrast indirect ground occlusion")
		elif kind == "noisy_soft_shadow":
			check(absf(new_value - 0.0018375) < 0.000002, "low-contrast coherent shadow reacts despite spatial stochastic variance")
		elif kind in ["static_correlated_noise", "mask_static_far", "mask_stopped_dynamic"]:
			check(absf(old_value - new_value) < 0.000001, kind + " preserves legacy accumulation for correlated stochastic noise")
		elif kind in ["mask_current_dynamic", "mask_vacated_dynamic"]:
			var expected := 0.00195 if kind == "mask_vacated_dynamic" else 0.001794
			check(absf(old_value - expected) > 0.00005 and absf(new_value - expected) < 0.000002, kind + " clears affected floor history only with independent motion and influence")
		else:
			check(absf(old_value - new_value) < 0.000001, kind + " preserves expected response")
		var finite := true
		for y in SIZE.y:
			for x in SIZE.x:
				var c := adaptive.get_pixel(x, y)
				finite = finite and is_finite(c.r) and is_finite(c.g) and is_finite(c.b)
		check(finite, kind + " finite output including partial workgroups")
	rd.free_rid(frame_set)
	rd.free_rid(frame_buffer)
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	rd.free_rid(sampler)
	rd.free()
	print("HDDAGI_REACTIVE_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
