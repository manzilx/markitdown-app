import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: DocumentViewModel
    @ObservedObject var jobStore: JobStore
    var isDropTargeted: Bool = false

    var body: some View {
        ZStack {
            backdrop

            ScrollView {
                VStack(spacing: Theme.Spacing.xxl) {
                    hero
                    dropZone
                    if !jobStore.recents.isEmpty {
                        recents
                    }
                    Spacer(minLength: Theme.Spacing.lg)
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.xxxl)
            }
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            Theme.canvasGradient.ignoresSafeArea()
            Circle()
                .fill(Theme.accent.opacity(0.22))
                .frame(width: 460, height: 460)
                .blur(radius: 140)
                .offset(x: -120, y: -260)
            Circle()
                .fill(Color(red: 0.36, green: 0.74, blue: 0.92).opacity(0.16))
                .frame(width: 420, height: 420)
                .blur(radius: 150)
                .offset(x: 180, y: -160)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: Theme.Spacing.lg) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.brandGradient)
                .frame(width: 84, height: 84)
                .overlay(
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Theme.accent.opacity(0.5), radius: 28, y: 14)

            VStack(spacing: Theme.Spacing.sm) {
                Text("OCR Review")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("Recognize, review, and perfect text from any scanned PDF or image — then export to Markdown, Word, or a searchable PDF.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 460)
            }
        }
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isDropTargeted ? Theme.accentBright : Theme.dim)
                .scaleEffect(isDropTargeted ? 1.15 : 1)

            VStack(spacing: 4) {
                Text(isDropTargeted ? "Drop to open" : "Drag a PDF or image here")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("PDF · PNG · JPEG · TIFF · HEIC")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.dim)
            }

            Button {
                model.openDocument()
            } label: {
                Label("Open Document", systemImage: "folder")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut("o", modifiers: .command)

            if model.isProcessing {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Running Apple Vision OCR…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, Theme.Spacing.xs)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxl)
        .padding(.horizontal, Theme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                .fill(Theme.surface.opacity(isDropTargeted ? 0.9 : 0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Theme.accent : Theme.border,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: isDropTargeted ? [] : [8, 6])
                )
        )
        .shadow(color: isDropTargeted ? Theme.accent.opacity(0.3) : .clear, radius: 24, y: 8)
        .scaleEffect(isDropTargeted ? 1.01 : 1)
        .animation(Theme.Motion.snappy, value: isDropTargeted)
        .animation(Theme.Motion.smooth, value: model.isProcessing)
    }

    // MARK: - Recents

    private var recents: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                SectionLabel("Recent documents")
                Spacer()
            }
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(jobStore.recents.prefix(6)) { recent in
                    RecentDocumentCard(
                        document: recent,
                        onOpen: { model.openRecent(recent) },
                        onRemove: { jobStore.delete(id: recent.id) }
                    )
                }
            }
        }
    }
}

// MARK: - Recent document card

private struct RecentDocumentCard: View {
    let document: OCRDocument
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.md) {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(tileGradient)
                    .frame(width: 44, height: 52)
                    .overlay(
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(document.filename)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: Theme.Spacing.sm) {
                        Label("\(document.totalPageCount) pages", systemImage: "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                        if document.ocrPageCount > 0 {
                            Pill(
                                document.issueCount == 0 ? "All clear" : "\(document.issueCount) to review",
                                systemImage: document.issueCount == 0 ? "checkmark" : "exclamationmark",
                                color: document.issueCount == 0 ? Theme.success : Theme.warning
                            )
                        }
                    }
                }

                Spacer()

                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.dim)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from recents")
                    .transition(.opacity)
                }

                Text(document.createdAt, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.accent : Theme.dim)
            }
            .padding(Theme.Spacing.md)
            .panelBackground(fill: Theme.surfaceElevated.opacity(hovering ? 1 : 0.7),
                             stroke: hovering ? Theme.accent.opacity(0.4) : Theme.hairline)
        }
        .buttonStyle(.plain)
        .hoverLift()
        .onHover { hovering = $0 }
        .animation(Theme.Motion.snappy, value: hovering)
    }

    private var tileGradient: LinearGradient {
        let hue = Double(abs(document.filename.hashValue) % 360) / 360.0
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.5, brightness: 0.85),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.62),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: DocumentViewModel
    @ObservedObject var jobStore: JobStore
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if model.document != nil {
                ReviewWorkspaceView(model: model)
                    .transition(.opacity)
            } else {
                WelcomeView(model: model, jobStore: jobStore, isDropTargeted: isDropTargeted)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.gentle, value: model.document != nil)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay {
            if model.isCommandPaletteVisible {
                CommandPaletteView(model: model)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(Theme.Motion.snappy, value: model.isCommandPaletteVisible)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted.animation(Theme.Motion.snappy)) { providers in
            handleDrop(providers)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, DocumentLoader.isSupported(url) else { return }
            Task { @MainActor in
                await model.open(url: url)
            }
        }
        return true
    }
}
