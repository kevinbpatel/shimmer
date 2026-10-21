# Workspace instructions

## Preview links

Kevin accesses this computer through Tailscale. Use Tailscale-accessible URLs
instead of localhost or LAN URLs, and bind development servers to an accessible
network interface. This machine is `mac-mini.tail835fed.ts.net`
(`100.94.140.12`); verify the current address when needed.

## App and project branding

- `Glimmer/AppIcon.icon` is the source of truth for the logo. Preserve the
  approved design unless Kevin asks for a redesign.
- Use the purple **Default** rendition for the GitHub README and T3 Code
  project icon. The charcoal Dark rendition is for dark app UI.
- After changing the source icon, run `scripts/export-shimmer-icon.sh` and
  commit the matching README and About-pane image exports
  with the source change. `make app` also refreshes these exports.
- When an approved logo change is pushed, update `docs/assets/icon-512.png`
  on the user fork's default branch too, so the repo front page stays current.
  Do not merge unrelated app changes just to refresh that image.
- T3 Code's Shimmer project uses `faviconPath: docs/assets/icon-512.png`.
  Keep that path stable so logo exports also refresh the project icon.
- Kevin did not request GitHub social-preview or account-avatar changes.
- The user fork remote is `shimmer` (`kevinbpatel/shimmer`). `origin` is the
  upstream project; do not push Shimmer branding changes there.
