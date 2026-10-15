import Foundation
import SwiftUI

struct ScriptEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var notes: String
    var command: String
    var workingDirectory: String
    var isEnabled: Bool
    var runAtLaunch: Bool
    var tags: [String]
    var createdAt: Date
    var lastRunAt: Date?

    static func empty() -> ScriptEntry {
        ScriptEntry(
            id: UUID(),
            name: "",
            command: "",
            workingDirectory: "",
            isEnabled: true,
            tags: [],
            createdAt: Date(),
            lastRunAt: nil
        )
    }

    /// Migration from old format without new fields (backward compatible)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        command = try container.decode(String.self, forKey: .command)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        runAtLaunch = try container.decodeIfPresent(Bool.self, forKey: .runAtLaunch) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
    }

    init(
        id: UUID,
        name: String,
        command: String,
        workingDirectory: String,
        isEnabled: Bool,
        notes: String = "",
        runAtLaunch: Bool = false,
        tags: [String] = [],
        createdAt: Date = Date(),
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.command = command
        self.workingDirectory = workingDirectory
        self.isEnabled = isEnabled
        self.runAtLaunch = runAtLaunch
        self.tags = tags
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
    }
}

enum RunStatus: String, Codable {
    case idle
    case running
    case success
    case failed
    case stopped

    var label: String {
        L10n.text(localizationKey)
    }

    var localizationKey: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .success: return "Success"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .gray
        case .running: return .orange
        case .success: return .green
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}

struct ScriptRunState: Equatable {
    var status: RunStatus
    var lastMessage: String
    var startedAt: Date?
    var endedAt: Date?
    var exitCode: Int?
    var pid: Int32? = nil

    static var idle: ScriptRunState {
        ScriptRunState(
            status: .idle,
            lastMessage: "",
            startedAt: nil,
            endedAt: nil,
            exitCode: nil
        )
    }

    /// Calculated duration of the script run
    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = endedAt ?? Date()
        return end.timeIntervalSince(start)
    }

    /// Human-readable duration string
    var formattedDuration: String? {
        guard let duration = duration else { return nil }
        if duration < 60 {
            return String(format: "%.1fs", duration)
        } else if duration < 3600 {
            return String(format: "%.1fm", duration / 60)
        } else {
            return String(format: "%.1fh", duration / 3600)
        }
    }
}
