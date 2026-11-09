<p align="center">
  <img src="docs/assets/icon-512.png" width="120" alt="Shimmer app icon">
</p>

<h1 align="center">Shimmer</h1>
<p align="center">Your PC's games, in a corner of your Mac.</p>
<p align="center">Native macOS · Swift · Sunshine / Moonlight · GPLv3 licensed</p>

Shimmer streams games from a PC running
[Sunshine](https://github.com/LizardByte/Sunshine) to your Mac, and can pop the
stream out into macOS **Picture in Picture**. The game floats over your other
apps while your controller keeps playing.

<p align="center">
  <img src="docs/assets/servers.png" width="600" alt="Shimmer's Servers tab with a paired PC, its apps and a latency graph">
</p>
<p align="center"><em>Your PCs and their apps, in one window.</em></p>

### Picture in Picture

Press ⌃⌥P during a stream and the game moves into the system Picture in Picture
window, over other apps, Spaces and full-screen windows. It can also pop out on
its own when you switch apps. The controller keeps driving the game, and the
mouse over the PiP window moves the PC's pointer.

### One window

Servers lists your PCs and the ones nearby, pairs them in place, shows each PC's
apps, and can measure latency. Stream and General hold the settings.

<p align="center">
  <img src="docs/assets/stream-settings.png" width="600" alt="Shimmer's Stream settings tab">
</p>
<p align="center"><em>Stream settings.</em></p>

### Made for the menu bar

The menu bar icon shows the connected controller and its battery, or the app
you're streaming. End Stream and Picture in Picture are in its menu.

### What works today

- Picture in Picture, by shortcut, from the menu bar, or automatically.
- Hardware-decoded H.264, HEVC and AV1, with HDR.
- Xbox and DualSense controllers, including rumble, gyro and touchpad.
- Mouse and keyboard forwarding, or controller-only play.
- PC discovery, PIN pairing, and import of moonlight-qt pairings.
- A second address per PC, such as a Tailscale address, used when the home
  address isn't reachable.
- `shimmerctl`, a command-line tool a coding agent can use to check and fix the
  app. See the [CLI guide](docs/CLI.md).

**A PC running Sunshine is required.** See [host setup](docs/HOST_SETUP.md).

On macOS 27.2, the menu bar icon's menu doesn't open while another app is in
full screen.

### Build on macOS

Requires macOS 26+, Apple Silicon, Xcode 26 and Homebrew. There is no notarized
installer yet.

```sh
git clone https://github.com/slaughterhousesoftware/shimmer.git
cd shimmer
brew install openssl@3 opus
make local-signing-setup
make
```

`make local-signing-setup` is a one-time step so macOS keeps Shimmer's
permissions across rebuilds. `make` builds and installs
`/Applications/Shimmer.app`. `make test` runs the tests.

### Under the hood

Shimmer is a fork of [glimmer](https://github.com/Se7enbrc/glimmer) by
[Se7enbrc](https://github.com/Se7enbrc), based on glimmer 2026.9.0 with fixes
ported from later releases. The whole pipeline is Swift in one process: network,
VideoToolbox decode, display, audio and input. Picture in Picture uses the same
display layer the stream already draws into, so there is no second decoder.

glimmer has moved on since and has features Shimmer doesn't, such as iOS apps
and its own Mini Player. See [architecture](docs/ARCHITECTURE.md),
[security](docs/SECURITY.md) and the [changelog](CHANGELOG.md).

Shimmer is a [Slaughterhouse Software](https://github.com/slaughterhousesoftware)
project, built by Kevin Patel with Claude and Codex. It is independent of
LizardByte, Moonlight and Valve.

### License

glimmer is Copyright © 2026 ugfugl.io. Shimmer's additions are Copyright © 2026
Kevin Patel. Shimmer is licensed under the
[GNU General Public License, version 3](LICENSE). The streaming protocol code is
ported from Moonlight, also GPLv3. See [CREDITS.md](CREDITS.md).
