import Foundation

public struct Machine: Decodable {
    public let name: String
    public let running: Bool
    public let starting: Bool

    enum CodingKeys: String, CodingKey { case name = "Name", running = "Running", starting = "Starting" }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        running = try values.decode(Bool.self, forKey: .running)
        starting = try values.decodeIfPresent(Bool.self, forKey: .starting) ?? false
    }
}

public struct Container: Decodable, Identifiable, Equatable {
    public let id: String
    public let names: [String]
    public let image: String
    public var name: String { names.first ?? String(id.prefix(12)) }

    enum CodingKeys: String, CodingKey { case id = "Id", names = "Names", image = "Image" }
}

public enum MachineState: Equatable {
    case unknown, stopped, starting, running, stopping

    public var title: String {
        switch self {
        case .unknown: return "Unknown"
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        }
    }
}

public enum PodmanError: LocalizedError {
    case missingExecutable, missingMachine, malformedOutput, command(String), timeout

    public var errorDescription: String? {
        switch self {
        case .missingExecutable: return "Podman was not found. Install Podman, then refresh."
        case .missingMachine: return "Machine podman-machine-default was not found. Create it with podman machine init."
        case .malformedOutput: return "Podman returned invalid JSON or unexpected data."
        case .command(let message): return message
        case .timeout: return "Podman timed out. Refresh to check the machine's current state."
        }
    }
}

public enum PodmanJSON {
    public static func machine(_ data: Data) throws -> Machine {
        let machines: [Machine]
        do { machines = try JSONDecoder().decode([Machine].self, from: data) }
        catch { throw PodmanError.malformedOutput }
        guard let machine = machines.first(where: { $0.name == "podman-machine-default" }) else {
            throw PodmanError.missingMachine
        }
        return machine
    }

    public static func containers(_ data: Data) throws -> [Container] {
        do {
            return try JSONDecoder().decode([Container].self, from: data)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch { throw PodmanError.malformedOutput }
    }
}
