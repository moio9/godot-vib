extends Node3D

var moving_mesh: MeshInstance3D


func _ready() -> void:
	var camera := Camera3D.new()
	camera.look_at_from_position(Vector3(0.0, 1.3, 5.0), Vector3.ZERO)
	camera.current = true
	var attributes := CameraAttributesPractical.new()
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
	add_child(floor_mesh)

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

	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	get_viewport().scaling_3d_scale = 0.75
	environment.ssil_enabled = false
	environment.ssgi_enabled = false
	for frame in range(12):
		moving_mesh.position.x = sin(float(frame) * 0.25) * 0.5
		await get_tree().process_frame
	print("GRAPHICS_FSR2_OK")

	attributes.motion_blur_intensity = 0.0
	await get_tree().process_frame
	print("GRAPHICS_PORT_OK")
	get_tree().quit()
