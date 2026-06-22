import Foundation

@MainActor
final class SidecarProcessManager: ObservableObject {
    static let shared = SidecarProcessManager()

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Sidecar not started"
    @Published private(set) var lastError: AppError?

    private var process: Process?
    private var didAttemptStart = false
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var recentOutput = ""

    private init() {}

    func ensureRunning() async {
        if await EngineSidecarClient.isAvailable() {
            isRunning = true
            lastError = nil
            statusMessage = "Sidecar running at \(SidecarConfig.baseURL)"
            return
        }

        if !didAttemptStart {
            didAttemptStart = true
            start()
        }

        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await EngineSidecarClient.isAvailable() {
                isRunning = true
                statusMessage = "Sidecar started at \(SidecarConfig.baseURL)"
                return
            }
        }

        isRunning = false
        let error = diagnoseStartupFailure()
        lastError = error
        statusMessage = error.userMessage
        DiagnosticsLogger.shared.log(
            level: .error,
            event: "sidecar.startup_failed",
            context: ["message": error.userMessage, "technical": error.technicalMessage ?? ""]
        )
    }

    func restart() async {
        stop()
        didAttemptStart = false
        await ensureRunning()
    }

    func clearLastError() {
        lastError = nil
    }

    func start() {
        guard process == nil || process?.isRunning == false else { return }

        guard let projectRoot = resolveProjectRoot() else {
            let error = AppError(
                kind: .sidecar,
                title: "Sidecar project not found",
                userMessage: "OCR Review could not find the MarkItDown project folder.",
                recoveryAction: "Set the project path in Settings."
            )
            lastError = error
            statusMessage = error.userMessage
            DiagnosticsLogger.shared.log(level: .error, event: "sidecar.project_root_missing")
            return
        }

        let uvPath = resolveUVPath()
        let endpoint = sidecarEndpoint()
        recentOutput = ""
        lastError = nil

        let launcher = Process()
        if uvPath.hasPrefix("/") {
            launcher.executableURL = URL(fileURLWithPath: uvPath)
            launcher.arguments = [
                "run", "uvicorn", "markitdown_api.main:app",
                "--host", endpoint.host,
                "--port", endpoint.port,
                "--app-dir", "api",
            ]
        } else {
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            launcher.arguments = [
                uvPath, "run", "uvicorn", "markitdown_api.main:app",
                "--host", endpoint.host,
                "--port", endpoint.port,
                "--app-dir", "api",
            ]
        }
        launcher.currentDirectoryURL = projectRoot
        let stdout = Pipe()
        let stderr = Pipe()
        launcher.standardOutput = stdout
        launcher.standardError = stderr
        outputPipe = stdout
        errorPipe = stderr
        attachLogging(pipe: stdout, label: "stdout")
        attachLogging(pipe: stderr, label: "stderr")
        launcher.terminationHandler = { [weak self] proc in
            DiagnosticsLogger.shared.log(
                level: proc.terminationStatus == 0 ? .info : .error,
                event: "sidecar.exited",
                context: ["status": "\(proc.terminationStatus)"]
            )
            Task { @MainActor in
                if self?.process === proc {
                    self?.process = nil
                    self?.isRunning = false
                    self?.outputPipe?.fileHandleForReading.readabilityHandler = nil
                    self?.errorPipe?.fileHandleForReading.readabilityHandler = nil
                    // Allow the next ensureRunning() to relaunch — without this, a
                    // crashed sidecar leaves every dependent action stalling for the
                    // full health-poll timeout until the user manually restarts.
                    self?.didAttemptStart = false
                }
            }
        }

        do {
            try launcher.run()
            process = launcher
            statusMessage = "Starting sidecar…"
            DiagnosticsLogger.shared.log(
                level: .info,
                event: "sidecar.launch_started",
                context: ["projectRoot": projectRoot.path, "uv": uvPath, "baseURL": SidecarConfig.baseURL]
            )
        } catch {
            let appError = AppError(
                kind: .sidecar,
                title: "Sidecar launch failed",
                userMessage: "OCR Review could not launch the Python sidecar.",
                technicalMessage: String(describing: error),
                recoveryAction: "Check that uv is installed and the project path is correct."
            )
            lastError = appError
            statusMessage = appError.userMessage
            DiagnosticsLogger.shared.log(
                level: .error,
                event: "sidecar.launch_failed",
                context: ["error": String(describing: error)]
            )
        }
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        outputPipe = nil
        errorPipe = nil
        isRunning = false
    }

    func resolveProjectRoot() -> URL? {
        if let configured = OCRSettings.projectRootPath,
           FileManager.default.fileExists(atPath: configured)
        {
            return URL(fileURLWithPath: configured)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("markitdown-app"),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
        ]

        for candidate in candidates {
            let apiDir = candidate.appendingPathComponent("api/markitdown_api")
            if FileManager.default.fileExists(atPath: apiDir.path) {
                return candidate
            }
        }
        return nil
    }

    private func sidecarEndpoint() -> (host: String, port: String) {
        guard let url = URL(string: SidecarConfig.baseURL) else {
            return ("127.0.0.1", "8001")
        }
        let host = url.host.flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        let port = String(url.port ?? 8001)
        return (host, port)
    }

    private func resolveUVPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            home.appendingPathComponent(".local/bin/uv").path,
            home.appendingPathComponent(".cargo/bin/uv").path,
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "uv"
    }

    private func attachLogging(pipe: Pipe, label: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            DiagnosticsLogger.shared.log(
                level: label == "stderr" ? .warning : .info,
                event: "sidecar.\(label)",
                context: ["output": text]
            )
            Task { @MainActor in
                self?.appendRecentOutput(text)
            }
        }
    }

    private func appendRecentOutput(_ text: String) {
        recentOutput += text
        if recentOutput.count > 8_000 {
            recentOutput = String(recentOutput.suffix(8_000))
        }
    }

    private func diagnoseStartupFailure() -> AppError {
        if resolveProjectRoot() == nil {
            return AppError(
                kind: .sidecar,
                title: "Sidecar project not found",
                userMessage: "OCR Review could not find the MarkItDown project folder.",
                technicalMessage: recentOutput,
                recoveryAction: "Set the project path in Settings."
            )
        }

        let output = recentOutput.lowercased()
        if output.contains("address already in use") || output.contains("errno 48") {
            return AppError(
                kind: .sidecar,
                title: "Sidecar port in use",
                userMessage: "The sidecar port is already in use.",
                technicalMessage: recentOutput,
                recoveryAction: "Stop the other process or change the sidecar URL in Settings, then retry."
            )
        }

        if output.contains("env: uv") || output.contains("uv: no such file") || output.contains("no such file or directory: 'uv'") {
            return AppError(
                kind: .sidecar,
                title: "uv is missing",
                userMessage: "OCR Review could not find uv to start the Python sidecar.",
                technicalMessage: recentOutput,
                recoveryAction: "Install uv or add it to PATH, then restart the sidecar."
            )
        }

        if output.contains("could not import module") || output.contains("markitdown_api") {
            return AppError(
                kind: .sidecar,
                title: "Sidecar project path is invalid",
                userMessage: "The sidecar started from a folder that does not expose the MarkItDown API module.",
                technicalMessage: recentOutput,
                recoveryAction: "Set the repository root in Settings."
            )
        }

        return AppError(
            kind: .sidecar,
            title: "Sidecar unhealthy",
            userMessage: "The Python sidecar did not become healthy in time.",
            technicalMessage: recentOutput.isEmpty ? nil : recentOutput,
            recoveryAction: "Open Settings, verify the URL and project path, then retry."
        )
    }
}
