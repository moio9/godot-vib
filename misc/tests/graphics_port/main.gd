extends Node3D

var moving_mesh: MeshInstance3D


func _ready() -> void:
	var camera := Camera3D.new()
	camera.look_at_from_position(Vector3(0.0, 1.3, 5.0), Vector3.ZERO)
	camera.current = true
	var attributes := CameraAttributesPractical.new()
	attributes.motion_blur_enabled = true
	attributes.motion_blur_intensity = 0.2
	camera.attributes = attributes
	add_child(camera)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35.0, -25.0, 0.0)
	light.shadow_enabled = true
	light.shadow_contact_shadows_allow = true
	add_child(light)

	var area_light := AreaLight3D.new()
	area_light.position = Vector3(1.0, 2.0, 2.0)
	add_child(area_light)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.12, 0.12, 0.12)
	environment.ssao_enabled = true
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)

	var floor_mesh := MeshInstance3D.new()
	var floor_box := BoxMesh.new()
	floor_box.size = Vector3(6.0, 0.2, 6.0)
	floor_mesh.mesh = floor_box
	floor_mesh.position = Vector3(0.0, -0.6, 0.0)
	var floor_material := StandardMaterial3D.new()
	floor_material.metallic = 0.6
	floor_material.roughness = 0.35
	floor_mesh.material_override = floor_material
	add_child(floor_mesh)

	var reflection_probe := ReflectionProbe.new()
	reflection_probe.size = Vector3(10.0, 6.0, 10.0)
	reflection_probe.box_projection = true
	add_child(reflection_probe)

	moving_mesh = MeshInstance3D.new()
	moving_mesh.mesh = BoxMesh.new()
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
void fragment() {
	ALBEDO = vec3(0.35, 0.7, 0.25);
	ROUGHNESS = 0.8;
	MESH_BLEND = 0.75;
	MESH_BLEND_GROUP = 1u;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	moving_mesh.material_override = material
	add_child(moving_mesh)

	for samples in [Viewport.MSAA_DISABLED, Viewport.MSAA_2X]:
		get_viewport().msaa_3d = samples
		for gi_mode in range(3):
			environment.ssil_enabled = gi_mode == 1
			environment.ssgi_enabled = gi_mode == 2
			for frame in range(12):
				moving_mesh.position.x = sin(float(frame) * 0.25) * 0.5
				await get_tree().process_frame
			print("GRAPHICS_CASE_OK msaa=", samples, " gi=", gi_mode)

	for box_projection in [false, true]:
		reflection_probe.box_projection = box_projection
		for frame in range(6):
			camera.position.x = float(frame) * 0.05
			await get_tree().process_frame
		print("REFLECTION_PROBE_CASE_OK box_projection=", box_projection)

	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	get_viewport().scaling_3d_scale = 0.75
	environment.ssil_enabled = false
	environment.ssgi_enabled = false
	for frame in range(12):
		moving_mesh.position.x = sin(float(frame) * 0.25) * 0.5
		await get_tree().process_frame
	print("GRAPHICS_FSR2_OK")

	if "--dynamic-gi" in OS.get_cmdline_user_args():
		get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		get_viewport().scaling_3d_scale = 1.0
		environment.dynamic_gi_cascades = 1
		environment.dynamic_gi_min_cell_size = 0.5
		environment.dynamic_gi_cascade_format = Environment.DYNAMIC_GI_CASCADE_FORMAT_16x8x16
		environment.dynamic_gi_screen_probe_size = 16
		# Static scene meshes must participate in the HDDAGI voxel field.
		floor_mesh.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		moving_mesh.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
		environment.dynamic_gi_enabled = true
		ProjectSettings.set_setting("rendering/global_illumination/hddagi/screen_probe_denoiser", 1)
		for half_resolution in [false, true]:
			RenderingServer.gi_set_use_half_resolution(half_resolution)
			for samples in [Viewport.MSAA_DISABLED, Viewport.MSAA_2X]:
				get_viewport().msaa_3d = samples
				for probe_mode in range(3):
					environment.dynamic_gi_screen_probes_enabled = probe_mode > 0
					environment.dynamic_gi_screen_probe_mode = probe_mode - 1 if probe_mode > 0 else 0
					for frame in range(8):
						moving_mesh.position.x = sin(float(frame) * 0.25) * 0.5
						await get_tree().process_frame
					print("DYNAMIC_GI_CASE_OK half=", half_resolution, " msaa=", samples, " probes=", probe_mode)
		# Disable motion blur while keeping the GI denoiser's motion history active.
		attributes.motion_blur_enabled = false
		for frame in range(4):
			moving_mesh.position.x += 0.05
			await get_tree().process_frame
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_HDDAGI_SCREEN_PROBES
		await get_tree().process_frame
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_HDDAGI_SCREEN_PROBE_REFLECTIONS
		await get_tree().process_frame
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
		# Check the existing SDFGI script API still maps to Dynamic GI.
		environment.sdfgi_enabled = false
		assert(not environment.dynamic_gi_enabled)
		await get_tree().process_frame
		environment.sdfgi_enabled = true
		assert(environment.dynamic_gi_enabled)
		await get_tree().process_frame
		environment.dynamic_gi_enabled = false
		print("DYNAMIC_GI_PORT_OK")

	attributes.motion_blur_enabled = false
	await get_tree().process_frame
	print("GRAPHICS_PORT_OK")
	get_tree().quit()
