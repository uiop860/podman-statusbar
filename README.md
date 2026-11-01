# Podman Statusbar

A small macOS menu bar app for checking and controlling the default Podman machine. It shows running container names and count, and lets you start or stop the machine. It never starts the machine automatically.

## Requirements

- macOS 13 or later
- Podman, with the `podman-machine-default` machine
- Xcode or Apple's Command Line Tools

## Build and run

```sh
swift test
./build.sh release
```

The build creates, signs, installs, and opens `build/PodmanStatusbar.app`. To build without installing or opening it:

```sh
PODMAN_STATUSBAR_INSTALL=0 ./build.sh release
open build/PodmanStatusbar.app
```

You can also open `PodmanStatusbar.xcodeproj` in Xcode and run the `PodmanStatusbar` scheme.

## Updates and errors

The app refreshes when opened and about every 30 seconds while the machine is running, or every 2 minutes while it is stopped. It does not query containers while stopped. Missing Podman, a missing machine, and CLI or connection errors appear in the menu.

The menu bar icon uses muted colors to show the machine state. Its white number is the running-container count.
