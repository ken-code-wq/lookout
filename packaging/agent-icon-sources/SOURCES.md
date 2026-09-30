# Agent icon sources

The 256x256 PNGs in `Sources/LocalObserverCore/Resources/AgentIcons/` are rendered from the files in this folder. Each is RGBA on a transparent background, trimmed to its bounding box, centered, with 12% padding.

Monochrome marks are pure black (#000000) so the app can use them as template images. Claude uses its terracotta (#D97757). Antigravity keeps its official multicolor gradient.

These are third-party trademarks. They are used here only to identify each tool, which is nominative use. Don't recolor or distort them beyond what each brand's guidelines allow, and don't imply endorsement.

| File | Output | Mark | Source | License / usage note |
|---|---|---|---|---|
| `claude.svg` | claude.png | Claude spark, fill #D97757 | Spark path from the `ClaudeWordmark` inline SVG on https://claude.com (viewBox 0 0 125 125) | Anthropic trademark. Brand use per Anthropic guidelines. |
| `codex.svg` | codex.png | OpenAI Codex app mark (flower/cloud with `>_` prompt), black | `codex.svg` from `@lobehub/icons-static-svg` v1.95.1 (https://github.com/lobehub/lobe-icons). Checked against the official Codex app icon `ChatGPT.app/Contents/Resources/icon-codex-light.png`. | lobe-icons is MIT (the vector redraw). The mark is an OpenAI trademark; see https://openai.com/brand |
| `opencode.svg` | opencode.png | OpenCode mark (frame with inner block). Frame is black; inner block is black at 30% opacity to keep the official two-tone look. | `packages/identity/mark-light.svg` in https://github.com/sst/opencode (also shown on https://opencode.ai/brand). Background removed, colors swapped to black. | opencode repo is MIT. Brand assets are published at opencode.ai/brand. |
| `antigravity-icon__full-color.png` | antigravity.png | Google Antigravity "A" arch, full-color gradient | https://antigravity.google/assets/image/brand/antigravity-icon__full-color.png (from https://antigravity.google/press) | Google trademark. Official press-kit asset. |
| `antigravity-lobehub-color.svg` | (reference only) | Vector redraw of the color mark | `@lobehub/icons-static-svg` antigravity-color.svg | MIT (redraw) |
| `antigravity-mono-from-app.svg` | (reference only) | One-color mark | `Antigravity IDE.app/Contents/Resources/app/out/media/jetski-logo-black.svg` | Google, shipped in the app |
| `copilot.svg` | copilot.png | GitHub Copilot mark (goggles face), black | https://github.com/primer/octicons/blob/main/icons/copilot-24.svg | Octicons is MIT. The Copilot mark is a GitHub trademark; see https://brand.github.com |
| `cursor.svg` | cursor.png | Cursor cube (2D), black | `General Logos/Cube/SVG/CUBE_2D_LIGHT.svg` in https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/brand/cursor-brand-assets.zip (linked from https://cursor.com/brand). Fill changed from #26251e to #000000. | Anysphere trademark. Official brand kit. |
| `pi.svg` | pi.png | Pi mark (blocky "pi" glyph), black | https://pi.dev/favicon.svg, the official one-color mark. The multicolor version is https://pi.dev/logo.svg; press kit: https://pi.dev/press-kit | Mario Zechner / pi.dev. Official press-kit asset. |
| `qoder-app-icon.png` | qoder.png | Qoder "a" mark, black | `icon_256x256.png` extracted from `/Applications/Qoder.app/Contents/Resources/icon.icns` with `iconutil -c iconset`. No vector brand kit is published, so the shipped app icon is the source. | Qoder trademark. Extracted from the installed app for identification only. |

## Regenerating

```sh
npm i @resvg/resvg-js
node render-svg.mjs claude.svg ../../Sources/LocalObserverCore/Resources/AgentIcons/claude.png   # same for codex/opencode/copilot/cursor/pi
swift render-raster.swift antigravity-icon__full-color.png ../../Sources/LocalObserverCore/Resources/AgentIcons/antigravity.png
# Qoder has no vector source: extract the installed app icon, then flatten it to a one-color mark.
iconutil -c iconset /Applications/Qoder.app/Contents/Resources/icon.icns -o /tmp/qoder.iconset
swift render-app-icon-mono.swift qoder-app-icon.png ../../Sources/LocalObserverCore/Resources/AgentIcons/qoder.png
```

Use resvg, not AppKit `NSImage` or CoreSVG. CoreSVG mis-parses compact arc flags such as `a.117.117 0 00.107.029` and draws the Codex path wrong.
