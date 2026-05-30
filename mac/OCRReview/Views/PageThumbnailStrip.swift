import PDFKit
import SwiftUI

struct PageThumbnailStrip: View {
    let totalPages: Int
    @Binding var currentPageIndex: Int
    let document: PDFDocument?
    var ocrPageNumbers: Set<Int> = []
    var issuePageNumbers: Set<Int> = []
    var onMovePage: ((Int, Int) -> Void)?
    var onRotatePage: ((Int, Bool) -> Void)?
    var onDeletePage: ((Int) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                SectionLabel("Pages")
                Text("\(totalPages)")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text("Drag to reorder · right-click for tools")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.sm)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.md) {
                        ForEach(0..<totalPages, id: \.self) { index in
                            thumbnailButton(for: index)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                }
                .onChange(of: currentPageIndex) { _, newIndex in
                    withAnimation(Theme.Motion.snappy) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onAppear {
                    proxy.scrollTo(currentPageIndex, anchor: .center)
                }
            }
        }
        .background(Theme.surface)
    }

    @ViewBuilder
    private func thumbnailButton(for index: Int) -> some View {
        let isCurrent = index == currentPageIndex
        Button {
            withAnimation(Theme.Motion.snappy) { currentPageIndex = index }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    thumbnail(for: index)
                        .frame(width: 62, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .strokeBorder(isCurrent ? Theme.accent : Theme.border, lineWidth: isCurrent ? 2 : 1)
                        )
                        .shadow(color: isCurrent ? Theme.accent.opacity(0.5) : .black.opacity(0.25),
                                radius: isCurrent ? 10 : 4, y: 3)

                    statusDot(for: index)
                        .padding(5)
                }

                Text("\(index + 1)")
                    .font(.system(size: 11, weight: isCurrent ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isCurrent ? Theme.accentBright : Theme.dim)
            }
        }
        .buttonStyle(.plain)
        .hoverLift(1.05)
        .draggable(String(index))
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first.flatMap(Int.init), from != index else { return false }
            onMovePage?(from, index)
            return true
        }
        .contextMenu {
            Button { onRotatePage?(index, true) } label: { Label("Rotate Right", systemImage: "rotate.right") }
            Button { onRotatePage?(index, false) } label: { Label("Rotate Left", systemImage: "rotate.left") }
            Divider()
            Button(role: .destructive) { onDeletePage?(index) } label: { Label("Delete Page…", systemImage: "trash") }
                .disabled(totalPages <= 1)
        }
    }

    @ViewBuilder
    private func statusDot(for index: Int) -> some View {
        let pageNumber = index + 1
        if ocrPageNumbers.contains(pageNumber) {
            Circle()
                .fill(issuePageNumbers.contains(pageNumber) ? Theme.warning : Theme.success)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.5))
        }
    }

    @ViewBuilder
    private func thumbnail(for index: Int) -> some View {
        if let document, let page = document.page(at: index) {
            PDFThumbnailView(page: page)
        } else {
            Rectangle().fill(Theme.surfaceElevated)
        }
    }
}

private struct PDFThumbnailView: View {
    let page: PDFPage
    var width: CGFloat = 124

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Theme.border.opacity(0.25))
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: thumbKey) {
            if let hit = ThumbnailCache.shared.cached(for: page, width: width) {
                image = hit
            } else {
                image = await ThumbnailCache.shared.thumbnail(for: page, width: width)
            }
        }
    }

    private var thumbKey: String {
        "\(UInt(bitPattern: ObjectIdentifier(page).hashValue))-\(page.rotation)-\(Int(width))"
    }
}
