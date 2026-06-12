import SwiftUI

@main
struct OCRReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DocumentViewModel()
    @StateObject private var jobStore = JobStore.shared
    @StateObject private var sidecarManager = SidecarProcessManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, jobStore: jobStore, sidecarManager: sidecarManager)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(.dark)
                .task {
                    // Don't spawn the sidecar while running unit tests.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    await sidecarManager.ensureRunning()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Document…") {
                    model.openDocument()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("OCR") {
                Button("Recognize This Page") {
                    model.recognizeCurrentPage()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.loadedSource == nil)

                Button("Recognize All Pages…") {
                    model.recognizeAllPages()
                }
                .disabled(model.loadedSource == nil)

                Button("Cancel Current Operation") {
                    model.cancelCurrentOperation()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isProcessing)

                Divider()

                Button("Export Markdown…") {
                    model.exportMarkdown()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.document == nil)

                Button("Export Word…") {
                    model.exportDOCX()
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.document == nil || model.document?.ocrPageCount == 0)

                Button("Export Searchable PDF…") {
                    model.exportSearchablePDF()
                }
                .disabled(model.document == nil || model.document?.ocrPageCount == 0)

                Divider()

                Button("Export Plain Text…") { model.exportText() }
                    .disabled(model.document == nil)
                Button("Export Rich Text…") { model.exportRTF() }
                    .disabled(model.document == nil)
            }

            CommandMenu("View") {
                Button("Command Palette…") { model.isCommandPaletteVisible.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Zoom In") { model.pdfController.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(model.pdfDocument == nil)
                Button("Zoom Out") { model.pdfController.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model.pdfDocument == nil)
                Button("Fit to Window") { model.pdfController.fit() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(model.pdfDocument == nil)
                Button("Actual Size") { model.pdfController.actualSize() }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(model.pdfDocument == nil)
            }

            CommandMenu("Review") {
                Button("Next Issue") { model.goToNextIssue() }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                    .disabled(!model.hasReviewIssues)
                Button("Previous Issue") { model.goToPreviousIssue() }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                    .disabled(!model.hasReviewIssues)
                Divider()
                Button(model.showConfidenceHeatmap ? "Hide Confidence Heatmap" : "Show Confidence Heatmap") {
                    model.showConfidenceHeatmap.toggle()
                }
                .keyboardShortcut("h", modifiers: [.command, .option])
                .disabled(model.document == nil)
                Button("Denoise Repeated Headers/Footers…") {
                    model.denoiseDocument()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!model.canDenoiseDocument)
                Divider()
                Button(model.isSelectedRegionRedacted ? "Un-redact Region" : "Redact Region") {
                    model.toggleRedactionForSelection()
                }
                .disabled(model.selectedBlockID == nil)
                Button("Revert Page to OCR…") { model.revertCurrentPage() }
                    .disabled(model.document == nil)
            }

            CommandMenu("Pages") {
                Button("Rotate Right") { model.rotateCurrentPage(clockwise: true) }
                    .disabled(model.pdfDocument == nil)
                Button("Rotate Left") { model.rotateCurrentPage(clockwise: false) }
                    .disabled(model.pdfDocument == nil)
                Divider()
                Button("Append PDFs…") { model.appendPDFs() }
                    .disabled(model.pdfDocument == nil)
                Button("Combine PDFs…") { model.combinePDFs() }
                Button("Extract Pages…") { model.splitPDFPrompt() }
                    .disabled(model.pdfDocument == nil)
                Divider()
                Button("Delete This Page…") { model.deleteCurrentPage() }
                    .disabled(model.pdfDocument == nil || model.totalPages <= 1)
            }

            CommandGroup(after: .pasteboard) {
                Button("Find…") {
                    model.isFindVisible = true
                    model.refreshFindResults()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.document == nil)
            }

            CommandGroup(after: .toolbar) {
                Button("Previous Page") {
                    model.goToPage(model.currentPageIndex - 1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button("Next Page") {
                    model.goToPage(model.currentPageIndex + 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            JobStore.shared.flushSynchronously()
            // Kill the spawned Python sidecar — otherwise it outlives the app,
            // holding port 8001 and serving stale code forever.
            SidecarProcessManager.shared.stop()
        }
    }
}

struct SettingsView: View {
    @AppStorage(OCRSettings.engineKey) private var selectedEngine = "vision"
    @AppStorage(OCRSettings.sidecarURLKey) private var sidecarURL = SidecarConfig.defaultBaseURL
    @AppStorage(OCRSettings.projectRootKey) private var projectRoot = ""
    @ObservedObject private var sidecarManager = SidecarProcessManager.shared

    @State private var sidecarHealthy = false
    @State private var sidecarEngines: [EngineSidecarClient.SidecarEngineInfo] = []
    @State private var projectRootRestart: Task<Void, Never>?

    private var sidecarOCREngines: [EngineSidecarClient.SidecarEngineInfo] {
        sidecarEngines.filter(\.supportsPageOCR)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.brandGradient)
                        .frame(width: 46, height: 46)
                        .overlay(
                            Image(systemName: "doc.text.viewfinder")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OCR Review").font(.headline)
                        Text("On-device OCR with human review · v1.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Python sidecar") {
                HStack(spacing: 10) {
                    StatusDot(color: sidecarHealthy ? Theme.success : Theme.danger, pulsing: sidecarHealthy)
                    Text(sidecarManager.statusMessage)
                        .font(.callout)
                    Spacer()
                    Button("Restart") {
                        Task {
                            await sidecarManager.restart()
                            await refreshSidecarStatus()
                        }
                    }
                    .controlSize(.small)
                    Button("Refresh") { Task { await refreshSidecarStatus() } }
                        .controlSize(.small)
                }

                TextField("Project path", text: $projectRoot, prompt: Text("~/markitdown-app"))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())

                TextField("URL", text: $sidecarURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())

                Text("The app auto-starts the sidecar on launch using uv from the project path above. Word export, searchable PDF, and sidecar OCR engines need it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OCR engine") {
                Picker("Engine", selection: $selectedEngine) {
                    Text("Apple Vision (on-device)").tag("vision")
                    ForEach(sidecarOCREngines) { engine in
                        Text(enginePickerLabel(engine)).tag(engine.id)
                            .disabled(!engine.available)
                    }
                }

                if selectedEngine != "vision",
                   let engine = sidecarEngines.first(where: { $0.id == selectedEngine }),
                   let reason = engine.reason, !engine.available
                {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(engineDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
        .task { await refreshSidecarStatus() }
        .onChange(of: sidecarURL) { _, _ in Task { await refreshSidecarStatus() } }
        .onChange(of: projectRoot) { _, _ in
            // Debounce: this fires per keystroke, and each restart is a kill + spawn +
            // health poll. Only restart once typing pauses.
            projectRootRestart?.cancel()
            projectRootRestart = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await sidecarManager.restart()
                await refreshSidecarStatus()
            }
        }
    }

    private var engineDescription: String {
        switch selectedEngine {
        case "vision":
            return "Apple Vision runs locally — free, private, offline. Best default for review workflows."
        case "azure_doc_intel":
            return "Azure Document Intelligence for hard scans, tables, and forms. Requires MARKITDOWN_DOCINTEL_* in .env."
        case "pymupdf4llm":
            return "PyMuPDF4LLM is a document converter, not a page-image OCR engine. Use it from the web converter, not OCR review."
        case "ocr_plugin":
            return "LLM vision OCR for embedded images. Requires MARKITDOWN_LLM_* in .env."
        case "builtin":
            return "Built-in MarkItDown is a document converter, not a page-image OCR engine. Use Apple Vision for local OCR."
        default:
            return "Selected engine runs through the Python sidecar per page."
        }
    }

    private func enginePickerLabel(_ engine: EngineSidecarClient.SidecarEngineInfo) -> String {
        if engine.badge.isEmpty {
            return engine.label
        }
        return "\(engine.label) · \(engine.badge)"
    }

    private func refreshSidecarStatus() async {
        if !(await EngineSidecarClient.isAvailable()) {
            await sidecarManager.ensureRunning()
        }
        sidecarHealthy = await EngineSidecarClient.isAvailable()
        if sidecarHealthy {
            do {
                sidecarEngines = try await EngineSidecarClient.fetchEngines()
                if selectedEngine != "vision",
                   !sidecarEngines.contains(where: { $0.id == selectedEngine && $0.available && $0.supportsPageOCR })
                {
                    selectedEngine = "vision"
                }
            } catch {
                sidecarEngines = []
            }
        } else {
            sidecarEngines = []
            if selectedEngine != "vision" {
                selectedEngine = "vision"
            }
        }
    }
}
