# HDDAGI reactive diffuse history

The new `rendering/global_illumination/hddagi/screen_probe_denoiser_reactive`
setting is enabled by default and applies only to SVGF diffuse screen probes.
It shortens history for spatially coherent brightness changes, while retaining
history for isolated noisy samples and unrelated surfaces. It does not enable
screen probes or SVGF automatically and does not change SSIL, SSGI or specular
filtering.

Run from the engine checkout on a Vulkan-capable desktop:

```sh
bin/godot.linuxbsd.editor.x86_64 --display-driver x11 --rendering-method forward_plus --rendering-driver vulkan --audio-driver Dummy --path tests/rendering/hddagi_reactive_history --script res://check.gd
bin/godot.linuxbsd.editor.x86_64 --display-driver x11 --rendering-method forward_plus --rendering-driver vulkan --audio-driver Dummy --path tests/rendering/hddagi_reactive_history --script res://scene_check.gd
```

`check.gd` compiles the actual engine shader and dispatches it on a local GPU
RenderingDevice. It compares old and reactive accumulation with identical input,
including light-on/off steps, stable illumination, stochastic noise, isolated
outliers, depth/normal/dynamic-surface boundaries, invalid history, specular
invariance and partial workgroups. It also checks faint and low-contrast shadow
changes despite noisy old moments, and coherent changes on oblique surfaces
whose neighboring view depths differ, including recent illumination history.
It reports 40 checks. This isolates temporal
response; it does not measure whole-scene GI convergence or frame time.

`scene_check.gd` exercises both screen-probe modes with the integrated renderer,
light changes, setting toggles, resize and teardown. Pass `-- --out=/absolute/path`
to save captures. This is an integration smoke test, not an image-quality score.
