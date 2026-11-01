import Foundation
import Combine

@MainActor
public final class PodmanStore: ObservableObject {
    @Published public private(set) var state: MachineState = .unknown
    /// nil means unknown/unavailable, never a successful empty response.
    @Published public private(set) var containers: [Container]?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isBusy = false
    private let cli: PodmanCommanding
    private var pollTask: Task<Void, Never>?
    private var monitoring = false

    public init(cli: PodmanCommanding = PodmanCLI()) { self.cli = cli }

    public var pollInterval: TimeInterval { state == .running || state == .starting || state == .stopping ? 30 : 120 }
    public var canStart: Bool { !isBusy && state == .stopped }
    public var canStop: Bool { !isBusy && state == .running }
    public var count: Int? { state == .running ? containers?.count : nil }

    public func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        pollTask = Task { [weak self] in await self?.refresh() }
    }

    public func stopMonitoring() {
        monitoring = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func scheduleNextPoll() {
        guard monitoring else { return }
        pollTask?.cancel()
        let delay = pollInterval
        pollTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false; scheduleNextPoll() }
        errorMessage = nil
        await loadStatus()
    }

    private func loadStatus() async {
        do {
            let machine = try PodmanJSON.machine(await cli.run(["machine", "list", "--format", "json"], timeout: 15))
            state = machine.starting ? .starting : (machine.running ? .running : .stopped)
            if state == .running {
                do { containers = try PodmanJSON.containers(await cli.run(["ps", "--format", "json"], timeout: 15)) }
                catch { containers = nil; errorMessage = error.localizedDescription }
            } else {
                containers = nil
            }
        } catch {
            state = .unknown
            containers = nil
            errorMessage = error.localizedDescription
        }
    }

    public func startMachine() async { await operate(start: true) }
    public func stopMachine() async { await operate(start: false) }

    private func operate(start: Bool) async {
        guard start ? canStart : canStop else { return }
        isBusy = true
        state = start ? .starting : .stopping
        containers = nil
        errorMessage = nil
        defer { isBusy = false; scheduleNextPoll() }
        var operationError: String?
        do {
            _ = try await cli.run(["machine", start ? "start" : "stop", "podman-machine-default"], timeout: 120)
        } catch { operationError = error.localizedDescription }
        // Reconcile even after timeout/failure: the VM may still have changed state.
        await loadStatus()
        if let operationError { errorMessage = operationError }
    }
}
