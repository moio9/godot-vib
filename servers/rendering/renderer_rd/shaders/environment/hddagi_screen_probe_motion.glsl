#[compute]

#version 450

#VERSION_DEFINES

#include "hddagi_surface_history_inc.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	uvec4 control;
	vec4 tuning;
	vec4 atrous;
}
params;

layout(set = 1, binding = 0, std140) uniform FrameData {
	mat4 current_inv_projection;
	mat4 previous_inv_projection;
	mat4 current_view_to_previous_view;
	mat4 current_view_to_world;
	mat4 previous_view_to_world;
	vec4 taa_jitter;
}
frame_data;

layout(set = 0, binding = 0) uniform texture2D motion_input;
layout(set = 0, binding = 1) uniform texture2D current_view_z_input;
layout(set = 0, binding = 2) uniform utexture2D current_surface_history;
layout(set = 0, binding = 3) uniform sampler nearest_sampler;
layout(r32ui, set = 0, binding = 4) uniform restrict coherent uimage2D dynamic_motion_output;

bool motion_finite(vec4 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool motion_reconstruct_view(vec2 uv, float view_z, out vec3 r_view) {
	vec2 ndc = uv * 2.0 - 1.0;
	if ((params.control.w & 1u) == 0u) {
		vec3 point_h = (frame_data.current_inv_projection * vec4(ndc, 0.5, 1.0)).xyz;
		if (any(isnan(point_h)) || any(isinf(point_h)) || abs(point_h.z) <= 1e-7) {
			return false;
		}
		r_view = point_h * (-view_z / point_h.z);
		return !any(isnan(r_view)) && !any(isinf(r_view));
	}
	vec4 point_a_h = frame_data.current_inv_projection * vec4(ndc, 0.25, 1.0);
	vec4 point_b_h = frame_data.current_inv_projection * vec4(ndc, 0.75, 1.0);
	if (!motion_finite(point_a_h) || !motion_finite(point_b_h) || abs(point_a_h.w) <= 1e-7 || abs(point_b_h.w) <= 1e-7) {
		return false;
	}
	vec3 point_a = point_a_h.xyz / point_a_h.w;
	vec3 ray = point_b_h.xyz / point_b_h.w - point_a;
	if (any(isnan(ray)) || any(isinf(ray)) || abs(ray.z) <= 1e-7) {
		return false;
	}
	r_view = point_a + ray * ((-view_z - point_a.z) / ray.z);
	return !any(isnan(r_view)) && !any(isinf(r_view));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = textureSize(sampler2D(motion_input, nearest_sampler), 0);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec4 motion = texelFetch(sampler2D(motion_input, nearest_sampler), pixel, 0);
	// Only actual geometry movement matters. A stationary Dynamic mesh must
	// retain temporal accumulation even while the camera moves around it.
	if (!motion_finite(motion) || motion.w <= 1.0) {
		return;
	}
	vec2 surface_offset = vec2(motion.z, motion.w - 2.0);
	if (any(greaterThan(abs(surface_offset), vec2(1.0)))) {
		return;
	}
	float view_z = texelFetch(sampler2D(current_view_z_input, nearest_sampler), pixel, 0).r;
	if (isnan(view_z) || isinf(view_z) || view_z <= 0.0 || view_z > params.tuning.x) {
		return;
	}
	vec2 surface_uv = (vec2(pixel) + 0.5) / vec2(size) + surface_offset;
	ivec2 surface_size = textureSize(usampler2D(current_surface_history, nearest_sampler), 0);
	ivec2 surface_pixel = ivec2(floor(surface_uv * vec2(surface_size)));
	if (any(lessThan(surface_pixel, ivec2(0))) || any(greaterThanEqual(surface_pixel, surface_size))) {
		return;
	}
	uvec2 surface = texelFetch(usampler2D(current_surface_history, nearest_sampler), surface_pixel, 0).xy;
	vec3 current_view;
	if (!motion_reconstruct_view(surface_uv, view_z, current_view)) {
		return;
	}
	// The renderer's velocity is previous UV minus current UV. Its jitter
	// correction and previous vertex depth match the receiver history pass.
	vec2 previous_uv = surface_uv + motion.xy + (frame_data.taa_jitter.zw - frame_data.taa_jitter.xy) * 0.5;
	vec3 observed_previous_view;
	if (!hddagi_surface_previous_view(surface, previous_uv, frame_data.previous_inv_projection, observed_previous_view)) {
		// Unsupported/new geometry keeps the conservative temporal response.
		return;
	}
	vec3 expected_previous_view = (frame_data.current_view_to_previous_view * vec4(current_view, 1.0)).xyz;
	vec3 movement = observed_previous_view - expected_previous_view;
	float tolerance = 0.002 + 1e-4 * view_z;
	if (!any(isnan(movement)) && !any(isinf(movement)) && dot(movement, movement) > tolerance * tolerance) {
		imageAtomicOr(dynamic_motion_output, ivec2(0), 1u);
	}
}
