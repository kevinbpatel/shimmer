# Client troubleshooting from the terminal

`shimmerctl` diagnoses the installed app without clicking through its UI.
It prints JSON and returns nonzero on a failed diagnosis or stream test.
It requires Python 3 and the existing user account's access to macOS unified logs.

The app bundles the command and this guide in `Contents/Resources`. In
**General → CLI integration → Show Me How**, use **Add Command to PATH** to add
`~/.local/bin/shimmerctl` for your account. Open a new Terminal window afterward.
Removing it removes only Shimmer's symlink and its marked shell-profile block.
The installer supports zsh, bash, and fish and does not overwrite other commands.

Without adding it to PATH:

```sh
/Applications/Shimmer.app/Contents/Resources/shimmerctl status
```

Coding agents can discover `shimmerctl` on PATH or use that bundled path, read
`--help`, and consult the bundled `CLI.md`. **Copy Agent Instructions** in the
same sheet includes this discovery information and the selected PC. No pairing
credentials are copied. In a source checkout, `scripts/shimmerctl` remains usable.

```sh
scripts/shimmerctl status
scripts/shimmerctl doctor --host 192.168.1.20
scripts/shimmerctl logs --last 10m
scripts/shimmerctl test-stream --host gaming-pc --seconds 12
```

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
scripts/shimmerctl --on me@my-macbook doctor --host 192.168.1.20
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
