extends SceneTree

const SIZE := Vector2i(13, 11)
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var sampler: RID
var frame_buffer: RID
var frame_set: RID
var motion_flag: RID
var checks := 0
var failures := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	print("MOTION_FLAG_OK " if ok else "MOTION_FLAG_FAIL ", message)
	if not ok:
		failures += 1

func _initialize() -> void:
	call_deferred("run")

func uniform(kind: int, binding: int, rid: RID) -> RDUniform:
	var value := RDUniform.new()
	value.uniform_type = kind
	value.binding = binding
	value.add_id(rid)
	return value

func make_texture(format: int, data: PackedByteArray, size := SIZE, extra_usage := 0) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.width = size.x
	fmt.height = size.y
	fmt.format = format
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | extra_usage
	return rd.texture_create(fmt, RDTextureView.new(), [data])

func projection(jitter: Vector2, orthographic: bool) -> Projection:
	# Vulkan reverse-Z, near=1, far=100; jitter is an NDC displacement.
	if orthographic:
		return Projection(Vector4(0.5, 0, 0, 0), Vector4(0, 0.5, 0, 0), Vector4(0, 0, 1.0 / 99.0, 0), Vector4(jitter.x, jitter.y, 100.0 / 99.0, 1))
	return Projection(Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0), Vector4(-jitter.x, -jitter.y, 1.0 / 99.0, -1), Vector4(0, 0, 100.0 / 99.0, 0))

func transform_projection(value: Transform3D) -> Projection:
	return Projection(Vector4(value.basis.x.x, value.basis.x.y, value.basis.x.z, 0), Vector4(value.basis.y.x, value.basis.y.y, value.basis.y.z, 0), Vector4(value.basis.z.x, value.basis.z.y, value.basis.z.z, 0), Vector4(value.origin.x, value.origin.y, value.origin.z, 1))

func append_matrix(data: PackedFloat32Array, matrix: Projection) -> void:
	for column in 4:
		var value: Vector4 = matrix[column]
		data.append_array(PackedFloat32Array([value.x, value.y, value.z, value.w]))

func clip_uv(matrix: Projection, position: Vector3) -> Vector2:
	var clip := matrix * Vector4(position.x, position.y, position.z, 1)
	return Vector2(clip.x, clip.y) / clip.w * 0.5 + Vector2(0.5, 0.5)

func current_point(inv_projection: Projection, uv: Vector2, orthographic: bool) -> Vector3:
	var position := inv_projection * Vector4(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0, 0.5, 1)
	var point := Vector3(position.x, position.y, position.z) / position.w
	if orthographic:
		return Vector3(point.x, point.y, -4)
	return point * (-4.0 / point.z)

func dispatch(test: Dictionary) -> void:
	var name: String = test.name
	var orthographic: bool = test.get("ortho", false)
	var current_camera := Transform3D(Basis.IDENTITY, test.get("camera", Vector3.ZERO))
	var previous_camera := Transform3D.IDENTITY
	var displacement: Vector3 = test.get("object", Vector3.ZERO)
	var current_jitter: Vector2 = test.get("current_jitter", Vector2.ZERO)
	var previous_jitter: Vector2 = test.get("previous_jitter", Vector2.ZERO)
	var current_projection := projection(current_jitter, orthographic)
	var previous_projection := projection(previous_jitter, orthographic)
	var stable_projection := projection(Vector2.ZERO, orthographic)
	var current_inv := current_projection.inverse()
	var previous_inv := previous_projection.inverse()
	var frame_data := PackedFloat32Array()
	for matrix in [current_inv, previous_inv, transform_projection(previous_camera.affine_inverse() * current_camera), transform_projection(current_camera), transform_projection(previous_camera)]:
		append_matrix(frame_data, matrix)
	frame_data.append_array(PackedFloat32Array([current_jitter.x, current_jitter.y, previous_jitter.x, previous_jitter.y]))
	check(frame_data.size() * 4 == 336, name + " frame uniform ABI")
	rd.buffer_update(frame_buffer, 0, frame_data.size() * 4, frame_data.to_byte_array())
	var motion := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	var depth := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RF)
	depth.fill(Color(4, 0, 0, 1))
	var metadata := PackedInt32Array()
	var minimum_motion := INF
	var maximum_motion := 0.0
	for y in SIZE.y:
		for x in SIZE.x:
			var uv := (Vector2(x, y) + Vector2(0.5, 0.5)) / Vector2(SIZE)
			var view := current_point(current_inv, uv, orthographic)
			var world := current_camera * view
			var previous_world := world - displacement
			var previous_view := previous_camera.affine_inverse() * previous_world
			var velocity := clip_uv(stable_projection, previous_view) - clip_uv(stable_projection, view)
			var clip := previous_projection * Vector4(previous_view.x, previous_view.y, previous_view.z, 1)
			var previous_depth := clip.z / clip.w
			if test.get("invalid_depth", false):
				previous_depth = NAN
			var dynamic: bool = test.get("dynamic", true)
			if test.get("last_pixel_only", false):
				dynamic = x == SIZE.x - 1 and y == SIZE.y - 1
			motion.set_pixel(x, y, Color(velocity.x, velocity.y, 0, 2 if dynamic else 0))
			metadata.append_array(PackedInt32Array([PackedFloat32Array([previous_depth]).to_byte_array().to_int32_array()[0], 0 if test.get("invalid_identity", false) else 123]))
			minimum_motion = minf(minimum_motion, velocity.length())
			maximum_motion = maxf(maximum_motion, velocity.length())
	var resources: Array[RID] = [
		make_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, motion.get_data()),
		make_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, depth.get_data()),
		make_texture(RenderingDevice.DATA_FORMAT_R32G32_UINT, metadata.to_byte_array())
	]
	var uniforms: Array[RDUniform] = []
	for binding in 3:
		uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE, binding, resources[binding]))
	uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER, 3, sampler))
	uniforms.append(uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 4, motion_flag))
	var set_rid := rd.uniform_set_create(uniforms, shader, 0)
	var push := PackedInt32Array([0, 0, 0, 3 if orthographic else 0]).to_byte_array()
	push.append_array(PackedFloat32Array([500000, 0.9, 0.005, 2, 8, 0.005, 0.00004, 30]).to_byte_array())
	rd.texture_clear(motion_flag, Color(0, 0, 0, 0), 0, 1, 0, 1)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set_rid, 0)
	rd.compute_list_bind_uniform_set(list, frame_set, 1)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, 2, 2, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var result := rd.texture_get_data(motion_flag, 0).to_int32_array()[0]
	print("MOTION_FLAG_SAMPLE ", name, " flag=", result, " expected=", test.expected, " stable_uv_motion_min=", minimum_motion, " max=", maximum_motion)
	check(result == test.expected, name + " classifies world movement including partial workgroups")
	if name == "camera_car_comotion":
		check(maximum_motion < 0.000001, "camera/car co-motion has zero UV velocity but nonzero world motion")
	if name == "camera_only":
		check(maximum_motion > 0.01, "camera-only case has actual nonzero UV velocity")
	rd.free_rid(set_rid)
	for rid in resources:
		rd.free_rid(rid)

