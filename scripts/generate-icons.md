# App icon and legacy generator notes

**The shipping icon is `Glimmer/AppIcon.icon`.** It is the selected aligned
square-based glass pyramid on purple, with warmer incoming light and richer
gold, cyan and violet gradients. The selected shading-only treatment keeps
the spectrum continuous, with stronger colour through the faces. A brighter
violet fill (Display P3 `#5024BD`) and lighter glass improve separation from
the background in Default/Light. Dark uses a neutral charcoal fill
(Display P3 `#1C1C1E`), with a pearl entry beam and vivid yellow-gold, cyan
and violet gradients. Dark has stronger transmitted colour through the faces,
quieter rear-face colours and brighter glass (translucency 0.40 with full shell
opacity). Its material settings remain independently editable.
The pyramid geometry is shared. The porcelain variant was retired.

The Composer document has four groups: restrained spectrum colour retention,
the glass shell, rear faces and base seam, and the aligned light artwork.
The shell is a raster asset with native inside specular lighting and
translucency (0.40 in Default, with the shell layer at full opacity). The beam
boundaries, gradients, rear facets and base seam are editable SVG. Material blur and
screen-space refraction are disabled to keep
the selected ray geometry crisp. The colour-retention overlay uses restrained
transmission gradients across the faces and is inset from the bevels so it
preserves their highlights. The rays have no facet offsets or bends.

Xcode compiles this document into appearance-aware icon stacks using
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. No flattened replacement icon
or Finder custom icon is needed.

The shipping Composer document is the editable source consumed directly by
the app build. Open `Glimmer/AppIcon.icon` in Icon Composer to adjust the
material. Beam gradients live in `Assets/light.svg`; their colour-retention
counterparts live in `Assets/retained-spectrum.svg`. Keep those palettes in
sync when tuning the light. The icon does not depend on the exploratory
studies under `output/`.

Dark artwork is supplied through native `image-name-specializations` on the
same layers. The matching `*-dark.svg` assets tune the beams, transmitted
colour, rear faces and base seam. Native material overrides use
`translucency-specializations` and `opacity-specializations`. Keep the default
and Dark paths and transforms aligned when editing: this is an appearance
palette, not a different pyramid construction. The Default export is unchanged
by these Dark overrides.

Export the README icon with `./scripts/export-shimmer-icon.sh`. The export
uses Icon Composer's macOS 27 design generation, matching the approved icon.
The same command refreshes the About pane's `AboutAppIcon` image set at 1× and
2×, with Default and Dark appearances. SwiftUI selects the image for the
window's current appearance; regenerate these exports after editing the source
icon. The app's Dock and Finder icon still uses the layered Composer document.
`make app` refreshes all exports before compiling. GitHub always uses the purple
Default appearance: `docs/assets/icon-512.png` in the README and the larger
`docs/assets/icon-social.png` for Settings → Social preview. Keep the default
branch's README image current when publishing an approved logo change. The
social preview is a separate GitHub upload and must also be replaced there.

`generate-icons.swift` is the generator for the previous moon-and-sparkles
design. It still runs, and the rationale below is worth keeping because the
constraints it solved (the small-size collapse, the `.icon` bundle's placement)
apply to any replacement. Treat it as reference, not as the build step.

## Composition (back-to-front)

1. Midnight diagonal gradient background (indigo → violet) + warm corner accent
2. Frosted-glass moon body (radial gradient) with an inset shadow for depth and
   a soft crescent shading to give it a three-quarter-lit feel
3. Sparkles rendered as radial gradients with bright specular cores
4. Rim highlight along the top edge for the "lifted glass" feeling
5. Faint inner stroke around the squircle to define the tile edge

## Usage

Run via `swift scripts/generate-icons.swift [flag]`:

| Flag        | Output                                                                                                                                                                                                                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _(none)_    | Light variant - legacy `.appiconset` output                                                                                                                                                                               |
| `--dark`    | Dark variant - brighter palette so the icon pops on a dark Dock                                                                                                                                                           |
| `--layered` | The layered 1024px PNGs into `AppIcon.icon/Assets` (`Background-Light.png` + `Background-Dark.png` + `Foreground.png`) consumed by macOS 26's Icon Composer bundle for light/dark/tinted/clear theme-snapping in the Dock |

In legacy mode the dark variant emits filenames with a `-dark` suffix, and the
`.appiconset`'s `Contents.json` carries both sets with
`appearances: [{luminosity: dark}]` entries pointing at the dark files. That
output directory no longer exists in the tree; on macOS 26 the Tahoe `.icon`
bundle is what the Dock reads.

## `.icon` bundle layout (`--layered`)

The Tahoe Icon Composer bundle splits the design into a flat canvas fill
(`icon.json`'s top-level `fill`, with a dark `fill-specialization` so the system
crossfades it on Appearance toggle) plus raster layers that theme-snap for
light/dark/tinted/clear. The two raster layers are rendered at 1024×1024 with NO
squircle clip - Tahoe applies the mask itself (squircle on macOS, circle on
watchOS, none on clear):

- **Background overlay** (`renderBackgroundOverlay`): the atmospheric glows +
  rim. The base indigo→violet gradient is deliberately NOT drawn here - that's
  `icon.json`'s top-level `fill`; this layer is just the depth glows on top.
- **Foreground** (`renderForeground`): the moon + sparkles, drawn with the LIGHT
  palette's moon/sparkle colors (warm cream + cool-white) which read fine on
  either appearance - the system's Liquid Glass shader handles the tinted/clear
  adaptations.

The `.icon` bundle lives next to `Assets.xcassets`, NOT inside it - Xcode 26
requires the Icon Composer bundle to be a top-level resource in the target so it
produces appearance-themed AppIcon entries in `Assets.car`. Placed inside
`.xcassets` the bundle is silently ignored. `generate-icons.swift --layered`
writes to the correct `Glimmer/AppIcon.icon/Assets`; the older
`generate-icon-layers.swift` still targets the inside-`.xcassets` path and is
superseded.

## Palette

Instance-based so light + dark variants can be swapped at CLI time.

- **Light**: midnight indigo → violet base.
- **Dark**: brighter, more saturated purple to stand out against the macOS dark
  Dock; bottom-right pulls the brand accent `#8110FE` directly so the icon
  thematically pairs with the in-app accent. The moon/sparkle palette is
  unchanged - cream-warm reads cleanly on either base. The dark moon-shade picks
  up the new background so the lit-from-upper-left illusion stays consistent
  with the surrounding gradient. The dark small-renderer background is a
  mid-bright violet that holds the silhouette at 16/32pt without becoming a neon
  flat fill.

## Small-size render

At 16pt / 32pt the full design (gradient bg, multiple sparkles, glass moon,
inner shadow, rim highlight) collapses into a purple smudge - the moon
silhouette is lost and the inner shadow eats most of what's left. The Dock /
Finder list / status menu all hit this path. Apple's first-party utilities solve
this with a dedicated low-res pass: drop secondary detail, push the primary mark
to ~50% canvas, flat fill, single-pixel-aware stroke (see Finder, Disk Utility,
Activity Monitor at 16pt). Anything ≤64px takes that branch; larger sizes use
the full design, which holds together fine.
