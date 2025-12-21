///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2016, Intel Corporation
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of
// the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// File changes (yyyy-mm-dd)
// 2016-09-07: filip.strugar@intel.com: first commit
// 2020-12-05: clayjohn: convert to Vulkan and Godot
// 2021-05-27: clayjohn: convert SSAO to SSIL
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16, set = 0, binding = 0) uniform restrict writeonly image2D dest_image;
layout(rgba16, set = 0, binding = 1) uniform restrict writeonly image2D dest_history;

layout(set = 1, binding = 0) uniform sampler2DArray source_texture;
layout(r8, set = 2, binding = 0) uniform restrict readonly image2DArray source_edges;
layout(set = 3, binding = 0) uniform sampler2D source_history;
layout(set = 4, binding = 0) uniform sampler2D source_depth;

layout(push_constant, std430) uniform Params {
	float inv_sharpness;
	uint size_modifier;
	vec2 pixel_size;
	float temporal_decay;
	uint use_history;
	vec2 pad;
	mat4 reprojection;
}
params;

vec4 unpack_edges(float p_packed_val) {
	uint packed_val = uint(p_packed_val * 255.5);
	vec4 edgesLRTB;
	edgesLRTB.x = float((packed_val >> 6) & 0x03) / 3.0;
	edgesLRTB.y = float((packed_val >> 4) & 0x03) / 3.0;
	edgesLRTB.z = float((packed_val >> 2) & 0x03) / 3.0;
	edgesLRTB.w = float((packed_val >> 0) & 0x03) / 3.0;

	return clamp(edgesLRTB + params.inv_sharpness, 0.0, 1.0);
}

void main() {
	ivec2 ssC = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(ssC, ivec2(1.0 / params.pixel_size)))) { //too large, do nothing
		return;
	}

#ifdef MODE_SMART
	uvec2 pix_pos = uvec2(gl_GlobalInvocationID.xy);
	vec2 uv = (gl_GlobalInvocationID.xy + vec2(0.5)) * params.pixel_size;

	// calculate index in the four deinterleaved source array texture
	int mx = int(pix_pos.x % 2);
	int my = int(pix_pos.y % 2);
	int index_center = mx + my * 2; // center index
	int index_horizontal = (1 - mx) + my * 2; // neighboring, horizontal
	int index_vertical = mx + (1 - my) * 2; // neighboring, vertical
	int index_diagonal = (1 - mx) + (1 - my) * 2; // diagonal

	vec4 color = texelFetch(source_texture, ivec3(pix_pos / uvec2(params.size_modifier), index_center), 0);

	vec4 edgesLRTB = unpack_edges(imageLoad(source_edges, ivec3(pix_pos / uvec2(params.size_modifier), index_center)).r);

	// convert index shifts to sampling offsets
	float fmx = float(mx);
	float fmy = float(my);

	// in case of an edge, push sampling offsets away from the edge (towards pixel center)
	float fmxe = (edgesLRTB.y - edgesLRTB.x);
	float fmye = (edgesLRTB.w - edgesLRTB.z);

	// calculate final sampling offsets and sample using bilinear filter
	vec2 uv_horizontal = (gl_GlobalInvocationID.xy + vec2(0.5) + vec2(fmx + fmxe - 0.5, 0.5 - fmy)) * params.pixel_size;
	vec4 color_horizontal = textureLod(source_texture, vec3(uv_horizontal, index_horizontal), 0.0);
	vec2 uv_vertical = (gl_GlobalInvocationID.xy + vec2(0.5) + vec2(0.5 - fmx, fmy - 0.5 + fmye)) * params.pixel_size;
	vec4 color_vertical = textureLod(source_texture, vec3(uv_vertical, index_vertical), 0.0);
	vec2 uv_diagonal = (gl_GlobalInvocationID.xy + vec2(0.5) + vec2(fmx - 0.5 + fmxe, fmy - 0.5 + fmye)) * params.pixel_size;
	vec4 color_diagonal = textureLod(source_texture, vec3(uv_diagonal, index_diagonal), 0.0);

	// reduce weight for samples near edge - if the edge is on both sides, weight goes to 0
	vec4 blendWeights;
	blendWeights.x = 1.0;
	blendWeights.y = (edgesLRTB.x + edgesLRTB.y) * 0.5;
	blendWeights.z = (edgesLRTB.z + edgesLRTB.w) * 0.5;
	blendWeights.w = (blendWeights.y + blendWeights.z) * 0.5;

	// calculate weighted average
	float blendWeightsSum = dot(blendWeights, vec4(1.0, 1.0, 1.0, 1.0));
	color += color_horizontal * blendWeights.y;
	color += color_vertical * blendWeights.z;
	color += color_diagonal * blendWeights.w;
	color /= blendWeightsSum;

#else // !MODE_SMART

	vec2 uv = (gl_GlobalInvocationID.xy + vec2(0.5)) * params.pixel_size;
#ifdef MODE_HALF
	vec4 a = textureLod(source_texture, vec3(uv, 0), 0.0);
	vec4 d = textureLod(source_texture, vec3(uv, 3), 0.0);
	vec4 color = (a + d) * 0.5; // Changed avg to color for consistency

#else
	vec4 a = textureLod(source_texture, vec3(uv, 0), 0.0);
	vec4 b = textureLod(source_texture, vec3(uv, 1), 0.0);
	vec4 c = textureLod(source_texture, vec3(uv, 2), 0.0);
	vec4 d = textureLod(source_texture, vec3(uv, 3), 0.0);
	vec4 color = (a + b + c + d) * 0.25; // Changed avg to color for consistency

#endif
#endif

	// --- Temporal Accumulation Logic ---
	if (params.use_history > 0) {
		float depth = textureLod(source_depth, uv, 0.0).r;
		if (depth < 1.0) { // If not skybox (Godot uses reverse-z or standard? Vulkan is usually 0..1 or 1..0 depending on setup. Godot uses 0..1 usually. Assuming < 1.0 means valid geometry)
			// Reproject
			vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
			vec4 prev_clip = params.reprojection * clip_pos;
			vec2 prev_uv = (prev_clip.xy / prev_clip.w) * 0.5 + 0.5;

			if (all(greaterThanEqual(prev_uv, vec2(0.0))) && all(lessThanEqual(prev_uv, vec2(1.0)))) {
				vec4 history = textureLod(source_history, prev_uv, 0.0);
				
				// Decay logic:
				// If history is brighter than current, it means light disappeared. Fade it out slowly.
				// If current is brighter, accept it quickly (responsiveness).
				
				float history_lum = dot(history.rgb, vec3(0.299, 0.587, 0.114));
				float current_lum = dot(color.rgb, vec3(0.299, 0.587, 0.114));
				
				float blend;
				if (current_lum > history_lum) {
					// Light turned ON: Fast reaction
					// Modified: Depend on temporal_decay for stability. Small decay = High blend (slow update).
					// Multiplier 20.0 ensures that at default decay (0.01) blend is ~0.8.
					blend = clamp(1.2 - (params.temporal_decay), 0.2, 0.98);
				} else {
					// Light turned OFF: Slow fade (User's desired persistence)
					// Apply decay to history first
					history.rgb *= (1.0 - params.temporal_decay); 
					blend = 0.999; // 98.5% history (~3s fade at 60fps)
				}
				
				color = mix(color, history, blend);
			}
		}
	}

	imageStore(dest_image, ssC, color);
	imageStore(dest_history, ssC, color);
}
