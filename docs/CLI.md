# Client troubleshooting from the terminal

`shimmerctl` diagnoses the installed app without clicking through its UI.
It prints JSON and returns nonzero on a failed diagnosis or stream test.
It requires Python 3 and the existing user account's access to macOS unified logs.

The app bundles the command and this guide in `Contents/Resources`:

```sh
/Applications/Shimmer.app/Contents/Resources/shimmerctl doctor
```

It's meant for coding agents. **General → Coding agents → Copy Instructions**
copies a prompt with that path, the selected PC and the workflow below; paste it
into your agent. No pairing credentials are copied. In a source checkout,
`scripts/shimmerctl` works the same.

```sh
scripts/shimmerctl doctor              # start here: app state, helpers, PC ports, fixes
scripts/shimmerctl fix auto            # apply every safe fix, list what needs a person
scripts/shimmerctl state               # what the running app is showing and doing
scripts/shimmerctl logs --last 10m
scripts/shimmerctl test-stream --host gaming-pc --seconds 12
```

## When something's wrong

1. `shimmerctl doctor`. With no `--host` it uses the PC selected in Shimmer.
   It reports the running app's own state - which screen is up, the selected
   PC's status, the stream phase, anything still `loading`, permissions, both
   background helpers - plus launchd's view of those helpers (a helper launchd
   can't spawn shows `spawn_failing`), the PC's ports, and a `fixes` list.
2. `shimmerctl fix auto` applies every fix that needs no person: re-checking
   the PC (`refresh`), re-registering a Wi-Fi or login helper launchd can't
   start (`wifi-helper`, `login-item`), cancelling a stuck connect
   (`cancel-connect`). It lists the rest under `needs_a_person`.
3. The rest open the right System Settings pane, where someone has to flip a
   switch: `fix approve-background` (Login Items & Extensions, for the Wi-Fi
   helper and "Be ready at login") and `fix input-monitoring` (then relaunch).
4. `shimmerctl fix relaunch` quits and reopens Shimmer when the app itself is
   stuck or doesn't answer.

How it works: the app keeps `~/Library/Application Support/Shimmer/agent-state.json`
current (owner-only, local, no network listener), and runs a fixed allowlist of
harmless commands that shimmerctl drops as files into the owner-only
`agent-commands` folder beside it - refresh, repair a helper, show a screen,
cancel a connect. It works the same over SSH. None of them starts a stream, quits a
game, unpairs or changes a setting. `state` and `doctor` flag a state file left
by a Shimmer that is no longer running as `stale`.

`logs`, `doctor` and `test-stream` read the unified log, where PC names and
addresses, and most connection error details, appear as `<private>`. Settings →
Diagnostics → Logs shows the full lines on the Mac itself.

The stream test uses the installed app's existing launch automation and real
pairing, certificate pinning, stream configuration, decoder, and teardown. It
starts the saved default app on the named host. The client quits after the test
duration; the host app remains running according to the existing disconnect
preference. It refuses to interrupt an already-running Shimmer instance. A
failed connection leaves Shimmer open for inspection.

Run the same commands on a Mac reachable over Tailscale:

```sh
scripts/shimmerctl --on me@my-macbook doctor
scripts/shimmerctl --on me@my-macbook test-stream --host gaming-pc
```

The helper sends its own script through SSH; the remote Mac needs no separate
CLI installation. SSH uses the existing host key and account authorization.
This does not expose a network control server or transfer pairing credentials.

`doctor` distinguishes an unreachable host, a broken secure port, and a logged
macOS Local Network denial. Its TCP checks run as the terminal/SSH process, so
they do not prove the app has permission or that TLS/pairing works. The real
stream test verifies the app path. Older errors remain timestamped in the report
and do not override successful current port checks, except for permission denials
belonging to the currently running app process.

A Sunshine HTTPS listener can stop accepting connections while its HTTP and web
UI ports still answer. Check the host's service and accept queue over SSH before
restarting Sunshine. Client re-pairing cannot repair an exhausted host listener.
The helper diagnoses that case but does not restart services, change permissions,
replace certificates, or weaken TLS validation.
