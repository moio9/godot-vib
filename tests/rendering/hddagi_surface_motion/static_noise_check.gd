extends "res://scene_check.gd"

# Keep the sampling budget at Brake's High preset. A fixed camera and unchanging
# surfaces isolate temporal GI noise from motion, shadow maps and post effects.
# Disable the irradiance cache only in this denoiser isolation: atomic allocation
# chooses entry/generation seeds and representatives in GPU invocation order, so
# separate processes cannot reproduce its multi-bounce input from frame IDs alone.
# Cached transport remains covered by ground_check.gd and scene_check.gd.
const WARMUP_FRAMES := 90
const MEASURED_FRAMES := 96
const SAMPLE_STEP := 4
const RELATIVE_NOISE_TOLERANCE := 1.15
const ABSOLUTE_NOISE_FRACTION := 0.0005
const GI_PREFIX := "rendering/global_illumination/hddagi/"

var receiver_ids: Dictionary = {}
var pixel_regions: Dictionary = {}
var noise_results: Dictionary = {}
var stopped_dynamic_box: MeshInstance3D
var frame_windows: Dictionary = {}

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("STATIC_NOISE_OK " if ok else "STATIC_NOISE_FAIL ", message)

func read_buffers() -> Dictionary:
	observer.request_capture()
	await frames(1)
	return observer.get_observation()

func surface_at(info: Dictionary, point: Vector3) -> int:
	var size: Vector2i = info.size
	var ids: PackedInt32Array = info.integers
	var center := Vector2i(camera.unproject_position(point))
	var counts: Dictionary = {}
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var pixel := center + Vector2i(dx, dy)
			if pixel.x < 0 or pixel.y < 0 or pixel.x >= size.x or pixel.y >= size.y:
				continue
			var identity := ids[(pixel.y * size.x + pixel.x) * 6]
			if identity > 0:
				counts[identity] = counts.get(identity, 0) + 1
	var best_id := 0
	var best_count := 0
	for identity in counts:
		if counts[identity] > best_count:
			best_id = identity
			best_count = counts[identity]
	return best_id

func choose_receivers(info: Dictionary) -> void:
	var points := {
		"floor": Vector3(0, 0.002, 2.2),
		"red_wall": Vector3(-3.365, 1.7, 0),
		"back_wall": Vector3(0, 1.7, -3.365),
		"box": Vector3(0.7, 0.65, 0.501),
	}
	for label in points:
		var identity := surface_at(info, points[label])
		check(identity > 0 and not receiver_ids.has(identity), label + " has its own real receiver surface ID")
		if identity > 0:
			receiver_ids[identity] = label
			pixel_regions[label] = PackedInt32Array()
	var size: Vector2i = info.size
	var ids: PackedInt32Array = info.integers
	for y in range(3, size.y - 3, SAMPLE_STEP):
		for x in range(3, size.x - 3, SAMPLE_STEP):
			var offset := (y * size.x + x) * 6
			var identity := ids[offset]
			if not receiver_ids.has(identity):
				continue
			# Exclude silhouettes and mixed neighboring geometry, including the
			# emissive source. This compares exactly the same static pixels.
			var interior := true
			for dy in [-2, 0, 2]:
				for dx in [-2, 0, 2]:
					if ids[((y + dy) * size.x + x + dx) * 6] != identity:
						interior = false
			if interior:
				var label: String = receiver_ids[identity]
				pixel_regions[label].append(offset)
	for label in pixel_regions:
		check(pixel_regions[label].size() >= 24, label + " has at least 24 interior static receiver pixels")

