import Foundation
import Darwin
import os.log

/// Thread-safe process state management using actor isolation
actor ProcessState {
    private var runningProcesses: [UUID: Process] = [:]
    private var runningProcessIds: [UUID: pid_t] = [:]
    private var stoppedIds: Set<UUID> = []
    private var outputBuffers: [UUID: String] = [:]

    func setProcess(_ process: Process, for id: UUID) {
        runningProcesses[id] = process
        runningProcessIds[id] = process.processIdentifier
    }

    func getProcess(for id: UUID) -> Process? {
        runningProcesses[id]
    }

    func getPid(for id: UUID) -> pid_t? {
        runningProcessIds[id]
    }

    func clearProcess(for id: UUID) {
        runningProcesses[id] = nil
        runningProcessIds[id] = nil
    }

    func markAsStopped(_ id: UUID) {
        stoppedIds.insert(id)
    }

    func checkAndClearStopped(_ id: UUID) -> Bool {
        stoppedIds.remove(id) != nil
    }

    func hasRunningProcess(for id: UUID) -> Bool {
        runningProcesses[id] != nil
    }

    func restoreProcessId(_ pid: pid_t, for id: UUID) {
        runningProcessIds[id] = pid
    }

    // Output buffer management
    func appendOutput(for id: UUID, text: String, maxLength: Int = 10000) {
        var buffer = outputBuffers[id] ?? ""
        buffer.append(text)
        if buffer.count > maxLength {
            buffer = String(buffer.suffix(maxLength))
        }
        outputBuffers[id] = buffer
    }

    func getOutput(for id: UUID) -> String {
        outputBuffers[id] ?? ""
    }

    func clearOutput(for id: UUID) {
        outputBuffers[id] = nil
    }

    func clearAllOutputs() {
        outputBuffers.removeAll()
    }
}

/// Errors that can occur during process operations
enum ProcessError: LocalizedError {
    case scriptDisabled
    case emptyCommand
    case alreadyRunning
    case startFailed(underlying: Error)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .scriptDisabled:
            return "Script is disabled"
        case .emptyCommand:
            return "Command is empty"
        case .alreadyRunning:
            return "Script is already running"
        case .startFailed(let error):
            return "Failed to start: \(error.localizedDescription)"
        case .notRunning:
            return "Script is not running"
        }
    }
}

/// Persisted run state for process recovery across app restarts
private struct PersistedRunState: Codable {
    let pid: pid_t
    let startedAt: TimeInterval
}

/// Handles all process lifecycle management with proper thread safety
@MainActor
final class ProcessManager: ObservableObject {
    private let logger = AppLogger.process
    private let processState = ProcessState()
    private let persistedStateKey = "scriptserRunState"

    @Published var runStates: [UUID: ScriptRunState] = [:]

    /// Callback for state changes
    var onStateChange: ((UUID, ScriptRunState) -> Void)?

    init() {
        logger.info("ProcessManager initialized")
    }

    func status(for id: UUID) -> ScriptRunState {
        runStates[id] ?? .idle
    }

    func isRunning(_ id: UUID) -> Bool {
        status(for: id).status == .running
    }

    func getOutput(for id: UUID) async -> String {
        await processState.getOutput(for: id)
    }

    func clearOutput(for id: UUID) async {
        await processState.clearOutput(for: id)
    }

    func run(_ script: ScriptEntry) async throws {
        guard script.isEnabled else {
            updateState(script.id, ScriptRunState(
                status: .failed,
                lastMessage: ProcessError.scriptDisabled.localizedDescription,
                startedAt: nil,
                endedAt: Date(),
                exitCode: nil
            ))
            throw ProcessError.scriptDisabled
        }

        guard await !processState.hasRunningProcess(for: script.id) else {
            throw ProcessError.alreadyRunning
        }

        let trimmedCommand = script.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            updateState(script.id, ScriptRunState(
                status: .failed,
                lastMessage: ProcessError.emptyCommand.localizedDescription,
                startedAt: nil,
                endedAt: Date(),
                exitCode: nil
            ))
            throw ProcessError.emptyCommand
        }

