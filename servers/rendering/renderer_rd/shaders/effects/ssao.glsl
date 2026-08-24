#[compute]

#version 450

#VERSION_DEFINES

#ifdef USE_VISIBILITY_BITMASK
#include "ssao_visibility_bitmask_inc.glsl"
#else
#include "ssao_standard_inc.glsl"
#endif
