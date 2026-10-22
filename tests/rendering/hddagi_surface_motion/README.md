# Moving HDDAGI screen-probe surfaces

`shader_check.gd` dispatches the actual SVGF shader on a local Vulkan RenderingDevice.
It checks matching history under depth and screen-space motion, starting/stopping,
identity changes, occlusion, uncovered pixels, out-of-screen reprojection, invalid
previous depth, and stationary surfaces. Baseline dispatches disable surface metadata
while corrected dispatches use the opaque prepass identity and previous raster depth.

Run with the editor using Forward+ and `--script res://shader_check.gd`.

`compile_probe.gd` compiles all 19 screen-probe shader variants, including
Stochastic, irradiance cache, Directional Gather, and specular paths.

`ground_check.gd` measures an emissive moving car's contribution on the floor,
separately from the car's own receiving surface. It checks Stochastic screen
radiance on/off, the first frame after movement, clearing the old location,
MSAA, and screen-radiance resource allocation without SVGF or specular effects.
It also isolates indirect sky occlusion with a black dynamic car and no ordinary
shadow maps, requiring the ground shadow to follow movement and clear its old
position. These assertions inspect floor pixels rather than the car itself.
Use `--baseline` to collect measurements without requiring the new behavior.
The historical `screen_probe_directional_screen_radiance` setting now enables
identity/depth-validated endpoint color in both diffuse screen-probe modes.
Opaque screen hits without valid endpoint color block the ray instead of
transmitting sky through an unvoxelized dynamic object.

Moving vehicle meshes must use `GeometryInstance3D.GI_MODE_DYNAMIC` (or Disabled
if desired), rather than being cached as static HDDAGI level geometry. Screen
tracing still depends on visible geometry and does not add an off-screen dynamic
voxel representation.
A headless run cannot create the local Vulkan RenderingDevice.

The renderer emits metadata only in the existing HDDAGI motion-vector depth prepass.
Depth, normal, velocity and metadata resolve from the same MSAA sample. Each viewport
keeps its own previous metadata, cleared on reconfiguration and freed when the screen
probe motion consumers are disabled. Ordinary meshes, including skinned meshes, have
stable geometry IDs independent of render-list order. MultiMesh and particle elements
keep the previous conservative behavior because per-element identities are unavailable.

`scene_check.gd` renders a fast moving car in Stochastic and Directional Gather,
checks live surface IDs and indirect-light buffers, exercises custom paint-like
varyings, MSAA and resize, and saves stationary/moving captures. It can optionally
load authored car geometry with `--car=res://path/to/body.tscn` in an isolated asset
project. The consuming game's native extensions and gameplay are not required.
