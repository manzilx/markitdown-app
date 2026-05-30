import Foundation

@MainActor
final class SidecarProcessManager: ObservableObject {
    static let shared = SidecarProcessManager()

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Sidecar not started"

    private var process: Process?
    private var didAttemptStart = false

    private init() {}

    func ensureRunning() async {
        if await EngineSidecarClient.isAvailable() {
            isRunning = true
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
        statusMessage = "Could not start sidecar automatically. Check project path in Settings."
    }

    func restart() async {
        stop()
        didAttemptStart = false
        await ensureRunning()
    }

    func start() {
        guard process == nil || process?.isRunning == false else { return }

        guard let projectRoot = resolveProjectRoot() else {
            statusMessage = "MarkItDown project not found. Set path in Settings."
            return
        }

        let uvPath = resolveUVPath()
        let shellCommand = """
        cd '\(projectRoot.path)' && '\(uvPath)' run uvicorn markitdown_api.main:app --host 127.0.0.1 --port 8001 --app-dir api
        """

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/zsh")
        launcher.arguments = ["-lc", shellCommand]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        launcher.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                if self?.process === proc {
                    self?.process = nil
                    self?.isRunning = false
                }
            }
        }

        do {
            try launcher.run()
            process = launcher
            statusMessage = "Starting sidecar…"
        } catch {
            statusMessage = "Failed to launch sidecar: \(error.localizedDescription)"
        }
    }

    func stop() {
        process?.terminate()
        process = nil
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
}
