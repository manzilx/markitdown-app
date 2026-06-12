import SwiftUI

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    var shortcut: String?
    let group: String
    let isEnabled: Bool
    let action: () -> Void
}

struct CommandPaletteView: View {
    @ObservedObject var model: DocumentViewModel
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            palette
                .frame(width: 580)
                .padding(.top, 96)
        }
        .onExitCommand { close() }
        .onAppear {
            selection = 0
            fieldFocused = true
        }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "command")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                TextField("Search commands…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                    .focused($fieldFocused)
                    .onSubmit { runSelected() }
                    .onChange(of: query) { _, _ in selection = 0 }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Keycap("esc")
            }
            .padding(Theme.Spacing.lg)

            Divider().overlay(Theme.hairline)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        let results = filtered
                        if results.isEmpty {
                            Text("No matching commands")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.dim)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Spacing.xl)
                        } else {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                row(command, index: index)
                                    .id(index)
                            }
                        }
                    }
                    .padding(Theme.Spacing.sm)
                }
                .frame(maxHeight: 400)
                .onChange(of: selection) { _, new in
                    withAnimation(Theme.Motion.smooth) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .panelBackground(radius: Theme.Radius.xl, fill: Theme.surfaceHigh, stroke: Theme.border, shadow: true)
    }

    private func row(_ command: PaletteCommand, index: Int) -> some View {
        let isSelected = index == selection
        return Button {
            run(command)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Theme.accentBright : Theme.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(command.isEnabled ? Theme.text : Theme.dim)
                    Text(command.group)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                if let shortcut = command.shortcut {
                    Keycap(shortcut)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
            .opacity(command.isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!command.isEnabled)
    }

    // MARK: - Filtering

    private var filtered: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { matches(q, in: $0.title.lowercased()) }
    }

    private func matches(_ query: String, in text: String) -> Bool {
        if text.contains(query) { return true }
        var qi = query.startIndex
        for ch in text {
            if qi == query.endIndex { break }
            if ch == query[qi] { qi = query.index(after: qi) }
        }
        return qi == query.endIndex
    }

    // MARK: - Navigation

    private func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func runSelected() {
        let results = filtered
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    private func run(_ command: PaletteCommand) {
        guard command.isEnabled else { return }
        close()
        DispatchQueue.main.async { command.action() }
    }

    private func close() {
        withAnimation(Theme.Motion.snappy) { model.isCommandPaletteVisible = false }
        query = ""
    }

    // MARK: - Commands

    private var commands: [PaletteCommand] {
        let hasDoc = model.document != nil
        let hasSource = model.loadedSource != nil
        let hasOCR = (model.document?.ocrPageCount ?? 0) > 0
        let hasPDF = model.pdfDocument != nil

        var list: [PaletteCommand] = []
        func add(_ title: String, _ icon: String, group: String, shortcut: String? = nil, enabled: Bool = true, _ action: @escaping () -> Void) {
            list.append(PaletteCommand(title: title, systemImage: icon, shortcut: shortcut, group: group, isEnabled: enabled, action: action))
        }

        add("Open Document…", "folder", group: "File", shortcut: "⌘O") { model.openDocument() }
        if hasDoc { add("Back to Library", "rectangle.stack", group: "File") { model.closeDocument() } }

        add("Recognize This Page", "text.viewfinder", group: "OCR", shortcut: "⌘R", enabled: hasSource && !model.isProcessing) { model.recognizeCurrentPage() }
        add("Recognize All Pages…", "doc.text.magnifyingglass", group: "OCR", enabled: hasSource && !model.isProcessing) { model.recognizeAllPages() }

        add("Export Markdown…", "arrow.down.doc", group: "Export", shortcut: "⌘⇧E", enabled: hasDoc) { model.exportMarkdown() }
        add("Export Word…", "doc.richtext", group: "Export", shortcut: "⌘⌥E", enabled: hasOCR) { model.exportDOCX() }
        add("Export Searchable PDF…", "doc.text.image", group: "Export", enabled: hasOCR) { model.exportSearchablePDF() }
        add("Export Plain Text…", "doc.plaintext", group: "Export", enabled: hasDoc) { model.exportText() }
        add("Export Rich Text…", "textformat", group: "Export", enabled: hasDoc) { model.exportRTF() }
        add("Copy Page Text", "doc.on.clipboard", group: "Export", enabled: hasDoc) { model.copyCurrentPageText() }
        add("Copy All Text", "doc.on.doc", group: "Export", enabled: hasDoc) { model.copyAllText() }

        add("Find & Replace", "magnifyingglass", group: "Edit", shortcut: "⌘F", enabled: hasDoc) {
            model.isFindVisible = true
            model.refreshFindResults()
        }
        add("Denoise Repeated Headers/Footers", "wand.and.stars", group: "Edit", shortcut: "⌘⇧D", enabled: model.canDenoiseDocument) { model.denoiseDocument() }

        add("Next Issue", "arrow.down.circle", group: "Review", shortcut: "⌥↓", enabled: model.hasReviewIssues) { model.goToNextIssue() }
        add("Previous Issue", "arrow.up.circle", group: "Review", shortcut: "⌥↑", enabled: model.hasReviewIssues) { model.goToPreviousIssue() }
        add(model.showConfidenceHeatmap ? "Hide Confidence Heatmap" : "Show Confidence Heatmap", "thermometer.medium", group: "Review", shortcut: "⌘⌥H", enabled: hasDoc) { model.showConfidenceHeatmap.toggle() }
        add("Revert Page to OCR…", "arrow.uturn.backward", group: "Review", enabled: hasDoc) { model.revertCurrentPage() }

        add("Rotate Page Right", "rotate.right", group: "Pages", enabled: hasPDF) { model.rotateCurrentPage(clockwise: true) }
        add("Rotate Page Left", "rotate.left", group: "Pages", enabled: hasPDF) { model.rotateCurrentPage(clockwise: false) }
        add("Append PDFs…", "rectangle.stack.badge.plus", group: "Pages", enabled: hasPDF) { model.appendPDFs() }
        add("Combine PDFs…", "square.stack.3d.up", group: "Pages") { model.combinePDFs() }
        add("Extract Pages…", "scissors", group: "Pages", enabled: hasPDF) { model.splitPDFPrompt() }
        add("Delete This Page…", "trash", group: "Pages", enabled: hasPDF && model.totalPages > 1) { model.deleteCurrentPage() }

        add("Zoom In", "plus.magnifyingglass", group: "View", enabled: hasPDF) { model.pdfController.zoomIn() }
        add("Zoom Out", "minus.magnifyingglass", group: "View", enabled: hasPDF) { model.pdfController.zoomOut() }
        add("Fit to Window", "arrow.up.left.and.arrow.down.right", group: "View", enabled: hasPDF) { model.pdfController.fit() }
        add("Actual Size", "1.square", group: "View", enabled: hasPDF) { model.pdfController.actualSize() }
        add("Next Page", "arrow.right", group: "View", enabled: model.currentPageIndex < model.totalPages - 1) { model.goToPage(model.currentPageIndex + 1) }
        add("Previous Page", "arrow.left", group: "View", enabled: model.currentPageIndex > 0) { model.goToPage(model.currentPageIndex - 1) }

        return list
    }
}
