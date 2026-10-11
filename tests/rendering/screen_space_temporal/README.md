# Screen-space temporal rendering regression

This standalone project exercises the custom Forward+ renderer with built-in meshes. It captures SSAO at three camera distances, SSGI with MSAA disabled and at 8x, screen-space shadows during a pan and a camera cut, two independent viewports, and a viewport resize. TAA is disabled so it cannot hide missing velocity resolves.

Run with a graphical editor build:

```sh
/path/to/godot --path /path/to/this/project -- --out=/absolute/capture/directory
```

For production templates with command-line path overrides disabled, create a PCK using an editor build, put it next to the template with the same basename, and run the template:

```sh
/path/to/editor --headless --path /path/to/this/project --script /path/to/this/project/pack.gd -- /path/to/this/project /path/to/test/render_test.pck
cp /path/to/template /path/to/test/render_test.x86_64
/path/to/test/render_test.x86_64 -- --out=/absolute/capture/directory
```

The final line reports `REGRESSION_RESULT checks=12 failures=0`, with a nonzero exit code for a regression. The captures and `metrics.json` are saved to the requested directory. Compare the six SSAO masks with an editor using the restored standard SSAO shader; they should match. The screenshot checks allow sampling noise but reject persistent shadow history after a camera cut and cross-viewport history contamination.

Use real Forward+ rendering; headless rendering cannot validate these effects. A screenshot pass does not substitute for checking the consuming game's scene and runtime log.
