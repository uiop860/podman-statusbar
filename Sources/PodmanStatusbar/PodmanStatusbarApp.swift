import SwiftUI
import AppKit
import PodmanCore

@main
struct PodmanStatusbarApp: App {
    @StateObject private var store = PodmanStore()

    var body: some Scene {
        MenuBarExtra {
            PodmanMenu(store: store)
        } label: {
            Image(nsImage: StatusIcons.label(icon: statusIcon, count: store.count))
                .renderingMode(.original)
            .accessibilityLabel("Podman: \(store.errorMessage == nil ? store.state.title : "Error")\(store.count.map { ", \($0) running containers" } ?? "")")
            .onAppear { store.startMonitoring() }
            // Standard MenuBarExtra has no presentation binding. AppKit's public
            // tracking notification fires when this app's native menu opens.
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                Task { await store.refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                store.stopMonitoring()
            }
        }
        .menuBarExtraStyle(.menu)
    }

    private var statusIcon: NSImage {
        if store.errorMessage != nil { return StatusIcons.error }
        switch store.state {
        case .running: return StatusIcons.running
        case .stopped: return StatusIcons.stopped
        case .starting, .stopping: return StatusIcons.transition
        case .unknown: return StatusIcons.unknown
        }
    }
}

private enum StatusIcons {
    static let running = make("shippingbox.fill", color: NSColor(calibratedRed: 0.38, green: 0.56, blue: 0.42, alpha: 1))
    static let stopped = make("shippingbox", color: NSColor(calibratedRed: 0.48, green: 0.51, blue: 0.55, alpha: 1))
    static let transition = make("arrow.triangle.2.circlepath", color: NSColor(calibratedRed: 0.68, green: 0.50, blue: 0.32, alpha: 1))
    static let unknown = make("questionmark.square", color: NSColor(calibratedRed: 0.48, green: 0.51, blue: 0.55, alpha: 1))
    static let error = make("exclamationmark.triangle", color: NSColor(calibratedRed: 0.66, green: 0.37, blue: 0.35, alpha: 1))

    private static var cachedLabel: (icon: NSImage, count: Int, image: NSImage)?

    static func label(icon: NSImage, count: Int?) -> NSImage {
        guard let count else { return icon }
        if let cachedLabel, cachedLabel.icon === icon, cachedLabel.count == count {
            return cachedLabel.image
        }
        // Native menu-bar text may ignore foreground styles. Draw the count in
        // the original-color image so it stays white alongside the colored icon.
        let text = NSAttributedString(string: String(count), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white
        ])
        let textSize = text.size()
        let image = NSImage(size: NSSize(width: icon.size.width + 4 + ceil(textSize.width),
                                        height: max(icon.size.height, ceil(textSize.height))),
                            flipped: false) { rect in
            icon.draw(in: NSRect(x: 0, y: (rect.height - icon.size.height) / 2,
                                 width: icon.size.width, height: icon.size.height))
            text.draw(at: NSPoint(x: icon.size.width + 4, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        cachedLabel = (icon, count, image)
        return image
    }

    private static func make(_ symbol: String, color: NSColor) -> NSImage {
        let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        // Render once into a non-template image so the menu bar preserves the
        // status color instead of applying its usual monochrome tint.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let source else { return false }
            let scale = min(rect.width / source.size.width, rect.height / source.size.height)
            let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            let frame = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height)
            source.draw(in: frame)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

private struct PodmanMenu: View {
    @ObservedObject var store: PodmanStore

    var body: some View {
        Text("Podman — \(store.state.title)")
        Divider()
        if let error = store.errorMessage {
            Text("Error: \(error)")
            Divider()
        }
        if store.state == .running {
            if let containers = store.containers {
                Text("Running containers (\(containers.count))")
                if containers.isEmpty { Text("No running containers") }
                ForEach(containers) { container in
                    Text(container.name).help(container.image)
                }
            } else {
                Text("Container list unavailable")
            }
        } else {
            Text(store.state == .stopped ? "Machine is stopped" : store.state.title)
        }
        Divider()
        if store.state == .starting || store.state == .stopping {
            Text(store.state.title)
        } else if store.state == .running {
            Button("Stop Machine") { Task { await store.stopMachine() } }
                .disabled(!store.canStop)
        } else if store.state == .stopped {
            Button("Start Machine") { Task { await store.startMachine() } }
                .disabled(!store.canStart)
        }
        Button(store.isBusy ? "Refreshing…" : "Refresh") { Task { await store.refresh() } }
            .disabled(store.isBusy)
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
