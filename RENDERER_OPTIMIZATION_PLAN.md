# Renderer optimization validation scope

This branch contains the low-risk depth and Mesh Blend optimizations:

- Correct workgroup liveness conditions for deeper shared linear-depth mips.
- Add an exact two-mip preparation path when SSAO and SSIL use different half-size settings without requiring the full mip chain.
- Sample Mesh Blend depth through a regular sampler instead of a storage image.
- Reuse the main scene depth for the Visibility/Mesh Blend pass when MSAA is disabled.

The branch must compile before it is merged. The existing MSAA guard remains in place, so the dedicated Visibility depth attachment is retained where the resolved depth cannot be used as an attachment.
