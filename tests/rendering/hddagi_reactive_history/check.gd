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
	if kind == "off":
		current = 0.0
		previous = 0.125
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
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(current, current, current, 1), signal_modifier))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(0.5, 0.5, 1, 0.5), normal_modifier))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, Color(2, 0, 0, 1), depth_modifier))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(0, 0, 0, 0), motion_modifier))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(previous, previous, previous, 1)))
	var moment := previous * 64.0
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(moment, moment * moment + variance, 0, 0)))
	resources.append(texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(0.5, 0.5, 1, 30.0 / 255.0)))
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
	var set_rid := rd.uniform_set_create(uniforms, shader, 0)
	var control := 0 if kind == "cut" else 1
	if reactive:
		control |= 8
	if kind == "specular":
		control |= 2
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
	for kind in ["on", "off", "stable", "noise", "isolated", "depth_edge", "normal_edge", "dynamic_edge", "cut", "specular"]:
		var baseline := dispatch(kind, false)
		var adaptive := dispatch(kind, true)
		var old_value := baseline.get_pixel(6, 5).r
		var new_value := adaptive.get_pixel(6, 5).r
		print("REACTIVE_SAMPLE ", kind, " baseline=", old_value, " reactive=", new_value)
		if kind == "on":
			check(absf(new_value - 0.125) < absf(old_value - 0.125) * 0.65, "light-on residual reduced by at least 35 percent")
		elif kind == "off":
			check(new_value < old_value * 0.65, "light-off residual reduced by at least 35 percent")
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
