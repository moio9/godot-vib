# Independent decal ORM regression

Run `bin/godot.linuxbsd.editor.x86_64 --path tests/rendering/decal_orm --script res://check.gd --rendering-method forward_plus --audio-driver Dummy`. Repeat with `mobile` and `gl_compatibility`.

The GPU test reads rendered images and checks default behavior, scene serialization, channel clamping, independent roughness and metallic changes, neutral-channel preservation, ambient-only AO, partial AO blending, direct-light preservation, multiple decals, and the RenderingServer API using a valid decal RID. A 128x128 soft alpha mask exercises projected blending.

Forward+ and Mobile honor the receiving material's `ao_light_affect=0` with AO enabled. Compatibility retains its existing lighting behavior, which applies AO to direct lighting; its direct-light preservation check therefore disables the AO channel. The port preserves each backend's default appearance.

Success prints `DECAL_ORM_RESULT renderer=<method> checks=17 failures=0`. No errors or RID/ObjectDB leaks are expected. Captures are saved in the project's isolated user directory.
