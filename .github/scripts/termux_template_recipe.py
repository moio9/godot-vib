"""Extend the Termux Godot package recipe with matching export templates."""

import sys
from pathlib import Path


recipe = Path(sys.argv[1])
source = recipe.read_text(encoding="utf-8")

build_start = "\tscons -j$TERMUX_PKG_MAKE_PROCESSES \\\n"
build_end = "\t\tverbose=1\n"
editor_binary = "\tmv $TERMUX_PKG_BUILDDIR/bin/godot.linuxbsd.editor.$_ARCH.llvm"
install_editor = (
    '\tinstall -Dm755 "$TERMUX_PKG_BUILDDIR/bin/godot.linuxbsd.editor.llvm" \\\n'
    '\t\t"$TERMUX_PREFIX/bin/godot"\n'
)

for marker in (build_start, build_end, editor_binary, install_editor):
    if source.count(marker) != 1:
        raise RuntimeError(f"Termux Godot recipe changed; expected exactly one {marker!r}")

source = source.replace(
    build_start,
    "\tfor godot_target in editor template_release template_debug; do\n"
    "\t\tscons -j$TERMUX_PKG_MAKE_PROCESSES \\\n"
    "\t\t\ttarget=$godot_target \\\n",
    1,
)
source = source.replace(
    build_end,
    "\t\tverbose=1\n\tdone\n",
    1,
)
source = source.replace(
    install_editor,
    install_editor
    + "\tfor godot_target in template_release template_debug; do\n"
    + '\t\tinstall -Dm755 "$TERMUX_PKG_BUILDDIR/bin/godot.linuxbsd.$godot_target.arm64.llvm" \\\n'
    + '\t\t\t"$TERMUX_PREFIX/share/godot-vib/templates/godot.linuxbsd.$godot_target.arm64.llvm"\n'
    + "\tdone\n",
    1,
)

recipe.write_text(source, encoding="utf-8")
