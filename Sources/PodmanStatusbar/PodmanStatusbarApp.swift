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
            Label {
                if let count = store.count { Text(String(count)) }
            } icon: {
                Image(systemName: statusSymbol)
            }
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

    private var statusSymbol: String {
        if store.errorMessage != nil { return "exclamationmark.triangle" }
        switch store.state {
        case .running: return "shippingbox.fill"
        case .stopped: return "shippingbox"
        case .starting, .stopping: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.square"
        }
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
