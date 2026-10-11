#ifdef GODOT_VERSION_MAJOR
#ifdef GODOT_VERSION_MINOR
#ifdef GODOT_VERSION_PATCH
vec4 version_include_color() {
    return vec4(0.0, 1.0, 0.0, 1.0);
}
#else
#error Engine patch version is unavailable in shader includes.
#endif
#else
#error Engine minor version is unavailable in shader includes.
#endif
#else
#error Engine major version is unavailable in shader includes.
#endif
