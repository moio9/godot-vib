#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r16ui, set = 0, binding = 0) uniform readonly uimage2D vb_aux;
// Edge coordinates are stored as coord + 1 in RG16UI; zero is the invalid sentinel.
layout(rg16ui, set = 0, binding = 1) uniform writeonly uimage2D mesh_edges;
layout(set = 0, binding = 2) uniform sampler2D mesh_depth;

layout(push_constant, std430) uniform Params {
	ivec2 resolution;
	float depth_tolerance;
	int require_pair;
}
params;

const int THREADCOUNT = 8;
const int TILE_BORDER = 1;
const int TILE_SIZE = THREADCOUNT + TILE_BORDER * 2;

shared vec2 cached_mask[TILE_SIZE * TILE_SIZE];
shared float cached_depth[TILE_SIZE * TILE_SIZE];

int coord_to_index(ivec2 coord) {
	coord = clamp(coord, ivec2(0), ivec2(TILE_SIZE - 1));
	return coord.y * TILE_SIZE + coord.x;
}

const ivec2 neighbor_offsets[8] = ivec2[8](
		ivec2(-1, 0),
		ivec2(1, 0),
		ivec2(0, -1),
		ivec2(0, 1),
		ivec2(-1, -1),
		ivec2(-1, 1),
		ivec2(1, -1),
		ivec2(1, 1));

vec2 unpack_visibility_aux(uint packed_value) {
	uint group_id = (packed_value >> 8u) & 0xFFu;
	uint weight_bits = packed_value & 0xFFu;
	int weight_snorm = weight_bits >= 128u ? int(weight_bits) - 256 : int(weight_bits);
	float weight = clamp(float(weight_snorm) / 127.0, -1.0, 1.0);
	return vec2(float(group_id) / 255.0, weight);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 resolution = params.resolution;
	bool pixel_in_bounds = all(lessThan(pixel, resolution));

	ivec2 tile_origin = ivec2(gl_WorkGroupID.xy) * THREADCOUNT - ivec2(TILE_BORDER);
	ivec2 local_id = ivec2(gl_LocalInvocationID.xy);

	for (int y = local_id.y; y < TILE_SIZE; y += THREADCOUNT) {
		for (int x = local_id.x; x < TILE_SIZE; x += THREADCOUNT) {
			ivec2 sample_pixel = clamp(tile_origin + ivec2(x, y), ivec2(0), resolution - ivec2(1));
			vec2 value = vec2(0.0);

	vec2 aux = unpack_visibility_aux(imageLoad(vb_aux, sample_pixel).x);
	float depth_value = texelFetch(mesh_depth, sample_pixel, 0).x;

	float id_quantized = aux.x;
	if (id_quantized > 0.0) {
		float raw_weight = aux.y;
		float weight = min(raw_weight, 1.0);
		value = vec2(id_quantized, weight);
	}

			int cache_idx = coord_to_index(ivec2(x, y));
			cached_mask[cache_idx] = value;
			cached_depth[cache_idx] = depth_value;
		}
	}

	barrier();

	if (!pixel_in_bounds) {
		return;
	}

	ivec2 local_pixel = local_id + ivec2(TILE_BORDER);
	int current_index = coord_to_index(local_pixel);
	vec2 current = cached_mask[current_index];
	float current_depth = cached_depth[current_index];

	float current_id = current.x;
	if (current_id <= 0.0) {
		imageStore(mesh_edges, pixel, uvec4(0u));
		return;
	}

	uvec4 edge_store = uvec4(0u);
	for (int i = 0; i < 8; i++) {
		int neighbor_idx = coord_to_index(local_pixel + neighbor_offsets[i]);
		vec2 neighbor = cached_mask[neighbor_idx];
		float neighbor_id = neighbor.x;
		if (neighbor_id <= 0.0 || neighbor_id == current_id) {
			continue;
		}

		float neighbor_depth = cached_depth[neighbor_idx];
		if (abs(neighbor_depth - current_depth) > params.depth_tolerance) {
			continue;
		}

		if (params.require_pair != 0 && neighbor.y <= 0.0) {
			continue;
		}

		ivec2 neighbor_pixel = clamp(pixel + neighbor_offsets[i], ivec2(0), resolution - ivec2(1));
		edge_store.xy = uvec2(neighbor_pixel + ivec2(1));
		break;
	}

	imageStore(mesh_edges, pixel, edge_store);
}
