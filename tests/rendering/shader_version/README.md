# Engine version in shader preprocessor branches

This fork provides the built-in numeric defines `GODOT_VERSION_MAJOR`,
`GODOT_VERSION_MINOR`, and `GODOT_VERSION_PATCH` in text shaders and shader
includes. Their values come from the engine binary compiling the shader,
including export templates. No script or uniform is required.

```glsl
#if GODOT_VERSION_MAJOR > 4 || (GODOT_VERSION_MAJOR == 4 && GODOT_VERSION_MINOR >= 8)
// Code compiled on Godot 4.8 and newer.
#else
// Code compiled on older versions of this fork with these defines.
#endif
```

Engines without this addition do not provide these defines. Use an outer
`#ifdef GODOT_VERSION_MAJOR` when a shader must also load on those engines.
This addition does not add preprocessing to GDScript.

Run the regression with a graphical Vulkan Forward+ display:

```sh
bin/godot.linuxbsd.editor.x86_64 --path tests/rendering/shader_version --rendering-method forward_plus --rendering-driver vulkan --audio-driver Dummy
```

The four rendered checks compare all numeric values with the running engine,
exclude deliberately unsupported code in the other version branch, use the
defines from a shader include, and retain the existing renderer defines.
Success ends with `SHADER_VERSION_RESULT checks=4 failures=0`.