func measure(label: String, reactive: bool, dynamic_region := "") -> Dictionary:
	ProjectSettings.set_setting(GI_PREFIX + "screen_probe_denoiser_reactive", reactive)
	await frames(WARMUP_FRAMES)
	var accumulators: Dictionary = {}
	for region in pixel_regions:
		var count: int = pixel_regions[region].size() * 3
		var means := PackedFloat64Array()
		var moments := PackedFloat64Array()
		means.resize(count)
		moments.resize(count)
		accumulators[region] = {"means": means, "moments": moments}
	var finite := true
	var same_surfaces := true
	var expected_mobility := true
	var metadata := true
	var valid_frames := 0
	var rendered_frames := PackedInt64Array()
	var first_rendered_frame := Engine.get_frames_drawn()
	for frame in MEASURED_FRAMES:
		var info: Dictionary = await read_buffers()
		rendered_frames.append(Engine.get_frames_drawn())
		if info.is_empty():
			continue
		valid_frames += 1
		metadata = metadata and bool(info.metadata)
		var values: PackedFloat32Array = info.floats
		var ids: PackedInt32Array = info.integers
		for region in pixel_regions:
			var means: PackedFloat64Array = accumulators[region].means
			var moments: PackedFloat64Array = accumulators[region].moments
			var pixels: PackedInt32Array = pixel_regions[region]
			for pixel in pixels.size():
				var offset := pixels[pixel]
				same_surfaces = same_surfaces and receiver_ids.get(ids[offset], "") == region
				if region == dynamic_region:
					expected_mobility = expected_mobility and values[offset + 5] > 0.5
				else:
					expected_mobility = expected_mobility and values[offset + 5] < 0.5
				for component in 3:
					var value := float(values[offset + 2 + component])
					if not is_finite(value):
						finite = false
						continue
					var i := pixel * 3 + component
					var delta := value - means[i]
					means[i] += delta / valid_frames
					moments[i] += delta * (value - means[i])
			accumulators[region].means = means
			accumulators[region].moments = moments
		if frame == MEASURED_FRAMES - 1:
			root.get_texture().get_image().save_png(out.path_join(label + ".png"))
	check(valid_frames == MEASURED_FRAMES, label + " captures all 96 settled GI frames")
	check(metadata and same_surfaces, label + " samples the same real receiver IDs on every frame")
	check(expected_mobility, label + " receivers retain expected Static/Dynamic classification")
	check(finite, label + " GI samples are finite")
	var measured: Dictionary = {}
	var total_variance := 0.0
	var total_luminance := 0.0
	var total_pixels := 0
	for region in pixel_regions:
		var means: PackedFloat64Array = accumulators[region].means
		var moments: PackedFloat64Array = accumulators[region].moments
		var variance_sum := 0.0
		var luminance_sum := 0.0
		for i in range(0, means.size(), 3):
			luminance_sum += means[i] * 0.2126 + means[i + 1] * 0.7152 + means[i + 2] * 0.0722
		for moment in moments:
			variance_sum += maxf(moment / maxi(valid_frames - 1, 1), 0.0)
		var count: int = pixel_regions[region].size()
		var rms := sqrt(variance_sum / maxi(count * 3, 1))
		var mean_luminance := luminance_sum / maxi(count, 1)
		measured[region] = {"pixels": count, "rgb_temporal_rms": rms, "mean_luminance": mean_luminance, "relative_rms": rms / maxf(mean_luminance, 1e-10)}
		total_variance += variance_sum
		total_luminance += luminance_sum
		total_pixels += count
	measured["all_receivers"] = {"pixels": total_pixels, "rgb_temporal_rms": sqrt(total_variance / maxi(total_pixels * 3, 1)), "mean_luminance": total_luminance / maxi(total_pixels, 1)}
	check(float(measured.all_receivers.mean_luminance) > 1e-6, label + " has measurable indirect illumination")
	frame_windows[label] = {"begin": first_rendered_frame, "end": Engine.get_frames_drawn(), "sampled_frames": Array(rendered_frames), "valid_frames": valid_frames}
	print("STATIC_NOISE_SAMPLE ", JSON.stringify({"label": label, "reactive": reactive, "frames": valid_frames, "regions": measured}))
	return measured

func compare_noise(legacy: Dictionary, reactive: Dictionary, scenario: String) -> Dictionary:
	var comparisons: Dictionary = {}
	for region in legacy:
		var before := float(legacy[region].rgb_temporal_rms)
		var after := float(reactive[region].rgb_temporal_rms)
		# Separate child processes use the same renderer-frame ray sequence;
		# 15% is retained as the original strict noise-regression allowance.
		# The absolute allowance is only 0.05% of receiver illumination, so a
		# nearly deterministic reference is not judged using a meaningless ratio.
		var noise_floor := maxf(1e-7, float(legacy[region].mean_luminance) * ABSOLUTE_NOISE_FRACTION)
		var limit := before * RELATIVE_NOISE_TOLERANCE + noise_floor
		comparisons[region] = {"ratio": after / maxf(before, 1e-10), "legacy_rms": before, "reactive_rms": after, "absolute_allowance": noise_floor, "limit": limit}
		if not baseline:
			check(after <= limit, scenario + " " + region + " reactive temporal noise stays within 15% of accumulated legacy GI")
	print("STATIC_NOISE_COMPARISON ", JSON.stringify({"scenario": scenario, "regions": comparisons}))
	return comparisons

