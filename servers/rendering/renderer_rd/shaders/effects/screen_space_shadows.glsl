#[compute]
#version 450

#VERSION_DEFINES

#define BRDF_NDOTL_BIAS 0.1
#define PI 3.14159265359

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba8, set = 0, binding = 0) uniform image2D color_image;
layout(set = 1, binding = 0) uniform sampler2D depth_image;
layout(set = 1, binding = 1) uniform sampler2D normal_image;
layout(set = 1, binding = 2) uniform sampler2D history_image;
layout(set = 1, binding = 3, r8) uniform writeonly image2D history_write_image;

layout(set = 2, binding = 0, std140) uniform Params {
    mat4 proj;
    mat4 proj_inv;
    mat4 view;
    mat4 view_inv;
} params;

layout(push_constant, std430) uniform PushConstant {
    vec2 screen_size_rcp;
    ivec2 screen_size;
    vec3 light_dir;
    float thickness;
    float max_dist;
    float intensity;
    uint sample_count;
    uint use_normals;
    
    vec3 camera_pos;
    uint frame_count;
    float light_radius;
    float thickness_falloff;
    float contact_shadow_distance;
    float shadow_fade_range;
    float history_blend;
    uint use_history;
    vec2 history_pad;
} push_constant;

// Funcții simple de hash compatibile
float hash12(vec2 p) {
    p = fract(p * vec2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

vec2 hash22(vec2 p) {
    p = fract(p * vec2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(vec2(p.x * p.y, p.y * p.x));
}

vec3 hash33(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx);
}

vec3 get_world_position(vec2 uv, float depth) {
    vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 view_pos = params.proj_inv * clip_pos;
    view_pos.xyz /= view_pos.w;
    return (params.view_inv * vec4(view_pos.xyz, 1.0)).xyz;
}

float get_linear_depth(vec3 world_pos) {
    return length(world_pos - push_constant.camera_pos);
}

bool is_valid_uv(vec2 uv) {
    return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
}

vec3 stable_temporal_noise(ivec2 pixel, int sample_index) {
    vec3 base = hash33(vec3(pixel + ivec2(sample_index * 23, sample_index * 11), 0.0));
    uint phase = push_constant.frame_count & 7u;
    vec3 temporal = hash33(vec3(pixel + ivec2(int(phase) * 17, int(phase) * 31), float(phase)));
    float blend = clamp(float(phase) * (1.0 / 7.0), 0.0, 1.0) * 0.6;
    return mix(base, temporal, blend);
}

// Screen space shadow raycasting simplificată dar eficientă
float screen_space_shadow_raycast(vec3 position_ws, vec3 ray_dir_ws, float initial_depth, 
                                 float linear_depth, float ray_length, vec2 position_ss, 
                                 int sample_count, out float fade) {

    if (initial_depth < 0.0001 || linear_depth <= 0.0) {
        fade = 0.0;
        return 0.0;
    }

    int samples = max(sample_count, 1);
    ivec2 pixel = ivec2(position_ss * push_constant.screen_size);
    
    // Parametri adaptivi
    float adaptive_ray_length = push_constant.max_dist * clamp(linear_depth * 0.5, 0.8, 2.0);
    float adaptive_thickness = push_constant.thickness * (1.0 / (1.0 + linear_depth * push_constant.thickness_falloff));
    
    float total_occlusion = 0.0;
    int valid_samples = 0;
    
    for (int i = 0; i < samples; i++) {
        // Jitter simplu folosind frame_count pentru temporal stability
        vec3 jitter = stable_temporal_noise(pixel, i);
        
        // Jitter pe direcția razei
        vec3 jittered_ray_dir = ray_dir_ws;
        if (push_constant.light_radius > 0.0) {
            // Perturbare simplă a direcției
            vec2 disk_jitter = hash22(vec2(jitter.x, jitter.y)) - 0.5;
            vec3 tangent = normalize(cross(ray_dir_ws, vec3(0.0, 1.0, 0.0)));
            if (length(tangent) < 0.001) {
                tangent = normalize(cross(ray_dir_ws, vec3(1.0, 0.0, 0.0)));
            }
            vec3 bitangent = cross(ray_dir_ws, tangent);
            jittered_ray_dir = normalize(ray_dir_ws + (tangent * disk_jitter.x + bitangent * disk_jitter.y) * push_constant.light_radius);
        }
        
        // Jitter pe start position
        float ray_bias = 0.015 + 0.005 * jitter.z;
        vec3 ray_start_ws = position_ws + jittered_ray_dir * ray_bias;
        vec3 ray_end_ws = ray_start_ws + jittered_ray_dir * adaptive_ray_length;
        
        // Transform to clip space
        vec4 clip_start = params.proj * params.view * vec4(ray_start_ws, 1.0);
        vec4 clip_end = params.proj * params.view * vec4(ray_end_ws, 1.0);
        
        // Perspective divide
        clip_start.xyz /= clip_start.w;
        clip_end.xyz /= clip_end.w;
        
        if (clip_start.z <= 0.0 || clip_end.z <= 0.0) continue;
        
        vec2 uv_start = clip_start.xy * 0.5 + 0.5;
        vec2 uv_end = clip_end.xy * 0.5 + 0.5;
        vec2 uv_delta = uv_end - uv_start;
        
        // Step size cu jitter
        float base_step_size = 1.0 / float(samples);
        float step_size = base_step_size * (0.8 + 0.4 * jitter.x);
        
        vec3 ray_start = vec3(uv_start, clip_start.z);
        vec3 ray_dir = vec3(uv_delta, clip_end.z - clip_start.z);
        
        // Jitter pe start position în spațiul UV
        float t = (float(i) + jitter.y) * step_size;
        
        bool found_occlusion = false;
        float hit_t = 1.0;
        
        for (int step = 0; step < samples; step++) {
            vec3 sample_pos = ray_start + t * ray_dir;
            
            if (!is_valid_uv(sample_pos.xy)) break;
            
            float sample_depth = textureLod(depth_image, sample_pos.xy, 0.0).r;
            float depth_diff = sample_depth - sample_pos.z;
            
            if (depth_diff > 0.0 && depth_diff < adaptive_thickness && sample_pos.z > 0.0) {
                hit_t = t;
                found_occlusion = true;
                break;
            }
            
            t += step_size;
            if (t > 1.0) break;
        }
        
        if (found_occlusion) {
            float progress = hit_t;
            float occlusion = 1.0 - smoothstep(0.0, 1.0, progress);
            total_occlusion += occlusion;
            valid_samples++;
        }
    }
    
    if (valid_samples > 0) {
        float occlusion = total_occlusion / float(valid_samples);
        
        // Screen edge fade
        vec2 centered_uv = position_ss * 2.0 - 1.0;
        float edge_fade = 1.0 - smoothstep(0.7, 1.0, max(abs(centered_uv.x), abs(centered_uv.y)));
        
        // Distance-based fade
        float fade_range = push_constant.shadow_fade_range;
        float distance_fade = 1.0;
        if (fade_range > 0.0001) {
            distance_fade = 1.0 - smoothstep(fade_range * 0.7, fade_range, linear_depth);
        }
        
        fade = occlusion * edge_fade * distance_fade;
        return 1.0;
    }
    
    fade = 0.0;
    return 0.0;
}

void main() {
    ivec2 iuv = ivec2(gl_GlobalInvocationID.xy);

    if (any(greaterThanEqual(iuv, push_constant.screen_size))) {
        return;
    }

    vec2 uv = (vec2(iuv) + 0.5) * push_constant.screen_size_rcp;
    vec4 orig_color = imageLoad(color_image, iuv);

    float depth = texelFetch(depth_image, iuv, 0).r;
    if (depth >= 0.999) {
        return;
    }

    vec3 world_pos = get_world_position(uv, depth);
    float linear_depth = get_linear_depth(world_pos);
    
    vec3 light_dir = normalize(push_constant.light_dir);
    
    // Normal handling
    vec3 normal_ws = vec3(0.0, 0.0, 1.0);
    if (push_constant.use_normals != 0u) {
        vec4 encoded = texelFetch(normal_image, iuv, 0);
        if (length(encoded.xyz) > 0.1) {
            vec3 normal_vs = normalize(encoded.xyz * 2.0 - 1.0);
            normal_ws = normalize(mat3(params.view_inv) * normal_vs);
            float ndotl = dot(normal_ws, -light_dir);
            if (ndotl <= BRDF_NDOTL_BIAS) {
                imageStore(color_image, iuv, orig_color);
                return;
            }
        }
        world_pos += normal_ws * 0.015;
    }

    float fade = 0.0;
    int samples = int(push_constant.sample_count);
    float history_shadow = 0.0;
    if (push_constant.use_history != 0u) {
        history_shadow = texelFetch(history_image, iuv, 0).r;
    }
    
    float shadow = screen_space_shadow_raycast(world_pos, -light_dir, depth, linear_depth, 
                                              push_constant.max_dist, uv, samples, fade);

    float shadow_strength = clamp(fade * shadow * push_constant.intensity, 0.0, 1.0);
    if (push_constant.use_history != 0u) {
        shadow_strength = mix(history_shadow, shadow_strength, push_constant.history_blend);
    }

    vec3 out_color = orig_color.rgb;
    if (shadow_strength > 0.01) {
        out_color = orig_color.rgb * (1.0 - shadow_strength * 0.9);
    }

    imageStore(color_image, iuv, vec4(out_color, orig_color.a));

    if (push_constant.use_history != 0u) {
        imageStore(history_write_image, iuv, vec4(shadow_strength, 0.0, 0.0, 0.0));
    }
}
