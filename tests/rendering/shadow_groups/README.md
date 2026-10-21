# Scene shadow groups (experimental)

On the root Node3D/CharacterBody3D/VehicleBody3D of a car or character scene,
enable **Visibility > Shadow Group Enabled**. All descendant geometry shares
one dedicated map, including descendants reached through plain Node containers.
A nested enabled root creates another group. Default is disabled.

This initial implementation targets Forward+ and the first shadow-casting
DirectionalLight3D. Up to eight groups per camera are selected by distance.
Allocated casters are removed from that light's ordinary CSM to avoid duplicating
its coarse shadow; overflow groups, other lights, reflection-probe renders,
Mobile and Compatibility retain ordinary shadow rendering.

`rendering/lights_and_shadows/shadow_groups/map_size` controls each tile's
resolution (256–2048, default 1024). The per-camera atlas reserves eight tiles
when active: 32 MiB at 1024, released when no groups remain. Filtering is fixed
four-tap PCF; directional light angular PCSS softness is not implemented for the
dedicated maps. Dedicated maps currently do not shadow volumetric fog. Animated
meshes must have conservative bounds, just as with existing CSM culling.

Run on a Vulkan desktop from the engine checkout:

```sh
bin/godot.linuxbsd.editor.x86_64 --display-driver x11 --rendering-method forward_plus --rendering-driver vulkan --audio-driver Dummy --path tests/rendering/shadow_groups --script res://check.gd -- --out=/tmp/shadow-group-captures
```

The test uses the default DirectionalLight3D bias values (0.1 depth, 2.0 normal).
As with CSM, very low bias can cause self-shadow acne; bias is scaled to the
dedicated map texel size.

The test compares disabled/enabled/restored images, checks actual GPU atlas
depth, scene-root inheritance, plain Node containers, nested groups, reparenting,
runtime children, caster flags, visibility, map and viewport resizing, atlas
capacity fallback, two viewports, light toggles, and teardown. It does not measure
whole-game GPU cost, animation quality or volumetric fog integration.

Run `--script res://skinned.gd` for a procedural Skeleton3D/Skin test which checks
that the old shadow clears and the new shadow follows bone deformation.
`--script res://fallback.gd --rendering-method mobile` (or `gl_compatibility`)
checks that group toggles preserve ordinary shadow rendering in other methods.
Pass `--bench` to check.gd to record raw GPU timing medians. These tiny-scene
measurements are sensitive to clock changes and are not a whole-game benchmark.
