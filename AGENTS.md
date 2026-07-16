# AGENTS.md

## Cursor Cloud specific instructions

This repository is the **Flathub packaging wrapper for Discord** (a `flatpak-builder`
manifest, not application source code). The "product" is the `com.discordapp.Discord`
Flatpak built from `com.discordapp.Discord.yaml`. Discord itself is proprietary and is
downloaded as prebuilt tarballs during the build.

### Toolchain (already installed in the VM snapshot)
- `flatpak` + `flatpak-builder` (apt) — used for **building**.
- `org.flatpak.Builder` (Flatpak app) — used only for **linting** (`flatpak-builder-lint`).
- Flatpak runtimes `org.freedesktop.Platform`, `org.freedesktop.Sdk`, and
  `org.electronjs.Electron2.BaseApp` at version `25.08` (the versions the manifest pins),
  installed in both the `--user` and `--system` installations.
- `librsvg2-common` (apt) — **required**; see the appstream gotcha below.

### Build
Use the host `flatpak-builder` binary (not the one bundled inside `org.flatpak.Builder`):
```
flatpak-builder --user --force-clean --repo=repo builddir com.discordapp.Discord.yaml
```
Outputs (`builddir/`, `repo/`, `.flatpak-builder/`) are git-ignored.

- Do NOT build with `flatpak run org.flatpak.Builder ...`: its nested bubblewrap sandbox
  hangs indefinitely in this Firecracker/Docker VM (it stalls right after the `socat`
  module). Only use `org.flatpak.Builder` for the linter, which does not need the nested sandbox.

### Lint (Flathub linter)
```
flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest com.discordapp.Discord.yaml
flatpak run --command=flatpak-builder-lint org.flatpak.Builder builddir builddir
flatpak run --command=flatpak-builder-lint org.flatpak.Builder repo repo
```
Pre-existing, expected findings when linting locally (not regressions):
- `finish-args-contains-both-x11-and-wayland` — intentional; Flathub grants this app a
  server-side exception.
- `appstream-external-screenshot-url` / `appstream-screenshots-not-mirrored-in-ostree` —
  only appear because local builds omit `--mirror-screenshots-url=https://dl.flathub.org/media/`
  (a Flathub publish-time step). Add that flag to `flatpak-builder` to silence them.

### Run (GUI)
The build produces an Electron GUI app that uses `zypak`, which **requires a D-Bus session
bus**. This headless VM has none, so you MUST wrap the launch in `dbus-run-session`, or it
aborts with `Failed to connect to session bus`:
```
flatpak-builder --user --install --force-clean builddir com.discordapp.Discord.yaml   # install once
DISPLAY=:1 dbus-run-session -- flatpak run --user com.discordapp.Discord
```
`DISPLAY=:1` is the pre-running TigerVNC desktop. A successful launch reaches Discord's
"Welcome back!" login screen (email/password form + QR code) and logs
`[useAuthWebsocket] ... handshake complete awaiting remote auth`. Logging in further
requires a real Discord account. When you stop the app by killing `dbus-run-session`, a
final `D-Bus connection was disconnected. Aborting.` line is expected teardown, not a crash.

### appstream gotcha (non-obvious)
`flatpak-builder` runs the **host** `appstreamcli compose` on the app metainfo, which
rasterizes the SVG icon. Without the gdk-pixbuf SVG loader the build fails at that step with
`Unrecognized image file` (reported as `file-read-error` / `filters-but-no-output`). The fix
is having `librsvg2-common` installed (already in the snapshot). If a build regresses there,
run `sudo apt-get install -y librsvg2-common`.
