# SSAO camera-distance scene

Open `project.godot` with the locally built Godot editor. The scene contains a flat floor and three boxes, with only basic lighting and SSAO enabled. The default algorithm is Standard.

To save scene and SSAO-mask captures at camera distances of 3, 8, and 16 meters, run the project with `-- --capture-dir=/tmp/ssao-captures`. Add `--algorithm=1` or `--algorithm=2` to compare the optional visibility-bitmask modes. The output images are written to the selected directory.
