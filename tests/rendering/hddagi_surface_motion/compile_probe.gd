extends SceneTree

func source_expanded(path: String) -> String:
	var result := ""
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if line.begins_with("#include \""):
			var relative := line.trim_prefix("#include \"").trim_suffix("\"")
			result += source_expanded(path.get_base_dir().path_join(relative).simplify_path()) + "\n"
		else:
			result += line + "\n"
	return result

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	var code := source_expanded(ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/shaders/environment/hddagi_screen_probe.glsl")).replace("#[compute]", "")
	var variants := ["MODE_SURFACE", "MODE_TRACE", "MODE_TRACE MODE_IRRADIANCE_CACHE_QUERY", "MODE_DIRECTIONAL_ADAPTIVE_MARK", "MODE_DIRECTIONAL_ADAPTIVE_SPAWN", "MODE_TRACE MODE_DIRECTIONAL_TRACE", "MODE_DIRECTIONAL_FILTER", "MODE_DIRECTIONAL_IRRADIANCE", "MODE_RESOLVE", "MODE_RESOLVE MODE_SVGF_PREPARE", "MODE_RESOLVE MODE_DIRECTIONAL_RESOLVE", "MODE_RESOLVE MODE_DIRECTIONAL_RESOLVE MODE_SVGF_PREPARE", "MODE_IRRADIANCE_CACHE_UPDATE_MULTIBOUNCE", "MODE_APPLY", "MODE_APPLY MODE_SVGF_APPLY", "MODE_TRACE MODE_SPECULAR_TRACE", "MODE_SPECULAR_APPLY", "MODE_TRACE MODE_DEBUG_MONTAGE", "MODE_TRACE MODE_IRRADIANCE_CACHE_QUERY MODE_DEBUG_MONTAGE"]
	var failures := 0
	for variant: String in variants:
		var defines := "#define LIGHTPROBE_OCT_SIZE 6\n#define SCREEN_PROBE_DIRECTIONAL_SIZE 8\n"
		for define in variant.split(" "): defines += "#define " + define + "\n"
		var source := RDShaderSource.new()
		source.source_compute = code.replace("#VERSION_DEFINES", defines)
		var spirv := rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_compute.is_empty():
			failures += 1
			print("PROBE_COMPILE_FAIL ", variant, " ", spirv.compile_error_compute)
		else:
			print("PROBE_COMPILE_OK ", variant)
	rd.free()
	print("PROBE_COMPILE_RESULT checks=%d failures=%d" % [variants.size(), failures])
	quit(1 if failures else 0)
