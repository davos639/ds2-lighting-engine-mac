# Draft: bug report for DXMT

A draft to file at https://github.com/3Shain/dxmt/issues. DXMT's CONTRIBUTING.md doesn't accept AI-written pull requests but allows sharing AI-assisted findings, so this is an issue, not a PR. It should be filed by a person who can answer questions, and the AI note at the end should stay.

---

**Title:** OMSetRenderTargets rejects a depth-stencil view smaller than the render target, so the scene is black with DS2 Lighting Engine

**Environment**
- DXMT `v0.72-25-gf35d839` as shipped in CrossOver 26.0, macOS 27.2, Apple M5 Pro
- Dark Souls II: Scholar of the First Sin with the DS2 Lighting Engine mod 0.9.50.1 (a ReShade-API-based `dxgi.dll`, https://www.nexusmods.com/darksouls2/mods/1146)

**What happens**
Menus and HUD render, but the whole 3D scene is black. The log repeats every frame:

```
OMSetRenderTargets: invalid render targets
```

**Cause**
`ValidateSetRenderTargets` in `src/d3d11/d3d11_context_impl.cpp` starts from the depth-stencil view's size and returns false when a render target is larger:

```cpp
// TODO: check all RTVs have the same size
if (width < props.Width || height < props.Height)
  return false;
```

The mod binds a render target together with a smaller depth-stencil view, so the call is dropped and nothing is bound. Current `main` still has the same check.

**What works**
With both comparisons skipped (binary-patched in `OMSetRenderTargets` and `OMSetRenderTargetsAndUnorderedAccessViews`), the scene renders correctly and the game plays normally. DXMT already reduces `width` and `height` to the smaller size right after the check, so the pass renders into the overlapping area.

The D3D11 documentation says the views should have the same size, so the mod is technically out of spec. Windows drivers render it anyway, and the mod works there. Would you accept relaxing this, for example by clamping the render area to the intersection, perhaps with a warning, instead of rejecting the call?

*This analysis was done with the help of an AI assistant (Claude). I verified the behavior on my machine.*
