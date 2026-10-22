// Surface motion is emitted by the opaque prepass: previous raster depth and
// a stable geometry identity. Motion vectors identify the previous pixel; depth
// and identity reject occluded, newly exposed, and unrelated surfaces there.
bool hddagi_surface_previous_view(uvec2 surface, vec2 previous_uv, mat4 previous_inv_projection, out vec3 r_previous_view) {
    r_previous_view = vec3(0.0);
    float depth = uintBitsToFloat(surface.x);
    if (surface.y == 0u || isnan(depth) || isinf(depth) || depth <= 0.0 || depth > 1.0 ||
            any(isnan(previous_uv)) || any(isinf(previous_uv)) ||
            any(lessThan(previous_uv, vec2(0.0))) || any(greaterThanEqual(previous_uv, vec2(1.0)))) {
        return false;
    }
    vec4 view_h = previous_inv_projection * vec4(previous_uv * 2.0 - 1.0, depth, 1.0);
    if (any(isnan(view_h)) || any(isinf(view_h)) || abs(view_h.w) < 1e-6) {
        return false;
    }
    r_previous_view = view_h.xyz / view_h.w;
    return !any(isnan(r_previous_view)) && !any(isinf(r_previous_view)) && r_previous_view.z < -1e-5;
}
