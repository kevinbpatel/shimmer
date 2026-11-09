<p align="center">
  <img src="docs/assets/icon-512.png" width="140" alt="Shimmer">
</p>

# Shimmer

A Mac client for [Sunshine](https://github.com/LizardByte/Sunshine) game
streaming with Picture in Picture: the game floats in a corner while you use
other apps, and your controller keeps playing.

Shimmer is a fork of [glimmer](https://github.com/Se7enbrc/glimmer) by
[Se7enbrc](https://github.com/Se7enbrc). macOS 26+, Apple Silicon.

<p align="center">
  <img src="docs/assets/servers.png" width="600" alt="The Servers tab: a paired PC, its apps, and a latency graph">
</p>

## What it adds to glimmer

- **Picture in Picture.** Press ⌃⌥P during a stream and the game moves into
  the system PiP window, over other apps, Spaces and full-screen windows. It
  can also pop out on its own when you switch apps. The mouse over the PiP
  window moves the PC's pointer.
- **One window.** Servers, Stream, General and About tabs. Servers lists your
  PCs and the ones nearby, pairs them in place, shows each PC's apps, and can
  measure latency.
- **Menu bar.** Shows the connected controller and its battery, or the app
  you're streaming. End Stream and Picture in Picture are in its menu.
- **A second address per PC,** such as a Tailscale address, used when the
  home address isn't reachable.
- **`shimmerctl`,** a command-line tool a coding agent can use to check and
  fix the app. See [docs/CLI.md](docs/CLI.md).

Shimmer is based on glimmer 2026.9.0, with fixes ported from later glimmer
releases. glimmer has moved on since and has features Shimmer doesn't, such as
iOS apps and its own Mini Player.

<p align="center">
  <img src="docs/assets/stream-settings.png" width="600" alt="The Stream settings tab">
</p>

## What it inherits from glimmer

- Hardware-decoded H.264, HEVC and AV1, with HDR.
- Xbox and DualSense controllers, including rumble, gyro and touchpad.
- Mouse and keyboard forwarding.
- PC discovery, PIN pairing, and import of moonlight-qt pairings.

## Build

There is no download yet. You need Xcode 26 and Homebrew.

```bash
git clone https://github.com/slaughterhousesoftware/shimmer.git
cd shimmer
brew install openssl@3 opus
make local-signing-setup   # once, so macOS keeps permissions across rebuilds
make                       # builds and installs /Applications/Shimmer.app
```

`make test` runs the tests. `make uninstall` removes the app.

Your PC needs Sunshine: see [docs/HOST_SETUP.md](docs/HOST_SETUP.md).

## Known issues

- On macOS 27.2, the menu bar icon's menu doesn't open while another app is in
  full screen.

## More

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/SECURITY.md](docs/SECURITY.md)
- [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md)
- [CHANGELOG.md](CHANGELOG.md)

## License

GPLv3. glimmer is Copyright © 2026 ugfugl.io. Shimmer's additions are
Copyright © 2026 Kevin Patel. See [LICENSE](LICENSE) and
[CREDITS.md](CREDITS.md).
