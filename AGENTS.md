# Workspace instructions

## Preview links

Kevin accesses this computer through Tailscale. Use Tailscale-accessible URLs
instead of localhost or LAN URLs, and bind development servers to an accessible
network interface. This machine is `mac-mini.tail835fed.ts.net`
(`100.94.140.12`); verify the current address when needed.

## App and GitHub branding

- `Glimmer/AppIcon.icon` is the source of truth for the logo. Preserve the
  approved design unless Kevin asks for a redesign.
- Use the purple **Default** rendition for GitHub branding, including the
  README and social preview. The charcoal Dark rendition is for dark app UI.
- After changing the source icon, run `scripts/export-shimmer-icon.sh` and
  commit the matching README, social-preview and About-pane image exports
  with the source change. `make app` also refreshes these exports.
- When an approved logo change is pushed, update `docs/assets/icon-512.png`
  on the user fork's default branch too, so the repo front page stays current.
  Do not merge unrelated app changes just to refresh that image.
- Re-upload `docs/assets/icon-social.png` in the user fork's Settings → Social
  preview after a logo change. GitHub stores that upload separately from repo
  files; do not claim it updated just because the PNG was committed. If browser
  authentication is unavailable, report the pending upload.
- The user fork remote is `shimmer` (`kevinbpatel/shimmer`). `origin` is the
  upstream project; do not push Shimmer branding changes there.
