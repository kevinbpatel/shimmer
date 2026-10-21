# Upstream review: 20 October 2026

Compared Shimmer's approved-logo commit `10a421a` with
[`Se7enbrc/glimmer` at `8850d6c`](https://github.com/Se7enbrc/glimmer/commit/8850d6c).
The shared ancestor is `12d2764`; 143 upstream commits are outside Shimmer's
ancestry. A trial merge reports 66 conflicting files, including streaming,
settings, the project, identity and input. No merge was applied.

## Ported immediately

Removed identity startup cleanup and legacy Keychain migration, following
[upstream `8aaaaa5`](https://github.com/Se7enbrc/glimmer/commit/8aaaaa550851939aa638a9eb456540541a474bd6).
The old cleanup used generic item labels and could remove another app's
credentials ([reported upstream](https://github.com/Se7enbrc/glimmer/issues/138)).
The existing file identity path and copy-only Moonlight import remain. A source
regression guard rejects Keychain operations in identity storage without
executing the unsafe code. It detects six calls in the old source and zero in
the fixed source. All 405 tests pass, including the new guard.

## Recommended order

| Priority | Improvement | Concrete next step |
| --- | --- | --- |
| 1 | Reliable recovery after closing the lid or changing networks | Preserve Shimmer's pending sleep-aware retry budget, network wait and stale-warning fixes. Port upstream's session ownership and PC-ended-session checks so recovery cannot relaunch a game the PC intentionally ended. |
| 2 | Consistent pacing and less audio delay on Wi-Fi | Port the cadence and audio-resampler work from [`6a2e485`](https://github.com/Se7enbrc/glimmer/commit/6a2e485), together with its tests and telemetry. Measure real streams before changing buffering defaults. |
| 3 | Packet-source validation and private diagnostics | Backport the paired-PC video-source check from [`30d5163`](https://github.com/Se7enbrc/glimmer/commit/30d5163) and log redaction from [`fcca41b`](https://github.com/Se7enbrc/glimmer/commit/fcca41b) and [`9367d69`](https://github.com/Se7enbrc/glimmer/commit/9367d69). Our video receiver currently accepts packets from any source. Preserve Sunshine's ability to use a different source port. |
| 4 | Fewer bundled dependencies and better audio support | Plan the native TLS, crypto and AudioToolbox Opus migration from [`464ddcb`](https://github.com/Se7enbrc/glimmer/commit/464ddcb). This spans 54 files; take it as a separate integration with pairing, surround and device-switch tests. |

## Preserve during integration

- Native AVKit Picture in Picture, controller input while other apps have focus,
  and the first-frame PiP gate. Upstream's Mini Player is not a replacement for
  these Shimmer behaviors.
- The approved aligned purple prism, Shimmer's bundle identifier and its data
  locations. Existing pairings must survive.
- Shimmer's disconnected upstream update feed. Importing release tooling or
  Info.plist wholesale must not make Shimmer update itself into stock Glimmer.
- The pending local sleep/reconnect and Steam Big Picture fixes. They passed
  the test suite in the deployed build and remain separate from the logo and
  identity-safety commits.

Validate each port with hostless tests, then a real Bazzite session: sleep and
wake, change networks, disconnect and recover, stop the app on the PC, switch
between fullscreen and PiP, and verify controller and local keyboard focus.
