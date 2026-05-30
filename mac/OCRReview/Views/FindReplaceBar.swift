import SwiftUI

struct FindReplaceBar: View {
    @ObservedObject var model: DocumentViewModel

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Find field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                TextField("Find in document", text: $model.findText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 180)
                    .onSubmit { model.findNext() }
                    .onChange(of: model.findText) { _, _ in model.refreshFindResults() }

                if !model.findText.isEmpty {
                    Text(matchLabel)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(model.findMatches.isEmpty ? Theme.warning : Theme.dim)
                        .fixedSize()
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 7)
            .panelBackground(radius: Theme.Radius.md, fill: Theme.bg, stroke: Theme.border)

            Button { model.findPrevious() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(ToolbarIconButtonStyle())
                .disabled(model.findMatches.isEmpty)
            Button { model.findNext() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(ToolbarIconButtonStyle())
                .disabled(model.findMatches.isEmpty)

            Rectangle().fill(Theme.border).frame(width: 1, height: 22).padding(.horizontal, 2)

            // Replace field
            HStack(spacing: 6) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                TextField("Replace with", text: $model.replaceText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 160)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 7)
            .panelBackground(radius: Theme.Radius.md, fill: Theme.bg, stroke: Theme.border)

            Button("Replace") { model.replaceCurrentMatch() }
                .buttonStyle(GhostButtonStyle())
                .disabled(model.findMatches.isEmpty)
            Button("All") { model.replaceAllMatches() }
                .buttonStyle(SoftButtonStyle())
                .disabled(model.findMatches.isEmpty)

            Spacer()

            Button { withAnimation(Theme.Motion.snappy) { model.isFindVisible = false } } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ToolbarIconButtonStyle())
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.surface)
    }

    private var matchLabel: String {
        if model.findMatches.isEmpty { return "No results" }
        return "\(model.currentFindMatchIndex + 1) / \(model.findMatches.count)"
    }
}