func run_control(control: String) -> void:
	var reactive := control == "on"
	ProjectSettings.set_setting(GI_PREFIX + "screen_probe_denoiser_reactive", reactive)
	root.size = Vector2i(640, 360)
	root.use_taa = false
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	var settings := {
		"screen_probe_denoiser": 1,
		"screen_probe_denoiser_quality": 2,
		"screen_probe_candidate_count": 2,
		"screen_probe_detail_trace": true,
		"screen_probe_detail_trace_quality": 0,
		"screen_probe_directional_screen_radiance": true,
		"screen_probe_guided_sampling": true,
		"screen_probe_radiance_cache": 0,
		"screen_probe_radiance_cache_multibounce": false,
		"screen_probe_specular_reflections": false,
	}
	for setting in settings:
		ProjectSettings.set_setting(GI_PREFIX + setting, settings[setting])
	ProjectSettings.set_setting("rendering/lights_and_shadows/contact_shadow/enabled", false)
	ProjectSettings.set_setting("rendering/debug/visibility_buffer/test_pattern", 0)
	world = Node3D.new()
	root.add_child(world)
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.035, 0.045, 0.065)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.dynamic_gi_enabled = true
	env.dynamic_gi_cascades = 1
	env.dynamic_gi_min_cell_size = 0.2
	env.dynamic_gi_read_sky_light = true
	env.dynamic_gi_screen_probes_enabled = true
	env.dynamic_gi_screen_probe_mode = 0
	env.dynamic_gi_screen_probe_size = 4
	env.ss_shadow_enabled = false
	env.ssao_enabled = false
	env.ssil_enabled = false
	env.ssr_enabled = false
	env.glow_enabled = false
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	we.environment = env
	world.add_child(we)
	make_box(world, Vector3(0, -0.15, 0), Vector3(12, 0.3, 12), Color(0.65, 0.65, 0.65))
	make_box(world, Vector3(-3.5, 1.8, 0), Vector3(0.25, 3.6, 7), Color(0.75, 0.08, 0.035))
	make_box(world, Vector3(0, 1.8, -3.5), Vector3(7, 3.6, 0.25), Color(0.65, 0.65, 0.65))
	stopped_dynamic_box = make_box(world, Vector3(0.7, 0.65, -0.3), Vector3(1.4, 1.3, 1.6), Color(0.55, 0.55, 0.55))
	var emitter := make_box(world, Vector3(-2.2, 1.2, -1), Vector3(0.7, 1.5, 0.7), Color(0.9, 0.3, 0.08))
	var material := emitter.material_override as StandardMaterial3D
	material.emission_enabled = true
	material.emission = Color(3.5, 0.7, 0.12)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -25, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = false
	sun.shadow_contact_shadows_allow = false
	world.add_child(sun)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.look_at_from_position(Vector3(5, 4.5, 8), Vector3(-0.3, 0.8, -0.3))
	camera.current = true
	observer = preload("res://observer.gd").new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [observer]
	camera.compositor = compositor
	await frames(WARMUP_FRAMES)
	var initial: Dictionary = await read_buffers()
	check(not initial.is_empty(), "Stochastic SVGF exposes actual GI output")
	if initial.is_empty():
		world.queue_free()
		await frames(4)
		print("STATIC_NOISE_RESULT checks=%d failures=%d" % [checks, failures])
		quit(1)
		return
	choose_receivers(initial)
	var static_label := "02_reactive_on" if reactive else "01_reactive_off"
	var stationary := await measure(static_label, reactive)
	# A Dynamic mesh is not necessarily moving. Exercise its real motion and
	# subsequent stop before comparing settled accumulation on it and its floor.
	stopped_dynamic_box.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	for frame in 30:
		stopped_dynamic_box.position.x = lerpf(-1.3, 0.7, float(frame + 1) / 30.0)
		await frames(1)
	await frames(WARMUP_FRAMES)
	var stopped: Dictionary = await read_buffers()
	check(not stopped.is_empty(), "stopped Dynamic box retains actual GI buffers after motion")
	var stopped_result: Dictionary = {}
	if not stopped.is_empty():
		receiver_ids.clear()
		pixel_regions.clear()
		choose_receivers(stopped)
		var stopped_label := "04_stopped_dynamic_reactive_on" if reactive else "03_stopped_dynamic_reactive_off"
		stopped_result = await measure(stopped_label, reactive, "box")
	world.queue_free()
	await frames(4)
	root.get_texture().get_image()
	var windows := {"all_static": frame_windows.get(static_label, {}), "stopped_dynamic": frame_windows.get("04_stopped_dynamic_reactive_on" if reactive else "03_stopped_dynamic_reactive_off", {})}
	noise_results = {"test_scope": "temporal_denoiser_isolation", "control": control, "reactive": reactive, "checks": checks, "failures": failures, "warmup_frames": WARMUP_FRAMES, "measured_frames": MEASURED_FRAMES, "probe_size": 4, "candidate_count": 2, "svgf_quality": 2, "taa": false, "settings": settings, "all_static": stationary, "stopped_dynamic": stopped_result, "frame_windows": windows}
	FileAccess.open(out.path_join("child-measurements.json"), FileAccess.WRITE).store_string(JSON.stringify(noise_results, "\t"))
	print("STATIC_NOISE_CHILD_RESULT control=%s checks=%d failures=%d" % [control, checks, failures])
	quit(1 if failures else 0)

