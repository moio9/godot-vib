# Rendering resource lifecycle regression

Run this standalone project with a graphical Forward+ build. It renders AreaLight3D textures in L8, RGBA8, and RGBAH formats and checks that the atlas contains their pixels. It then creates and destroys three independent worlds with real-time ReflectionProbes. The process must exit with `LIFECYCLE_RESULT checks=4 failures=0` and no invalid texture/uniform errors or leaked GPU RID warnings.

Before the fixes, an L8 AreaLight texture produced the invalid binding-0 texture/uniform cascade. A reflection probe also left a cubemap and six face views allocated after its world was destroyed. The renderer additionally leaked its visibility-buffer depth-copy compute pipeline, shader, and sampler.

For an editor, run `godot --path /path/to/this/project`. For a production template with path overrides disabled, use the included `pack.gd` to create a PCK beside a copy of the template with the same basename, then run that executable.

Headless rendering cannot exercise these GPU paths. Validate both template_debug and template_release, and check the consuming game's startup and orderly shutdown separately.

The 4.8 fixture includes a weak directional light in each world because this fork checks for a directional light even when its post-transparent contact-shadow pass is disabled. Its intensity stays below the atlas pixel threshold, so scene lighting cannot satisfy the texture checks.
