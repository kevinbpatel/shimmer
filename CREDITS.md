# Credits

**shimmer is a fork of [glimmer](https://github.com/Se7enbrc/glimmer)** by
[Se7enbrc](https://github.com/Se7enbrc) (Copyright © 2026 ugfugl.io, GPLv3).
shimmer adds macOS Picture in Picture on top of glimmer's engine and is
distributed under the same license; everything below about Glimmer's lineage
applies to shimmer unchanged.

Glimmer's Swift streaming transport was **ported from
[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)**,
the core protocol library written by the
[Moonlight Game Streaming](https://github.com/moonlight-stream) team. Their
implementation of the GameStream/Sunshine wire protocol is hard-won work, and
Glimmer would not exist without it. Thank you.

A few higher-level pieces, the pairing handshake, the nvhttp control client, and
the frame pacer, were likewise ported from the same team's
[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt) (also GPLv3).

These are faithful ports, so Glimmer is a derivative work and is distributed
under the **GNU General Public License v3** (see [LICENSE](LICENSE)), the same
license as the originals. The GPLv3 notice on the ported files is accurate and
intentional.

The Steam logo bundled as `Assets.xcassets/SteamGlyph` is a trademark of
**Valve Corporation**. shimmer is not affiliated with or endorsed by Valve; the
mark is used only to label the Steam entry a host publishes, the way every
Moonlight client shows the artwork the host serves for it. It was traced from
the box art Sunshine itself returns for that app, flattened to a monochrome
template so it tints like a system symbol.

The DualSense mark in the menu bar (`Assets.xcassets/DualSenseGlyph`) is
generated from `controller_playstation5.svg` in
**[Kenney's Input Prompts](https://kenney.nl/assets/input-prompts)**, released
into the public domain under **CC0 1.0**. The unmodified source SVG is kept at
`scripts/assets/kenney-controller_playstation5.svg`; the trim-and-template pass
that turns it into the menu-bar asset is `scripts/generate-dualsense-glyph.swift`.
There is no PlayStation-controller SF Symbol to use instead - the system
catalog has only `playstation.logo` (the PS letters mark, which Apple restricts
to unmodified, referential use) and a generic `gamecontroller`.

"DualSense" and the controller's design are trademarks / trade dress of **Sony
Interactive Entertainment Inc.**, which CC0 does not and cannot waive. shimmer
is not affiliated with or endorsed by Sony: the mark appears only while a
DualSense or DualShock 4 is actually connected, to name that controller and
show its battery, and never as an app icon or other branding. Every other pad
gets Apple's generic `gamecontroller` symbol.

shimmer's interface owes a debt to
**[moonlight-macos-enhanced](https://github.com/skyhua0224/moonlight-macos-enhanced)**
by [skyhua0224](https://github.com/skyhua0224) (GPLv3, a fork of Moonlight for
macOS). Two things came from studying it: the way Settings are organised
(Stream / Video / Audio / Input / App, with a single resolution picker, a
frame-rate picker, and an always-visible bitrate control), and the idea of
showing the host's real cover art for each app instead of a generic symbol.
No code was copied — that project is Objective-C/AppKit over Core Data and
shimmer is Swift/SwiftUI over a different model layer, so both were
reimplemented — but the design is theirs, and the `/appasset` box-art request
follows the same convention every Moonlight client uses. Thank you.

## MIT-licensed upstreams ported via moonlight-common-c

Two of the components ported into the Swift engine originate from separately
licensed (MIT) projects that moonlight-common-c vendors. Their copyright and
permission notices are preserved here, as the MIT license requires:

- **[enet](https://github.com/lsalzman/enet)** - Copyright (c) 2002-2024 Lee
  Salzman. MIT License. `Glimmer/Stream/Native/EnetControlChannel*.swift` and
  `EnetWire.swift` port the protocol logic of the enet sources vendored in
  moonlight-common-c (`protocol.h` / `host.c` / `protocol.c`).
- **[nanors](https://github.com/sleepybishop/nanors)** - Copyright (c) 2021
  Joseph Calderon. MIT License. `Glimmer/Stream/Native/ReedSolomon.swift` ports
  `nanors/rs.c` plus the scalar GF(256) math from nanors' vendored
  `deps/obl/oblas_lite.c` (covered by the same nanors license).

MIT permission notice (applies to both):

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
