import SwiftUI

struct SuspectSpansView: View {
    let blocks: [OCRBlock]
    var onSelectBlock: ((OCRBlock) -> Void)?

    var body: some View {
        if blocks.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.warning)
                    Text("Needs review")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                    Text("\(blocks.count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.warning.opacity(0.8))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(blocks) { block in
                            Button {
                                onSelectBlock?(block)
                            } label: {
                                Text(block.text.isEmpty ? "—" : block.text)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .foregroundStyle(Theme.text)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule(style: .continuous).fill(Theme.warning.opacity(0.14))
                                    )
                                    .overlay(
                                        Capsule(style: .continuous).strokeBorder(Theme.warning.opacity(0.45), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(String(format: "Confidence %.0f%% — click to locate on page", block.confidence * 100))
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
            .padding(Theme.Spacing.md)
            .panelBackground(radius: Theme.Radius.md, fill: Theme.surface, stroke: Theme.warning.opacity(0.22))
        }
    }
}

struct OCRTextEditorView: View {
    @Binding var text: String
    var placeholder: String = ""
    let suspectBlocks: [OCRBlock]
    var editorModeLabel: String = "Edit to fix OCR errors"
    var showBlockHint: Bool = false
    var selectedBlockID: UUID?
    var canRevert: Bool = false
    var isRedacted: Bool = false
    var onSelectBlock: ((OCRBlock) -> Void)?
    var onClearSelection: (() -> Void)?
    var onRevert: (() -> Void)?
    var onRedact: (() -> Void)?
    var spellIssueRefs: [DocumentViewModel.SpellIssueRef] = []
    var onApplySpellFix: ((DocumentViewModel.SpellIssueRef, String) -> Void)?

    @FocusState private var editorFocused: Bool

    private var isRegion: Bool { selectedBlockID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header

            if isRegion, let onRedact {
                regionActions(onRedact: onRedact)
            }

            SuspectSpansView(blocks: suspectBlocks, onSelectBlock: onSelectBlock)

            SpellSuggestionsView(refs: spellIssueRefs) { ref, replacement in
                onApplySpellFix?(ref, replacement)
            }

            if showBlockHint, !isRegion {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 10))
                    Text("Click a highlighted region on the page to edit just that block.")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Theme.dim)
            }

            editor

            footer
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.surface.opacity(0.4))
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: isRegion ? "selection.pin.in.out" : "text.alignleft")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isRegion ? Theme.accent : Theme.textSecondary)
            Text(isRegion ? "Selected region" : "Recognized text")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Spacer()

            if canRevert {
                Button {
                    onRevert?()
                } label: {
                    Label(isRegion ? "Revert region" : "Revert page", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(GhostButtonStyle())
                .help("Restore the original recognized text")
            }

            if isRegion {
                Button {
                    onClearSelection?()
                } label: {
                    Label("Full page", systemImage: "rectangle.expand.vertical")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func regionActions(onRedact: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                onRedact()
            } label: {
                Label(isRedacted ? "Un-redact" : "Redact", systemImage: isRedacted ? "eye" : "eye.slash")
            }
            .buttonStyle(SoftButtonStyle(tint: isRedacted ? Theme.textSecondary : Theme.danger))
            .help("Black out this region and remove its text from exports")

            if isRedacted {
                Text("Redacted — hidden from exports")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
            }
            Spacer()
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty, !placeholder.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .padding(16)
            }
            TextEditor(text: $text)
                .font(.system(size: 13.5, design: .monospaced))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .padding(10)
                .focused($editorFocused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(editorFocused ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .animation(Theme.Motion.smooth, value: editorFocused)
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(editorModeLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
            Spacer()
            Text("\(wordCount) words · \(text.count) chars")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.dim)
        }
    }

    private var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}
