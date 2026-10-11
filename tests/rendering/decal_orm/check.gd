extends SceneTree

var failures := 0
var checks := 0
var view: SubViewport
var decal: Decal
var env: Environment
var sun: DirectionalLight3D
var output := "user://"

func check(ok: bool, message: String) -> void:
	checks += 1
	print("DECAL_ORM_OK " if ok else "DECAL_ORM_FAIL ", message)
	if not ok:
		failures += 1

func texture(color: Color) -> ImageTexture:
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)

func soft_mask() -> ImageTexture:
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			var radius := Vector2(x - 63.5, y - 63.5).length() / 63.5
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, 1.0 - smoothstep(0.7, 1.0, radius)))
	return ImageTexture.create_from_image(img)

func capture(label: String) -> Image:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := view.get_texture().get_image()
	img.save_png(output + RenderingServer.get_current_rendering_method() + "_" + label + ".png")
	return img

func difference(a: Image, b: Image) -> float:
	var result := 0.0
	for y in range(64, 192):
		for x in range(64, 192):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			result += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
	return result / (128.0 * 128.0 * 3.0)

func luminance(img: Image) -> float:
	var result := 0.0
	for y in range(64, 192):
		for x in range(64, 192):
			result += img.get_pixel(x, y).get_luminance()
	return result / (128.0 * 128.0)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	decal = Decal.new()
	check(decal.ao_mix == 1.0 and decal.roughness_mix == 1.0 and decal.metallic_mix == 1.0, "Legacy defaults")
	decal.roughness_mix = 0.0
	decal.metallic_mix = 0.0
	var packed := PackedScene.new()
	check(packed.pack(decal) == OK, "Pack AO-only decal")
	check(ResourceSaver.save(packed, output + "ao_only.tscn") == OK, "Save scene")
	var restored := (load(output + "ao_only.tscn") as PackedScene).instantiate() as Decal
	check(restored.ao_mix == 1.0 and restored.roughness_mix == 0.0 and restored.metallic_mix == 0.0, "AO-only controls survive scene serialization")
	restored.free()
	decal.ao_mix = -1.0
	decal.roughness_mix = 2.0
	check(decal.ao_mix == 0.0 and decal.roughness_mix == 1.0 and decal.metallic_mix == 0.0, "Clamped controls stay independent")
	decal.metallic_mix = 2.0
	check(decal.metallic_mix == 1.0 and decal.ao_mix == 0.0, "Metallic upper clamp preserves AO")
	decal.metallic_mix = -1.0
	check(decal.metallic_mix == 0.0, "Metallic lower clamp")
	decal.ao_mix = 1.0
	decal.roughness_mix = 0.0

	view = SubViewport.new()
	view.size = Vector2i(256, 256)
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var world := Node3D.new()
	view.add_child(world)
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.ss_shadow_enabled = false
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.2, 0.2, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.7
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	we.environment = env
	world.add_child(we)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8.0, 8.0)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.55, 0.55)
	mat.roughness = 0.65
	mat.metallic = 0.0
	mat.ao_light_affect = 0.0
	ground.material_override = mat
	world.add_child(ground)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 6.0
	world.add_child(camera)
	camera.position = Vector3(0, 5, 0)
	camera.look_at(Vector3.ZERO, Vector3.FORWARD)
	camera.current = true
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-90, 0, 0)
	sun.light_energy = 0.8
	world.add_child(sun)
	decal.size = Vector3(4, 2, 4)
	decal.upper_fade = 0.0
	decal.lower_fade = 0.0
	decal.albedo_mix = 0.0
	decal.texture_albedo = soft_mask()
	decal.texture_orm = texture(Color(1.0, 0.0, 1.0))
	world.add_child(decal)
	decal.visible = false
	var baseline := await capture("baseline")
	decal.visible = true
	var neutral := await capture("neutral_ao_preserved_rm")
	var d := difference(baseline, neutral)
	check(d < 0.002, "Neutral AO preserves receiving material, pixel difference=%f" % d)
	decal.roughness_mix = 1.0
	decal.metallic_mix = 1.0
	var legacy := await capture("legacy_orm_override")
	d = difference(baseline, legacy)
	check(d > 0.02, "Legacy ORM override remains active, pixel difference=%f" % d)
	decal.metallic_mix = 0.0
	var roughness_only := await capture("roughness_only")
	check(difference(baseline, roughness_only) > 0.002, "Roughness channel can change independently")
	decal.roughness_mix = 0.0
	decal.metallic_mix = 1.0
	var metallic_only := await capture("metallic_only")
	check(difference(baseline, metallic_only) > 0.02, "Metallic channel can change independently")
	decal.roughness_mix = 0.0
	decal.metallic_mix = 0.0
	decal.texture_orm = texture(Color(0.15, 0.0, 1.0))
	sun.light_energy = 0.0
	decal.visible = false
	var ambient_base := await capture("ambient_baseline")
	decal.visible = true
	var ambient_ao := await capture("ambient_ao_only")
	check(luminance(ambient_ao) < luminance(ambient_base) * 0.8, "AO still darkens ambient: %f -> %f" % [luminance(ambient_base), luminance(ambient_ao)])
	decal.ao_mix = 0.5
	var partial_ao := await capture("partial_ao")
	check(luminance(partial_ao) > luminance(ambient_ao) and luminance(partial_ao) < luminance(ambient_base), "Partial AO mix interpolates ambient darkening")
	decal.ao_mix = 1.0
	env.ambient_light_energy = 0.0
	sun.light_energy = 0.8
	decal.visible = false
	var direct_base := await capture("direct_baseline")
	# Compatibility applies AO to direct lighting even with AO_LIGHT_AFFECT=0.
	# Preserve that backend's existing behavior; disabling AO must still leave
	# direct lighting unchanged. Forward+/Mobile preserve it with AO enabled.
	var compatibility := RenderingServer.get_current_rendering_method() == "gl_compatibility"
	if compatibility:
		decal.ao_mix = 0.0
	decal.visible = true
	var direct_ao := await capture("direct_ao_only")
	d = difference(direct_base, direct_ao)
	check(d < 0.002, "Direct lighting preserved with %s AO, pixel difference=%f" % ["disabled" if compatibility else "ambient-only", d])
	# Exercise a second GPU buffer element with independent values.
	var second := Decal.new()
	second.size = Vector3(4, 2, 4)
	second.upper_fade = 0.0
	second.lower_fade = 0.0
	second.albedo_mix = 0.0
	second.texture_albedo = decal.texture_albedo
	second.texture_orm = texture(Color(0.0, 0.0, 1.0))
	world.add_child(second)
	second.ao_mix = 0.0
	second.roughness_mix = 0.0
	second.metallic_mix = 0.0
	var stacked := await capture("two_decals_disabled_second")
	check(difference(direct_base, stacked) < 0.002, "Second decal preserves disabled channels")
	# VisualInstance3D.get_base() on Decal is not the internal decal RID. Create a
	# valid server-owned decal to verify the low-level API and its GPU data.
	decal.visible = false
	second.visible = false
	sun.light_energy = 0.0
	env.ambient_light_energy = 0.7
	var server_decal := RenderingServer.decal_create()
	var server_node := VisualInstance3D.new()
	server_node.set_base(server_decal)
	world.add_child(server_node)
	RenderingServer.decal_set_size(server_decal, Vector3(4, 2, 4))
	RenderingServer.decal_set_fade(server_decal, 0.0, 0.0)
	RenderingServer.decal_set_albedo_mix(server_decal, 0.0)
	RenderingServer.decal_set_texture(server_decal, RenderingServer.DECAL_TEXTURE_ALBEDO, decal.texture_albedo.get_rid())
	RenderingServer.decal_set_texture(server_decal, RenderingServer.DECAL_TEXTURE_ORM, decal.texture_orm.get_rid())
	RenderingServer.decal_set_orm_mix(server_decal, -1.0, -1.0, -1.0)
	var server_disabled := await capture("server_disabled")
	check(difference(ambient_base, server_disabled) < 0.002, "RenderingServer clamps negative mixes and preserves the surface")
	RenderingServer.decal_set_orm_mix(server_decal, 2.0, 0.0, 0.0)
	var server_ao := await capture("server_ao")
	check(difference(ambient_ao, server_ao) < 0.002, "RenderingServer AO reaches the shader and clamps to one")
	server_node.free()
	RenderingServer.free_rid(server_decal)
	print("DECAL_ORM_RESULT renderer=%s checks=%d failures=%d" % [RenderingServer.get_current_rendering_method(), checks, failures])
	quit(0 if failures == 0 else 1)
