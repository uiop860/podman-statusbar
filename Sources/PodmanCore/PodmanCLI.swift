import Foundation
import Darwin

public protocol PodmanCommanding {
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> Data
}

/// Each invocation owns a worker and temporary output files. No shell, persistent
/// process, or pipe buffers that can deadlock when stderr is large.
public struct PodmanCLI: PodmanCommanding {
    private let executable: URL?

    public init(executable: URL? = nil) {
        self.executable = executable
    }

    public static func resolveExecutable() -> URL? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/podman/bin", "/usr/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("podman") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func run(_ arguments: [String], timeout: TimeInterval) async throws -> Data {
        guard let executable = executable ?? Self.resolveExecutable() else { throw PodmanError.missingExecutable }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let outURL = directory.appendingPathComponent("stdout")
                    let errURL = directory.appendingPathComponent("stderr")
                    FileManager.default.createFile(atPath: outURL.path, contents: nil)
                    FileManager.default.createFile(atPath: errURL.path, contents: nil)
                    let output = try FileHandle(forWritingTo: outURL)
                    let errors = try FileHandle(forWritingTo: errURL)
                    defer { try? output.close(); try? errors.close() }
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    // Finder-launched apps need a useful PATH for Podman's helpers, too.
                    var environment = ProcessInfo.processInfo.environment
                    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/opt/podman/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
                    process.environment = environment
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = output
                    process.standardError = errors
                    let finished = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in finished.signal() }
                    try process.run()
                    if finished.wait(timeout: .now() + timeout) == .timedOut {
                        process.terminate()
                        if finished.wait(timeout: .now() + 2) == .timedOut {
                            kill(process.processIdentifier, SIGKILL)
                            process.waitUntilExit()
                        }
                        throw PodmanError.timeout
                    }
                    guard process.terminationStatus == 0 else {
                        let stderr = String(decoding: try Data(contentsOf: errURL), as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw PodmanError.command(stderr.isEmpty ? "Podman exited with status \(process.terminationStatus)." : String(stderr.prefix(2000)))
                    }
                    continuation.resume(returning: try Data(contentsOf: outURL))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
