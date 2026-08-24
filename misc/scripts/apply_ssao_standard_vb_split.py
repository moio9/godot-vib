from pathlib import Path
import re
import urllib.request


root = Path(".")

# Preserve the fork's current Visibility Bitmask implementation separately.
standard_path = root / "servers/rendering/renderer_rd/shaders/effects/ssao.glsl"
vb_path = root / "servers/rendering/renderer_rd/shaders/effects/ssao_vb.glsl"
if vb_path.exists():
    raise RuntimeError("ssao_vb.glsl already exists")
custom = standard_path.read_text(encoding="utf-8")
if "visibility" not in custom.lower() and "bitmask" not in custom.lower():
    raise RuntimeError("Current SSAO shader does not look like the custom VB implementation")
vb_path.write_text(custom, encoding="utf-8")

# Restore exact official Godot 4.7.2 ASSAO for Environment SSAO STANDARD.
url = "https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/servers/rendering/renderer_rd/shaders/effects/ssao.glsl"
with urllib.request.urlopen(url, timeout=30) as response:
    official = response.read().decode("utf-8")
if "Intel Corporation" not in official:
    raise RuntimeError("Downloaded SSAO shader does not look like official ASSAO")
standard_path.write_text(official, encoding="utf-8")

header = root / "servers/rendering/renderer_rd/effects/ss_effects.h"
text = header.read_text(encoding="utf-8")
include_old = '#include "servers/rendering/renderer_rd/shaders/effects/ssao.glsl.gen.h"\n'
include_new = include_old + '#include "servers/rendering/renderer_rd/shaders/effects/ssao_vb.glsl.gen.h"\n'
if text.count(include_old) != 1:
    raise RuntimeError(f"SSAO include mismatch: {text.count(include_old)}")
text = text.replace(include_old, include_new)
marker = "\n\t} ssao;\n\n\t/* Screen Space Reflection */"
if text.count(marker) != 1:
    raise RuntimeError(f"SSAO struct marker mismatch: {text.count(marker)}")
vb_struct = """
\t} ssao;

\tstruct SSAOVBShader {
\t\tSsaoVbShaderRD gather_shader;
\t\tRID gather_shader_version;
\t\tPipelineDeferredRD pipelines[SSAO_GATHER_ADAPTIVE + 1];
\t} ssao_vb;

\t/* Screen Space Reflection */"""
header.write_text(text.replace(marker, "\n" + vb_struct), encoding="utf-8")

cpp = root / "servers/rendering/renderer_rd/effects/ss_effects.cpp"
text = cpp.read_text(encoding="utf-8")

importance_marker = """
\t\t{
\t\t\tVector<String> ssao_modes;
\t\t\tssao_modes.push_back("\\n#define GENERATE_MAP\\n");"""
if text.count(importance_marker) != 1:
    raise RuntimeError(f"SSAO importance marker mismatch: {text.count(importance_marker)}")
vb_init = """
\t\t{
\t\t\tVector<String> ssao_vb_modes;
\t\t\tssao_vb_modes.push_back("\\n");
\t\t\tssao_vb_modes.push_back("\\n#define SSAO_BASE\\n");
\t\t\tssao_vb_modes.push_back("\\n#define ADAPTIVE\\n");

\t\t\tssao_vb.gather_shader.initialize(ssao_vb_modes);
\t\t\tssao_vb.gather_shader_version = ssao_vb.gather_shader.version_create();

\t\t\tfor (int i = SSAO_GATHER; i <= SSAO_GATHER_ADAPTIVE; i++) {
\t\t\t\tssao_vb.pipelines[i].create_compute_pipeline(ssao_vb.gather_shader.version_get_shader(ssao_vb.gather_shader_version, i));
\t\t\t}
\t\t}
"""
text = text.replace(importance_marker, vb_init + importance_marker)

destruct_pattern = re.compile(
    r"(\tif \(ssao\.gather_shader_version\.is_valid\(\)\) \{\n"
    r"\t\tssao\.gather_shader\.version_free\(ssao\.gather_shader_version\);\n"
    r"\t\}\n)"
)
match = destruct_pattern.search(text)
if not match:
    raise RuntimeError("Could not locate SSAO gather shader destructor block")
addition = match.group(1) + """\tif (ssao_vb.gather_shader_version.is_valid()) {
\t\tssao_vb.gather_shader.version_free(ssao_vb.gather_shader_version);
\t}
"""
text = text[: match.start()] + addition + text[match.end() :]

# Select only the gather shader/pipeline set. Importance, blur and interleave
# stay shared by both algorithms.
func_start = text.index("void SSEffects::generate_ssao(")
next_func = text.find("\nvoid SSEffects::", func_start + 1)
if next_func == -1:
    next_func = len(text)
func = text[func_start:next_func]
open_brace = func.index("{") + 1
insert = """
\tconst bool use_visibility_bitmask_shader = p_settings.vb_mode != 0;
\tPipelineDeferredRD *gather_pipelines = use_visibility_bitmask_shader ? ssao_vb.pipelines : ssao.pipelines;
"""
func = func[:open_brace] + insert + func[open_brace:]

split_candidates = [func.find("Generate Importance Map"), func.find("SSAO_GENERATE_IMPORTANCE_MAP")]
split_positions = [position for position in split_candidates if position != -1]
if not split_positions:
    raise RuntimeError("Could not locate boundary after SSAO gather stage")
gather_end = min(split_positions)
prefix = func[:gather_end]
suffix = func[gather_end:]

if prefix.count("ssao.pipelines[") < 1:
    raise RuntimeError("No SSAO gather pipeline accesses found")
prefix = prefix.replace("ssao.pipelines[", "gather_pipelines[")

shader_call = re.compile(
    r"ssao\.gather_shader\.version_get_shader\(ssao\.gather_shader_version,\s*([^\)]+)\)"
)
if not list(shader_call.finditer(prefix)):
    raise RuntimeError("No SSAO gather shader RID accesses found")
prefix = shader_call.sub(
    r"(use_visibility_bitmask_shader ? ssao_vb.gather_shader.version_get_shader(ssao_vb.gather_shader_version, \1) : ssao.gather_shader.version_get_shader(ssao.gather_shader_version, \1))",
    prefix,
)
func = prefix + suffix
cpp.write_text(text[:func_start] + func + text[next_func:], encoding="utf-8")

# Explicit shader lists need the new source added; glob-based SCsubs need no edit.
for scsub_path in [
    root / "servers/rendering/renderer_rd/shaders/effects/SCsub",
    root / "servers/rendering/renderer_rd/shaders/SCsub",
]:
    if not scsub_path.exists():
        continue
    scsub = scsub_path.read_text(encoding="utf-8")
    if "ssao.glsl" in scsub and "ssao_vb.glsl" not in scsub:
        lines = scsub.splitlines(keepends=True)
        for index, line in enumerate(lines):
            if "ssao.glsl" in line:
                lines.insert(index + 1, line.replace("ssao.glsl", "ssao_vb.glsl"))
                scsub_path.write_text("".join(lines), encoding="utf-8")
                break
