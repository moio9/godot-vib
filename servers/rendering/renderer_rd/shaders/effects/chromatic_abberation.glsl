#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D color_image;
layout(rgba8, set = 1, binding = 0) uniform image2D dest_image;

layout(push_constant, std430) uniform Params {
    vec2 screen_size_rcp;
    float strength;
} params;

void main() {

    if (any(greaterThanEqual(vec2(gl_GlobalInvocationID.xy) * params.screen_size_rcp, vec2(1.0)))) { // too large, do nothing
        return;
    }

    vec2 uv = (vec2(gl_GlobalInvocationID.xy)+0.5) * params.screen_size_rcp;

    vec4 r0, r1, r2;
    r0.yw = texture(color_image, uv).yw;
    r1.x = params.strength + params.strength;
    r1.yz = r1.xx * params.screen_size_rcp + 1.0;
    r1.xw = -r1.xx * params.screen_size_rcp + 1.0;
    r2.xy = uv - 0.5;
    r1.yz = r2.xy * r1.yz + 0.5;
    r1.xw = r2.xy * r1.xw + 0.5;
    r0.z = texture(color_image, r1.xw).z;
    r0.x = texture(color_image, r1.yz).x; // ca'd image
    imageStore(dest_image, ivec2(gl_GlobalInvocationID.xy), r0);
}
