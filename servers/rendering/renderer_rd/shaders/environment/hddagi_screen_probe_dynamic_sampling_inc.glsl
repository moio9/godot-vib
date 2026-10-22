// Select the stochastic diffuse ray count before sampling any current ray.
// Current geometry and validated previous influence are independent of those
// samples, so allocating extra rays does not select brighter ray outcomes.

bool stochastic_dynamic_view_position(vec2 uv, float depth, out vec3 r_view_position) {
	r_view_position = vec3(0.0);
	if (any(isnan(uv)) || any(isinf(uv)) || any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0))) ||
			isnan(depth) || isinf(depth) || depth <= 0.0 || depth > 1.0) {
		return false;
	}
	vec4 view_h = scene_data.inv_projection[params.view_index] * vec4(uv * 2.0 - 1.0, depth, 1.0);
	if (any(isnan(view_h)) || any(isinf(view_h)) || abs(view_h.w) < 1e-6) {
		return false;
	}
	r_view_position = view_h.xyz / view_h.w;
	return !any(isnan(r_view_position)) && !any(isinf(r_view_position)) && r_view_position.z < -1e-5;
}

bool stochastic_dynamic_previous_influence(ivec2 origin_position, vec3 origin_view) {
	if ((params.flags & SCREEN_PROBE_FLAG_DYNAMIC_SAMPLING_HISTORY_VALID) == 0u) {
		return false;
	}
	ivec2 metadata_size = textureSize(usampler2D(directional_surface_history, linear_sampler), 0);
	ivec2 previous_metadata_size = textureSize(usampler2D(directional_previous_surface_history, linear_sampler), 0);
	ivec2 previous_depth_size = textureSize(sampler2D(directional_previous_depth_buffer, linear_sampler), 0);
	ivec2 signal_size = textureSize(sampler2D(dynamic_previous_signal_input, linear_sampler), 0);
	if (any(notEqual(metadata_size, params.screen_size)) || any(notEqual(previous_metadata_size, params.screen_size)) ||
			any(notEqual(previous_depth_size, params.screen_size)) || any(lessThanEqual(signal_size, ivec2(0)))) {
		return false;
	}
	uvec2 surface = texelFetch(usampler2D(directional_surface_history, linear_sampler), origin_position, 0).xy;
	if (surface.y == 0u) {
		return false;
	}
	// This path is only used for static receivers. Camera reprojection therefore
	// locates the same world point without depending on moving-object velocity.
	vec3 world_position = (scene_data.cam_transform * vec4(origin_view, 1.0)).xyz;
	vec3 previous_view = (scene_data.previous_cam_inv_transform * vec4(world_position, 1.0)).xyz;
	vec4 previous_clip = scene_data.previous_projection[params.view_index] * vec4(previous_view, 1.0);
	if (any(isnan(previous_clip)) || any(isinf(previous_clip)) || previous_clip.w <= 1e-6) {
		return false;
	}
	vec2 previous_uv = previous_clip.xy / previous_clip.w * 0.5 + 0.5;
	vec3 expected_previous_view;
	if (!hddagi_surface_previous_view(surface, previous_uv, scene_data.previous_inv_projection[params.view_index], expected_previous_view)) {
		return false;
	}
	float depth_tolerance = 0.01 + 0.005 * abs(expected_previous_view.z);
	if (any(isnan(previous_view)) || any(isinf(previous_view)) || abs(previous_view.z - expected_previous_view.z) > depth_tolerance) {
		return false;
	}
	ivec2 previous_pixel = ivec2(floor(previous_uv * vec2(previous_metadata_size)));
	if (texelFetch(usampler2D(directional_previous_surface_history, linear_sampler), previous_pixel, 0).y != surface.y) {
		return false;
	}
	float previous_depth = texelFetch(sampler2D(directional_previous_depth_buffer, linear_sampler), previous_pixel, 0).r;
	vec4 actual_previous_h = scene_data.previous_inv_projection[params.view_index] *
			vec4((vec2(previous_pixel) + 0.5) / vec2(previous_depth_size) * 2.0 - 1.0, previous_depth, 1.0);
	if (isnan(previous_depth) || isinf(previous_depth) || previous_depth <= 0.0 || previous_depth > 1.0 ||
			any(isnan(actual_previous_h)) || any(isinf(actual_previous_h)) || abs(actual_previous_h.w) < 1e-6 ||
			abs(actual_previous_h.z / actual_previous_h.w - expected_previous_view.z) > depth_tolerance) {
		return false;
	}
	ivec2 signal_pixel = min(ivec2(floor(previous_uv * vec2(signal_size))), signal_size - ivec2(1));
	float influence = texelFetch(sampler2D(dynamic_previous_signal_input, linear_sampler), signal_pixel, 0).a;
	return !isnan(influence) && !isinf(influence) && influence > 0.001;
}

