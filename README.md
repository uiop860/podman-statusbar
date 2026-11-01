<img src="assets/icon.svg" width="64" height="64" alt="">

# Podman Statusbar

A tiny native macOS 13+ menu-bar app for `podman-machine-default`. No Dock icon,
main window, automatic VM startup, dependencies, or background daemon.

The menu icon distinguishes running (green filled box), stopped (gray outline
box), starting/stopping (orange arrows), and errors (red warning triangle). The count is white and appears
only when the running-container query succeeds. Errors never turn into a false
zero. Open the native menu to see container names, start/stop the machine, refresh,
or quit. Container image names are available as help text where macOS supports it.

## Build and run

Install Xcode or Apple's Command Line Tools and [Podman](https://podman.io/docs/installation).
The app icon is the generated slate container mark with a green status light.
The app finds Podman in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/podman/bin`,
`/usr/bin`, or the inherited PATH, without launching a shell.

```sh
swift test
./build.sh release
```

Like the reference build script, this builds with Swift Package Manager, assembles
`build/PodmanStatusbar.app`, signs it with an available Developer ID / Apple
Development identity (otherwise ad-hoc), replaces `/Applications/PodmanStatusbar.app`,
and opens it. No paid developer account is required for local use. It builds for
the current Mac architecture; `PODMAN_STATUSBAR_ARCH=arm64` overrides it.

For a build without installation or launch:

```sh
PODMAN_STATUSBAR_INSTALL=0 ./build.sh release
open build/PodmanStatusbar.app
```

For installation without administrator access:

```sh
PODMAN_STATUSBAR_INSTALL_DIR="$HOME/Applications" ./build.sh release
```

Use `./build.sh debug` for a debug build. `PODMAN_STATUSBAR_SIGN_ID` can select an
explicit signing identity. `CI=true` also disables install/launch. Signing here is
for local use; the script does not notarize or distribute the app.

Alternatively open `PodmanStatusbar.xcodeproj`, select the **PodmanStatusbar**
scheme and **My Mac**, and run. Xcode links the local `PodmanCore` Swift package.
Run the package tests with `swift test` or by opening `Package.swift` in Xcode.
The app is intentionally unsandboxed so it can execute the local Podman CLI.

## Behavior and implementation

- `PodmanStore` owns machine state, action gating, container data, and one cancellable
  polling task. It refreshes at launch, when the native menu begins tracking, and
  immediately after an operation, including a failed or timed-out operation.
- A running or transitioning machine gets a refresh after approximately 30 seconds;
  stopped/unknown machines after 120 seconds. Each refresh resets the delay. No
  `podman ps` calls are made unless discovery reports the machine running. Sleep
  does not create catch-up polling bursts.
- `PodmanCLI` runs `Process` on a utility queue, with 15-second query timeouts and
  120-second start/stop timeouts. Output goes to temporary files to avoid full-pipe
  deadlocks; nonzero exits include stderr. Timed-out processes receive termination,
  then a forced kill after two seconds. The UI thread never waits for a process.
- `PodmanJSON` decodes machine/container JSON; missing machines, invalid responses,
  missing executables, and connection errors appear in the menu. Refresh retries
  discovery and clears a recovered error. A failed `ps` keeps the machine running
  and leaves **Stop Machine** available.

The app uses `podman machine list --format json`, `podman machine start/stop
podman-machine-default`, and `podman ps --format json`. It assumes Podman's active
connection points to the default local machine, as on a standard installation.
Custom remote connections and multi-machine management are outside this MVP.

## Verification

```sh
swift test
# Optional read-only test against the installed CLI and existing default VM:
PODMAN_STATUSBAR_LIVE_TEST=1 swift test
# Independent Xcode build:
xcodebuild -project PodmanStatusbar.xcodeproj -scheme PodmanStatusbar \
  -configuration Release CODE_SIGNING_ALLOWED=NO build
```

Tests cover JSON parsing, missing/malformed data, counts changing, failed container
queries, start/stop transitions, duplicate actions, recovery after operation timeout,
external startup, stopped-state command suppression, idle monitor startup, and real
subprocess stdout/stderr/timeouts. Start/stop tests use a fake CLI, leaving your VM
and existing containers alone. The live test does not start or stop anything.

Manual acceptance on a disposable default machine:

1. Launch with the VM stopped: outline box, no count, **Start Machine**. Wait two
   minutes and confirm no `podman ps` calls or VM startup.
2. Start from the menu: arrows/progress text, disabled duplicate actions, then a
   filled box and count. An empty machine shows **No running containers**.
3. Start/remove a test container outside the app. Reopen the menu or wait 30 seconds
   and confirm the name/count changes.
4. Stop from the menu: progress, then outline box and no container query.
5. With Podman unavailable, a missing VM, or a failing connection, confirm the error
   text and warning icon. A failing `ps` must show **Container list unavailable**.
6. Confirm no Dock icon/window, native keyboard menu navigation, menu-open refresh,
   and near-zero CPU between refreshes using Activity Monitor.

Automated builds and tests cannot certify visual menu rendering or physical battery
usage; those last checks require an interactive macOS session.
