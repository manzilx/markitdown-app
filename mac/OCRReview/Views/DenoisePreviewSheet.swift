import SwiftUI

/// Pre-flight review for Denoise: shows every detected noise group with samples and
/// page coverage, lets the user keep or drop each group, then applies only what's on.
struct DenoisePreviewSheet: View {
    @ObservedObject var model: DocumentViewModel

    private var plan: DenoiseService.Plan? {
        model.denoisePreview?.plan
    }

    private var enabledKeys: Set<String> {
        model.denoisePreview?.enabledKeys ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(plan?.candidates ?? []) { candidate in
                        candidateRow(candidate)
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .frame(maxHeight: 360)

            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 520)
        .background(Theme.surface)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.brandGradient)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Denoise Document")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Review the repeated noise found in the OCR text. Anything you switch off is kept.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Rows

    private func candidateRow(_ candidate: DenoiseService.Candidate) -> some View {
        let isOn = binding(for: candidate.key)
        return HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: candidate.reason == .pageNumber ? "number.circle.fill" : "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? Theme.accentBright : Theme.dim)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(title(for: candidate))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: Theme.Spacing.sm) {
                    Pill("\(candidate.pages.count) page\(candidate.pages.count == 1 ? "" : "s")",
                         systemImage: "doc.on.doc",
                         color: isOn.wrappedValue ? Theme.accent : Theme.dim)
                    if !sampleText(for: candidate).isEmpty {
                        Text(sampleText(for: candidate))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.md)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(Theme.Spacing.md)
        .panelBackground(
            fill: Theme.surfaceElevated.opacity(isOn.wrappedValue ? 1 : 0.55),
            stroke: isOn.wrappedValue ? Theme.accent.opacity(0.35) : Theme.hairline
        )
        .animation(Theme.Motion.snappy, value: isOn.wrappedValue)
    }

    private func title(for candidate: DenoiseService.Candidate) -> String {
        if candidate.reason == .pageNumber {
            return "Page numbers"
        }
        return "“\(candidate.displayText)”"
    }

    private func sampleText(for candidate: DenoiseService.Candidate) -> String {
        guard candidate.reason == .pageNumber else { return "" }
        return candidate.samples.prefix(4).joined(separator: " · ")
    }

    // MARK: - Footer

    private var footer: some View {
        let count = plan?.removedLineCount(enabledKeys: enabledKeys) ?? 0
        let pages = plan?.affectedPageCount(enabledKeys: enabledKeys) ?? 0
        return HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 0
                     ? "Nothing selected"
                     : "Removes \(count) line\(count == 1 ? "" : "s") across \(pages) page\(pages == 1 ? "" : "s")")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(count == 0 ? Theme.dim : Theme.text)
                Text("Applies as editable text — Undo or page-level Revert restores the original OCR.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }

            Spacer()

            Button("Cancel") { model.cancelDenoisePreview() }
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut(.cancelAction)

            Button {
                model.applyDenoisePreview()
            } label: {
                Label(count == 0 ? "Remove" : "Remove \(count) Line\(count == 1 ? "" : "s")",
                      systemImage: "wand.and.stars")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(count == 0)
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Bindings

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { model.denoisePreview?.enabledKeys.contains(key) ?? false },
            set: { on in
                if on {
                    model.denoisePreview?.enabledKeys.insert(key)
                } else {
                    model.denoisePreview?.enabledKeys.remove(key)
                }
            }
        )
    }
}
