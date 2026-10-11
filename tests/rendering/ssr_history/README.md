# Shared SSR/SSGI history and threaded shutdown

Run with Vulkan Forward+:

```sh
bin/godot.linuxbsd.editor.x86_64 --path tests/rendering/ssr_history --rendering-method forward_plus --rendering-driver vulkan --audio-driver Dummy --verbose
```

The project uses a separate rendering thread and checks the actual history
texture dimensions and mip count from a compositor callback. Ten cases cover
SSGI-only, SSGI with half-resolution SSR, SSR-only, SSIL with SSR, transitions
between those configurations, and MSAA off/2x.

SSGI keeps history at full resolution. Half-resolution SSR must therefore
receive mip 1 from a history texture with at least two mips. SSR-only history
stays at half resolution with one mip; SSIL keeps its six-mip history.

Success ends with `SSR_HISTORY_RESULT checks=10 failures=0` and no invalid
uniforms, out-of-range mipmaps, rendering-thread errors, or leaked objects at
process shutdown. The shutdown check also exercises transferring ownership of
the main RenderingDevice back to the main thread after the render task stops.