func child_control(control: String) -> Dictionary:
	var child_out := ProjectSettings.globalize_path(out.path_join("control_" + control))
	DirAccess.make_dir_recursive_absolute(child_out)
	var data_path := child_out.path_join("child-measurements.json")
	if FileAccess.file_exists(data_path):
		DirAccess.remove_absolute(data_path)
	var log_path := child_out.path_join("godot.log")
	var args := PackedStringArray([
		"--path", ProjectSettings.globalize_path("res://"),
		"--display-driver", "x11", "--audio-driver", "Dummy", "--position", "1280,800",
		"--log-file", log_path, "--script", get_script().resource_path,
		"--", "--out=" + child_out, "--noise-control=" + control,
	])
	var pid := OS.create_process(OS.get_executable_path(), args)
	check(pid > 0, control + " launches an isolated identical-sequence renderer")
	if pid <= 0:
		return {}
	var deadline := Time.get_ticks_msec() + 300000
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	var timed_out := OS.is_process_running(pid)
	if timed_out:
		OS.kill(pid)
	check(not timed_out, control + " child finishes within five minutes")
	check(OS.get_process_exit_code(pid) == 0, control + " child exits successfully")
	var log_text := FileAccess.get_file_as_string(log_path) if FileAccess.file_exists(log_path) else "ERROR: missing child log"
	check(not log_text.contains("ERROR:") and not log_text.contains("leaked"), control + " child has no renderer/script errors or leaks")
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(data_path)) if FileAccess.file_exists(data_path) else null
	check(parsed is Dictionary and parsed.get("control", "") == control, control + " child produces fresh measurement JSON")
	if not parsed is Dictionary:
		return {}
	check(int(parsed.get("failures", -1)) == 0 and int(parsed.get("checks", 0)) >= 28, control + " child passes all finite, identity, mobility and illumination checks")
	checks += int(parsed.get("checks", 0))
	failures += int(parsed.get("failures", 0))
	var image_labels := ["01_reactive_off", "03_stopped_dynamic_reactive_off"] if control == "off" else ["02_reactive_on", "04_stopped_dynamic_reactive_on"]
	for label in image_labels:
		var source := child_out.path_join(label + ".png")
		check(FileAccess.file_exists(source) and DirAccess.copy_absolute(source, ProjectSettings.globalize_path(out.path_join(label + ".png"))) == OK, label + " preserves the standard comparison image")
	return parsed

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--noise-control="):
			var control := arg.trim_prefix("--noise-control=")
			check(control in ["off", "on"], "child control is valid")
			if control in ["off", "on"]:
				await run_control(control)
			else:
				quit(1)
			return
	# The stochastic generator consumes the renderer's global frame number.
	# Sequential toggles in one process compare different correlated samples.
	# Fresh renderers instead execute exactly the same scene/frame sequence.
	var off := await child_control("off")
	var on := await child_control("on")
	if not off.is_empty() and not on.is_empty():
		for scenario in ["all_static", "stopped_dynamic"]:
			var off_window: Dictionary = off.frame_windows.get(scenario, {})
			var on_window: Dictionary = on.frame_windows.get(scenario, {})
			check(not off_window.is_empty() and off_window == on_window and int(off_window.get("valid_frames", 0)) == MEASURED_FRAMES, scenario + " pairs identical renderer-frame samples and finite frame counts")
		var legacy: Dictionary = off.all_static
		var reactive: Dictionary = on.all_static
		var comparisons := compare_noise(legacy, reactive, "all_static")
		var stopped_legacy: Dictionary = off.stopped_dynamic
		var stopped_reactive: Dictionary = on.stopped_dynamic
		var stopped_results := {"legacy": stopped_legacy, "reactive": stopped_reactive, "comparisons": compare_noise(stopped_legacy, stopped_reactive, "stopped_dynamic")}
		noise_results = {"test_scope": "temporal_denoiser_isolation", "warmup_frames": WARMUP_FRAMES, "measured_frames": MEASURED_FRAMES, "baseline": baseline, "probe_size": 4, "candidate_count": 2, "svgf_quality": 2, "taa": false, "settings": off.settings, "legacy": legacy, "reactive": reactive, "comparisons": comparisons, "stopped_dynamic": stopped_results, "frame_windows": {"off": off.frame_windows, "on": on.frame_windows}, "isolated_controls": true}
		FileAccess.open(out.path_join("measurements.json"), FileAccess.WRITE).store_string(JSON.stringify(noise_results, "\t"))
	print("STATIC_NOISE_RESULT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
