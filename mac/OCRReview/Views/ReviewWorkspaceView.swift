import SwiftUI

struct ReviewWorkspaceView: View {
    @ObservedObject var model: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)

            if model.isFindVisible {
                FindReplaceBar(model: model)
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider().overlay(Theme.hairline)
            }

            HSplitView {
                pagePane
                    .frame(minWidth: 380)
                OCRTextEditorView(
                    text: model.currentPageBinding,
                    placeholder: model.currentPagePlaceholder,
                    suspectBlocks: model.lowConfidenceBlocks,
                    editorModeLabel: model.editorModeLabel,
                    showBlockHint: !model.currentBlocks.isEmpty,
                    selectedBlockID: model.selectedBlockID,
                    canRevert: model.canRevertSelection,
                    isRedacted: model.isSelectedRegionRedacted,
                    onSelectBlock: { model.selectBlockFromSuspect($0) },
                    onClearSelection: { model.selectBlock(nil) },
                    onRevert: { model.revertSelection() },
                    onRedact: { model.toggleRedactionForSelection() },
                    spellIssueRefs: model.activeSpellIssueRefs,
                    onApplySpellFix: { model.applySpellFix($0, replacement: $1) }
                )
                .frame(minWidth: 340)
            }

            if model.totalPages > 1 {
                Divider().overlay(Theme.hairline)
                PageThumbnailStrip(
                    totalPages: model.totalPages,
                    currentPageIndex: $model.currentPageIndex,
                    document: model.pdfDocument,
                    ocrPageNumbers: model.ocrPageNumbers,
                    issuePageNumbers: model.issuePageNumbers,
                    onMovePage: { from, to in model.movePage(from: from, to: to) },
                    onRotatePage: { index, clockwise in model.rotatePage(at: index, clockwise: clockwise) },
                    onDeletePage: { index in model.deletePage(at: index) }
                )
                .onChange(of: model.currentPageIndex) { _, newIndex in
                    Task { await model.ensurePageRecognized(at: newIndex) }
                }
            }
        }
        .background(Theme.bg)
        .animation(Theme.Motion.snappy, value: model.isFindVisible)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button { model.closeDocument() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(ToolbarIconButtonStyle())
                .help("Back to library")

            titleBlock

            Spacer(minLength: Theme.Spacing.md)

            pageNavCluster

            if model.document?.ocrPageCount ?? 0 > 0 {
                reviewHUD
            }

            if model.isProcessing {
                progressCapsule
            }

            Spacer(minLength: Theme.Spacing.md)

            actionCluster
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm + 2)
        .background(Theme.surface)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.document?.filename ?? "Document")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: model.engineIsLocal ? "cpu" : "cloud")
                    .font(.system(size: 9))
                Text(model.engineShortLabel)
                if model.pdfDocumentModified {
                    Text("· Edited").foregroundStyle(Theme.warning)
                }
                if let doc = model.document, doc.ocrPageCount < model.totalPages {
                    Text("· OCR \(doc.ocrPageCount)/\(model.totalPages)").foregroundStyle(Theme.warning)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.dim)
            .lineLimit(1)
        }
        .fixedSize()
    }

    private var pageNavCluster: some View {
        HStack(spacing: 2) {
            Button { model.goToPage(model.currentPageIndex - 1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(ToolbarIconButtonStyle())
                .disabled(model.currentPageIndex <= 0)

            HStack(spacing: 4) {
                TextField("", text: $model.pageJumpText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: 34)
                    .onSubmit { model.jumpToPageFromField() }
                Text("/ \(model.totalPages)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, Theme.Spacing.sm)

            Button { model.goToPage(model.currentPageIndex + 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(ToolbarIconButtonStyle())
                .disabled(model.currentPageIndex >= model.totalPages - 1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .panelBackground(radius: Theme.Radius.md, fill: Theme.bg, stroke: Theme.border)
    }

    private var reviewHUD: some View {
        HStack(spacing: 4) {
            Button { model.goToPreviousIssue() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(ToolbarIconButtonStyle())
                .disabled(!model.hasReviewIssues)
                .help("Previous issue (⌥↑)")

            HStack(spacing: 5) {
                Image(systemName: model.hasReviewIssues ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(model.reviewSummary)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(model.hasReviewIssues ? Theme.warning : Theme.success)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill((model.hasReviewIssues ? Theme.warning : Theme.success).opacity(0.15)))

            Button { model.goToNextIssue() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(ToolbarIconButtonStyle())
                .disabled(!model.hasReviewIssues)
                .help("Next issue (⌥↓)")

            Button { model.showConfidenceHeatmap.toggle() } label: { Image(systemName: "thermometer.medium") }
                .buttonStyle(ToolbarIconButtonStyle(active: model.showConfidenceHeatmap))
                .help("Confidence heatmap (⌘⌥H)")
        }
    }

    private var progressCapsule: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProgressView(value: model.progress)
                .frame(width: 90)
            Text("\(Int(model.progress * 100))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.accentSoft))
        .transition(.scale.combined(with: .opacity))
    }

    private var actionCluster: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                model.isCommandPaletteVisible = true
            } label: { Image(systemName: "command") }
                .buttonStyle(ToolbarIconButtonStyle())
                .help("Command palette (⌘K)")

            Button {
                model.isFindVisible.toggle()
                if model.isFindVisible { model.refreshFindResults() }
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(ToolbarIconButtonStyle(active: model.isFindVisible))
                .help("Find & replace (⌘F)")

            Menu {
                Button("This Page") { model.recognizeCurrentPage() }
                Button("All Pages…") { model.recognizeAllPages() }
            } label: {
                menuChip("Recognize", systemImage: "text.viewfinder")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.loadedSource == nil || model.isProcessing)

            Menu {
                Button { model.rotateCurrentPage(clockwise: true) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                Button { model.rotateCurrentPage(clockwise: false) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                Divider()
                Button("Append PDFs…") { model.appendPDFs() }
                Button("Combine PDFs…") { model.combinePDFs() }
                Button("Extract Pages…") { model.splitPDFPrompt() }
                Divider()
                Button(role: .destructive) { model.deleteCurrentPage() } label: { Label("Delete This Page…", systemImage: "trash") }
                    .disabled(model.totalPages <= 1)
            } label: {
                menuChip("Pages", systemImage: "doc.on.doc")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.pdfDocument == nil)

            Menu {
                Button("Markdown (.md)") { model.exportMarkdown() }
                Button("Word (.docx)") { model.exportDOCX() }
                    .disabled(model.document?.ocrPageCount == 0)
                Button("Searchable PDF") { model.exportSearchablePDF() }
                    .disabled(model.document?.ocrPageCount == 0)
                Divider()
                Button("Plain Text (.txt)") { model.exportText() }
                Button("Rich Text (.rtf)") { model.exportRTF() }
                Divider()
                Button("Copy Page Text") { model.copyCurrentPageText() }
                Button("Copy All Text") { model.copyAllText() }
            } label: {
                menuChip("Export", systemImage: "square.and.arrow.up", primary: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.document == nil || model.isProcessing)
        }
    }

    private func menuChip(_ title: String, systemImage: String, primary: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(primary ? .white : Theme.textSecondary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(primary ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.surfaceHigh))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(primary ? .white.opacity(0.14) : Theme.hairline, lineWidth: 1)
        )
        .shadow(color: primary ? Theme.accent.opacity(0.3) : .clear, radius: 8, y: 3)
    }

    // MARK: - Page pane

    @ViewBuilder
    private var pagePane: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.bg

            Group {
                if let source = model.loadedSource {
                    switch source {
                    case .pdf:
                        PDFPageViewWithBlocks(
                            document: model.pdfDocument,
                            pageIndex: model.currentPageIndex,
                            blocks: model.currentBlocks,
                            selectedBlockID: model.selectedBlockID,
                            showHeatmap: model.showConfidenceHeatmap,
                            redactedBlockIDs: model.currentRedactedBlockIDs,
                            controller: model.pdfController,
                            onSelectBlock: { model.selectBlock($0) }
                        )
                    case .image(let url):
                        ImagePageViewWithBlocks(
                            url: url,
                            blocks: model.currentBlocks,
                            selectedBlockID: model.selectedBlockID,
                            showHeatmap: model.showConfidenceHeatmap,
                            redactedBlockIDs: model.currentRedactedBlockIDs,
                            onSelectBlock: { model.selectBlock($0) }
                        )
                    }
                } else {
                    ContentUnavailableView("No page", systemImage: "doc")
                }
            }
            .padding(Theme.Spacing.md)

            if case .pdf = model.loadedSource {
                ZoomControls(controller: model.pdfController)
                    .padding(Theme.Spacing.lg)
            }
        }
    }
}

// MARK: - Zoom controls

private struct ZoomControls: View {
    @ObservedObject var controller: PDFViewController

    var body: some View {
        HStack(spacing: 2) {
            Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(ToolbarIconButtonStyle())
            Button { controller.actualSize() } label: {
                Text("\(controller.scalePercent)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 42)
            }
            .buttonStyle(.plain)
            .help("Actual size")
            Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(ToolbarIconButtonStyle())
            Rectangle().fill(Theme.border).frame(width: 1, height: 18).padding(.horizontal, 2)
            Button { controller.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(ToolbarIconButtonStyle())
                .help("Fit to window")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }
}
