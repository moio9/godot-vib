from pathlib import Path
import re


cpp_path = Path("servers/rendering/renderer_rd/effects/ss_effects.cpp")
text = cpp_path.read_text(encoding="utf-8")
start = text.index("void SSEffects::generate_ssao(")
end = text.find("\nvoid SSEffects::", start + 1)
if end == -1:
    end = len(text)
func = text[start:end]
old = "if (ssao_quality == RSE::ENV_SSAO_QUALITY_ULTRA) {"
count = func.count(old)
if count < 2:
    raise RuntimeError(f"Expected at least two SSAO Ultra branches, found {count}")
func = func.replace(
    old,
    "if (!use_visibility_bitmask_shader && ssao_quality == RSE::ENV_SSAO_QUALITY_ULTRA) {",
)
cpp_path.write_text(text[:start] + func + text[end:], encoding="utf-8")

# The VB shader is now selected explicitly, so it must return its own
# visibility rather than blending back toward the STANDARD result.
vb_path = Path("servers/rendering/renderer_rd/shaders/effects/ssao_vb.glsl")
vb = vb_path.read_text(encoding="utf-8")
pattern = re.compile(r"mix\(out_shadow_term,\s*vb_visibility,\s*[^\)]+\)")
if not list(pattern.finditer(vb)):
    raise RuntimeError("No Standard/VB blend expression found in ssao_vb.glsl")
vb = pattern.sub("vb_visibility", vb)
if "mix(out_shadow_term" in vb:
    raise RuntimeError("A Standard/VB blend expression remains")
vb_path.write_text(vb, encoding="utf-8")