func run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		check(false, "local Vulkan rendering device available")
		quit(1)
		return
	var shader_path := ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/shaders/environment/hddagi_screen_probe_motion.glsl")
	var code := FileAccess.get_file_as_string(shader_path).replace("#[compute]", "").replace("#VERSION_DEFINES", "")
	code = code.replace('#include "hddagi_surface_history_inc.glsl"', FileAccess.get_file_as_string(shader_path.get_base_dir().path_join("hddagi_surface_history_inc.glsl")))
	var source := RDShaderSource.new()
	source.source_compute = code
	var spirv := rd.shader_compile_spirv_from_source(source)
	check(spirv.compile_error_compute.is_empty(), "motion shader compiles " + spirv.compile_error_compute)
	if not spirv.compile_error_compute.is_empty():
		rd.free()
		quit(1)
		return
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	sampler = rd.sampler_create(RDSamplerState.new())
	frame_buffer = rd.uniform_buffer_create(336)
	frame_set = rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 0, frame_buffer)], shader, 1)
	motion_flag = make_texture(RenderingDevice.DATA_FORMAT_R32_UINT, PackedInt32Array([1]).to_byte_array(), Vector2i.ONE, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT)
	for test in [
		{"name": "stationary_dynamic", "expected": 0},
		{"name": "dynamic_xy", "object": Vector3(0.25, -0.15, 0), "expected": 1},
		{"name": "dynamic_z", "object": Vector3(0, 0, 0.3), "expected": 1},
		{"name": "camera_only", "camera": Vector3(0.25, -0.1, 0.3), "expected": 0},
		{"name": "camera_car_comotion", "camera": Vector3(0.25, 0, 0), "object": Vector3(0.25, 0, 0), "expected": 1},
		{"name": "jitter_only", "current_jitter": Vector2(0.07, -0.05), "previous_jitter": Vector2(-0.03, 0.04), "expected": 0},
		{"name": "static_receiver_uv_motion", "dynamic": false, "object": Vector3(0.25, 0, 0), "expected": 0},
		{"name": "invalid_identity", "object": Vector3(0.25, 0, 0), "invalid_identity": true, "expected": 0},
		{"name": "invalid_depth", "object": Vector3(0.25, 0, 0), "invalid_depth": true, "expected": 0},
		{"name": "sub_tolerance_motion", "object": Vector3(0.0005, 0, 0), "expected": 0},
		{"name": "last_pixel_motion", "object": Vector3(0.25, 0, 0), "last_pixel_only": true, "expected": 1},
		{"name": "orthographic_camera_only", "camera": Vector3(0.25, -0.1, 0.3), "ortho": true, "expected": 0},
		{"name": "orthographic_dynamic_z", "object": Vector3(0, 0, 0.3), "ortho": true, "expected": 1},
		{"name": "cleared_after_motion", "expected": 0}
	]:
		dispatch(test)
	for rid in [frame_set, frame_buffer, motion_flag, pipeline, shader, sampler]:
		rd.free_rid(rid)
	rd.free()
	print("HDDAGI_MOTION_FLAG_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