        logger.info("Starting script: \(script.name) with command: \(trimmedCommand)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -i: interactive (reads .zshrc), -l: login (reads .zprofile), -c: execute command
        process.arguments = ["-ilc", script.command]

        let workingDir = script.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workingDir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let startTime = Date()
        updateState(script.id, ScriptRunState(
            status: .running,
            lastMessage: "Running",
            startedAt: startTime,
            endedAt: nil,
            exitCode: nil
        ))

        // Clear previous output
        await processState.clearOutput(for: script.id)

        // Handle output asynchronously with proper thread safety
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

            Task { [weak self] in
                await self?.processState.appendOutput(for: script.id, text: text)
            }
        }

        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor [weak self] in
                pipe.fileHandleForReading.readabilityHandler = nil
                await self?.handleTermination(for: script.id, process: finishedProcess)
            }
        }

        do {
            try process.run()
            await processState.setProcess(process, for: script.id)
            setPersistedRunState(for: script.id, pid: process.processIdentifier, startedAt: startTime)
            logger.info("Script started with PID: \(process.processIdentifier)")
        } catch {
            logger.error("Failed to start script: \(error.localizedDescription)")
            updateState(script.id, ScriptRunState(
                status: .failed,
                lastMessage: ProcessError.startFailed(underlying: error).localizedDescription,
                startedAt: nil,
                endedAt: Date(),
                exitCode: nil
            ))
            throw ProcessError.startFailed(underlying: error)
        }
    }

    func stop(_ scriptId: UUID) async {
        var didStop = false

        if let process = await processState.getProcess(for: scriptId) {
            await processState.markAsStopped(scriptId)
            process.terminate()
            didStop = true
            clearPersistedRunState(for: scriptId)
            logger.info("Terminated process for script: \(scriptId)")
        } else if let pid = await processState.getPid(for: scriptId) {
            await processState.markAsStopped(scriptId)
            kill(pid, SIGTERM)
            await processState.clearProcess(for: scriptId)
            clearPersistedRunState(for: scriptId)
            didStop = true
            logger.info("Killed process PID \(pid) for script: \(scriptId)")
        }

        guard didStop else { return }

        updateState(scriptId, ScriptRunState(
            status: .stopped,
            lastMessage: "Stopped by user",
            startedAt: status(for: scriptId).startedAt,
            endedAt: Date(),
            exitCode: nil
        ))
    }

    func syncRunningStates(for scripts: [ScriptEntry]) {
        var persistedStates = loadPersistedRunStates()
        let validIds = Set(scripts.map { $0.id.uuidString })

        // Clean up invalid persisted states
        let originalCount = persistedStates.count
        persistedStates = persistedStates.filter { validIds.contains($0.key) }
        if persistedStates.count != originalCount {
            savePersistedRunStates(persistedStates)
        }

        for script in scripts {
            guard let persisted = persistedStates[script.id.uuidString] else { continue }

            if isProcessRunning(pid: persisted.pid) {
                Task {
                    await processState.restoreProcessId(persisted.pid, for: script.id)
                }
                updateState(script.id, ScriptRunState(
                    status: .running,
                    lastMessage: "Running (restored)",
                    startedAt: Date(timeIntervalSince1970: persisted.startedAt),
                    endedAt: nil,
                    exitCode: nil
                ))
                logger.info("Restored running state for script: \(script.id)")
            } else {
                Task {
                    await processState.clearProcess(for: script.id)
                }
                var updatedStates = persistedStates
                updatedStates.removeValue(forKey: script.id.uuidString)
                savePersistedRunStates(updatedStates)
                updateState(script.id, .idle)
            }
        }
    }

    // MARK: - Private Methods

    private func handleTermination(for scriptId: UUID, process: Process) async {
        await processState.clearProcess(for: scriptId)
        clearPersistedRunState(for: scriptId)

        let exitCode = Int(process.terminationStatus)
        let wasStopped = await processState.checkAndClearStopped(scriptId)

        let status: RunStatus
        let message: String

        if wasStopped {
            status = .stopped
            message = "Stopped by user"
        } else if exitCode == 0 {
            status = .success
            message = "Exit code 0"
        } else {
            status = .failed
            message = "Exit code \(exitCode)"
        }

        logger.info("Script \(scriptId) terminated with status: \(status.rawValue), exit code: \(exitCode)")

        updateState(scriptId, ScriptRunState(
            status: status,
            lastMessage: message,
            startedAt: runStates[scriptId]?.startedAt,
            endedAt: Date(),
            exitCode: exitCode
        ))
    }

    private func updateState(_ id: UUID, _ state: ScriptRunState) {
        runStates[id] = state
        onStateChange?(id, state)
    }

    private func isProcessRunning(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let result = kill(pid, 0)
        return result == 0 || errno == EPERM
    }

    // MARK: - Persistence

    private func setPersistedRunState(for id: UUID, pid: pid_t, startedAt: Date) {
        var states = loadPersistedRunStates()
        states[id.uuidString] = PersistedRunState(pid: pid, startedAt: startedAt.timeIntervalSince1970)
        savePersistedRunStates(states)
    }

    private func clearPersistedRunState(for id: UUID) {
        var states = loadPersistedRunStates()
        states.removeValue(forKey: id.uuidString)
        savePersistedRunStates(states)
    }

    private func loadPersistedRunStates() -> [String: PersistedRunState] {
        guard let data = UserDefaults.standard.data(forKey: persistedStateKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: PersistedRunState].self, from: data)) ?? [:]
    }

    private func savePersistedRunStates(_ states: [String: PersistedRunState]) {
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: persistedStateKey)
        }
    }
}