bool stochastic_dynamic_nearby_surface(ivec2 origin_position, vec3 origin_view, float radius) {
	ivec2 depth_size = textureSize(sampler2D(detail_hiz_buffer, linear_sampler), 0);
	ivec2 normal_size = textureSize(sampler2D(detail_normal_roughness_buffer, linear_sampler), 0);
	if (any(notEqual(depth_size, params.screen_size)) || any(notEqual(normal_size, params.screen_size))) {
		return false;
	}
	// Project a bounding cube rather than a single radius at the receiver depth:
	// it encloses the sphere in perspective and orthographic cameras. The actual
	// view-space distance check below rejects geometry outside that sphere.
	vec2 minimum_uv = vec2(1.0);
	vec2 maximum_uv = vec2(0.0);
	bool crosses_near_plane = origin_view.z + radius >= -1e-5;
	if (!crosses_near_plane) {
		for (int z = -1; z <= 1; z += 2) {
			for (int y = -1; y <= 1; y += 2) {
				for (int x = -1; x <= 1; x += 2) {
					vec4 clip = scene_data.projection[params.view_index] * vec4(origin_view + vec3(x, y, z) * radius, 1.0);
					if (any(isnan(clip)) || any(isinf(clip)) || clip.w <= 1e-6) {
						return false;
					}
					vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
					minimum_uv = min(minimum_uv, uv);
					maximum_uv = max(maximum_uv, uv);
				}
			}
		}
	} else {
		minimum_uv = vec2(0.0);
		maximum_uv = vec2(1.0);
	}
	vec2 origin_uv = (vec2(origin_position) + 0.5) / vec2(params.screen_size);
	vec2 radius_uv = max(abs(maximum_uv - origin_uv), abs(origin_uv - minimum_uv));
	for (int y = -3; y <= 3; y++) {
		for (int x = -3; x <= 3; x++) {
			vec2 uv = origin_uv + vec2(x, y) / 3.0 * radius_uv;
			if (any(isnan(uv)) || any(isinf(uv)) || any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) {
				continue;
			}
			ivec2 pixel = ivec2(floor(uv * vec2(depth_size)));
			vec4 normal_roughness = texelFetch(sampler2D(detail_normal_roughness_buffer, linear_sampler), pixel, 0);
			if (any(isnan(normal_roughness)) || any(isinf(normal_roughness)) || normal_roughness.a <= 0.5) {
				continue;
			}
			float depth = texelFetch(sampler2D(detail_hiz_buffer, linear_sampler), pixel, 0).r;
			vec3 view_position;
			if (stochastic_dynamic_view_position((vec2(pixel) + 0.5) / vec2(depth_size), depth, view_position) &&
					dot(view_position - origin_view, view_position - origin_view) <= radius * radius) {
				return true;
			}
		}
	}
	return false;
}

uint stochastic_dynamic_candidate_count(ivec2 origin_position, float origin_depth, uint base_candidate_count) {
	if ((params.flags & SCREEN_PROBE_FLAG_DYNAMIC_SAMPLING) == 0u) {
		return base_candidate_count;
	}
	uint target_candidate_count = max(base_candidate_count, clamp(params.dynamic_candidate_count, 1u, 8u));
	if (target_candidate_count == base_candidate_count ||
			isnan(params.dynamic_sampling_distance) || isinf(params.dynamic_sampling_distance) || params.dynamic_sampling_distance <= 0.0 ||
			isnan(params.dynamic_sampling_radius) || isinf(params.dynamic_sampling_radius) || params.dynamic_sampling_radius < 0.0 ||
			any(lessThanEqual(params.screen_size, ivec2(0))) || any(lessThan(origin_position, ivec2(0))) || any(greaterThanEqual(origin_position, params.screen_size))) {
		return base_candidate_count;
	}
	vec3 origin_view;
	if (!stochastic_dynamic_view_position((vec2(origin_position) + 0.5) / vec2(params.screen_size), origin_depth, origin_view)) {
		return base_candidate_count;
	}
	float camera_distance = length(origin_view);
	if (!(camera_distance < params.dynamic_sampling_distance)) {
		return base_candidate_count;
	}
	ivec2 normal_size = textureSize(sampler2D(detail_normal_roughness_buffer, linear_sampler), 0);
	if (any(notEqual(normal_size, params.screen_size))) {
		return base_candidate_count;
	}
	vec4 normal_roughness = texelFetch(sampler2D(detail_normal_roughness_buffer, linear_sampler), origin_position, 0);
	if (any(isnan(normal_roughness)) || any(isinf(normal_roughness))) {
		return base_candidate_count;
	}
	bool eligible = normal_roughness.a > 0.5;
	if (!eligible) {
		eligible = stochastic_dynamic_previous_influence(origin_position, origin_view) ||
				(params.dynamic_sampling_radius > 0.0 && stochastic_dynamic_nearby_surface(origin_position, origin_view, params.dynamic_sampling_radius));
	}
	if (!eligible) {
		return base_candidate_count;
	}
	float distance_weight = 1.0 - smoothstep(params.dynamic_sampling_distance * 0.75, params.dynamic_sampling_distance, camera_distance);
	uint extra_candidates = uint(floor(float(target_candidate_count - base_candidate_count) * distance_weight + 0.5));
	return base_candidate_count + extra_candidates;
}

vec2 stochastic_dynamic_candidate_sample(uvec2 probe_position, uint candidate, uint base_candidate_count) {
	if (candidate < base_candidate_count) {
		// Preserve every original candidate exactly when allocating extra work.
		return sample_temporally_permuted_r2_sequence(probe_position, params.frame_index * base_candidate_count + candidate, 0x44544330u);
	}
	// A separate stream and fixed stride make added samples independent of the
	// varying budget, and prevent sample identities shifting near the fade band.
	return sample_temporally_permuted_r2_sequence(probe_position, params.frame_index * 8u + candidate, 0x44594e41u);
}
