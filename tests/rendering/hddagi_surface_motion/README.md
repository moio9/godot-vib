# Moving HDDAGI screen-probe surfaces

`shader_check.gd` dispatches the actual SVGF shader on a local Vulkan RenderingDevice.
It checks matching history under depth and screen-space motion, starting/stopping,
identity changes, occlusion, uncovered pixels, out-of-screen reprojection, invalid
previous depth, and stationary surfaces. Baseline dispatches disable surface metadata
while corrected dispatches use the opaque prepass identity and previous raster depth.

Run with the editor using Forward+ and `--script res://shader_check.gd`.
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
