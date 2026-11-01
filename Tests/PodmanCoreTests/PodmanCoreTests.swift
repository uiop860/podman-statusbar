import XCTest
@testable import PodmanCore

private let running = Data(#"[{"Name":"podman-machine-default","Running":true,"Starting":false}]"#.utf8)
private let stopped = Data(#"[{"Name":"podman-machine-default","Running":false,"Starting":false}]"#.utf8)
private let starting = Data(#"[{"Name":"podman-machine-default","Running":false,"Starting":true}]"#.utf8)
private let containers = Data(#"[{"Id":"2","Names":["postgres"],"Image":"postgres:17"},{"Id":"1","Names":["nginx"],"Image":"nginx:latest"}]"#.utf8)

private actor StubCLI: PodmanCommanding {
    var replies: [Result<Data, Error>]
    var commands: [[String]] = []
    let delay: UInt64
    init(_ replies: [Result<Data, Error>], delay: UInt64 = 0) { self.replies = replies; self.delay = delay }
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> Data {
        commands.append(arguments)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        guard !replies.isEmpty else { throw PodmanError.command("Unexpected command") }
        return try replies.removeFirst().get()
    }
}

final class PodmanCoreTests: XCTestCase {
    func testMachineParsingAndDefaultSelection() throws {
        let data = Data(#"[{"Name":"other","Running":true},{"Name":"podman-machine-default","Running":false}]"#.utf8)
        XCTAssertFalse(try PodmanJSON.machine(data).running)
        XCTAssertFalse(try PodmanJSON.machine(data).starting)
        XCTAssertTrue(try PodmanJSON.machine(starting).starting)
    }

    func testMissingMachineAndMalformedOutput() {
        for json in ["[]", "null", "not json", #"[{"Name":"podman-machine-default"}]"#] {
            XCTAssertThrowsError(try PodmanJSON.machine(Data(json.utf8)))
        }
        for json in ["null", "{}", #"[{"Id":"1","Names":42,"Image":"nginx"}]"#] {
            XCTAssertThrowsError(try PodmanJSON.containers(Data(json.utf8)))
        }
    }

    func testContainerNamesImagesAndEmptyList() throws {
        let result = try PodmanJSON.containers(containers)
        XCTAssertEqual(result.map(\.name), ["nginx", "postgres"])
        XCTAssertEqual(result.first?.image, "nginx:latest")
        XCTAssertEqual(try PodmanJSON.containers(Data("[]".utf8)), [])
    }

    @MainActor func testStoppedDoesNotQueryContainersOrAutostart() async {
        let cli = StubCLI([.success(stopped), .success(stopped)])
        let store = PodmanStore(cli: cli)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.state, .stopped)
        XCTAssertNil(store.count)
        XCTAssertEqual(store.pollInterval, 120)
        XCTAssertTrue(store.canStart)
        let calls = await cli.commands
        XCTAssertEqual(calls, Array(repeating: ["machine", "list", "--format", "json"], count: 2))
    }

    @MainActor func testCountChangesAndFailedPSIsNotZero() async {
        let cli = StubCLI([.success(running), .success(containers), .success(running), .success(Data("[]".utf8)), .success(running), .failure(PodmanError.command("connection failed"))])
        let store = PodmanStore(cli: cli)
        await store.refresh()
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.pollInterval, 30)
        await store.refresh()
        XCTAssertEqual(store.count, 0)
        await store.refresh()
        XCTAssertEqual(store.state, .running)
        XCTAssertNil(store.count)
        XCTAssertEqual(store.errorMessage, "connection failed")
        XCTAssertTrue(store.canStop)
    }

    @MainActor func testStartStopTransitionsAndDuplicatePrevention() async {
        let cli = StubCLI([.success(stopped), .success(Data()), .success(running), .success(containers), .success(Data()), .success(stopped)], delay: 20_000_000)
        let store = PodmanStore(cli: cli)
        await store.refresh()
        let start = Task { await store.startMachine() }
        await Task.yield()
        // Wait for the first task to enter its operation, without awaiting completion.
        while store.state != .starting { await Task.yield() }
        XCTAssertTrue(store.isBusy)
        XCTAssertFalse(store.canStart)
        await store.startMachine()
        await store.refresh()
        await start.value
        XCTAssertEqual(store.state, .running)
        XCTAssertEqual(store.count, 2)
        let stop = Task { await store.stopMachine() }
        while store.state != .stopping { await Task.yield() }
        XCTAssertNil(store.count)
        XCTAssertFalse(store.canStop)
        await store.stopMachine()
        await stop.value
        XCTAssertEqual(store.state, .stopped)
        XCTAssertFalse(store.isBusy)
        let calls = await cli.commands
        XCTAssertEqual(calls.filter { $0.contains("start") }.count, 1)
        XCTAssertEqual(calls.filter { $0.contains("stop") }.count, 1)
        XCTAssertEqual(calls.last, ["machine", "list", "--format", "json"])
    }

    @MainActor func testOperationFailureReconcilesAndRefreshRecovers() async {
        let cli = StubCLI([.success(stopped), .failure(PodmanError.timeout), .success(running), .success(containers), .success(running), .success(containers)])
        let store = PodmanStore(cli: cli)
        await store.refresh()
        await store.startMachine()
        XCTAssertEqual(store.state, .running)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isBusy)
        await store.refresh()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.count, 2)
    }

    @MainActor func testDiscoveryFailureAndExternalStartup() async {
        let cli = StubCLI([.failure(PodmanError.missingExecutable), .success(Data("[]".utf8)), .success(starting), .success(running), .success(containers)])
        let store = PodmanStore(cli: cli)
        await store.refresh()
        XCTAssertEqual(store.state, .unknown)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.canStart)
        await store.refresh()
        XCTAssertTrue(store.errorMessage?.contains("not found") == true)
        await store.refresh()
        XCTAssertEqual(store.state, .starting)
        XCTAssertFalse(store.canStart)
        await store.refresh()
        XCTAssertEqual(store.count, 2)
    }

    @MainActor func testIdleMonitoringOnlyLaunchesInitialDiscovery() async throws {
        let cli = StubCLI([.success(stopped)])
        let store = PodmanStore(cli: cli)
        store.startMonitoring()
        store.startMonitoring()
        try await Task.sleep(nanoseconds: 100_000_000)
        store.stopMonitoring()
        let calls = await cli.commands
        XCTAssertEqual(calls.count, 1)
    }

    @MainActor func testLivePodmanReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["PODMAN_STATUSBAR_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set PODMAN_STATUSBAR_LIVE_TEST=1 for read-only local Podman verification")
        }
        let cli = PodmanCLI()
        let expected = try PodmanJSON.machine(await cli.run(["machine", "list", "--format", "json"], timeout: 15))
        let store = PodmanStore(cli: cli)
        await store.refresh()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.state, expected.starting ? .starting : (expected.running ? .running : .stopped))
        if store.state == .running {
            let expectedContainers = try PodmanJSON.containers(await cli.run(["ps", "--format", "json"], timeout: 15))
            XCTAssertEqual(store.count, expectedContainers.count)
        } else { XCTAssertNil(store.count) }
    }

    func testSubprocessOutputStderrAndTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("podman")
        func write(_ body: String) throws {
            try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let cli = PodmanCLI(executable: executable)
        try write("printf '[]'")
        let output = try await cli.run(["ps", "--format", "json"], timeout: 2)
        XCTAssertEqual(output, Data("[]".utf8))
        try write("echo 'connection failed' >&2\nexit 125")
        do {
            _ = try await cli.run([], timeout: 2)
            XCTFail("Expected command failure")
        } catch { XCTAssertEqual(error.localizedDescription, "connection failed") }
        // exec ensures the timed process itself is terminated, with no shell child.
        try write("exec /bin/sleep 30")
        let start = Date()
        do {
            _ = try await cli.run([], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
}
