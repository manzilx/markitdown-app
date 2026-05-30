import SwiftUI

struct SpellSuggestionsView: View {
    let refs: [DocumentViewModel.SpellIssueRef]
    var onApply: (DocumentViewModel.SpellIssueRef, String) -> Void

    var body: some View {
        if refs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.info)
                    Text("Spelling suggestions")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.info)
                }

                ForEach(refs) { ref in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text(ref.issue.word)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                            .strikethrough(color: Theme.danger.opacity(0.6))
                            .fixedSize()

                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.dim)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(ref.issue.suggestions, id: \.self) { suggestion in
                                    Button {
                                        onApply(ref, suggestion)
                                    } label: {
                                        Text(suggestion)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.info)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(Capsule(style: .continuous).fill(Theme.info.opacity(0.14)))
                                            .overlay(Capsule(style: .continuous).strokeBorder(Theme.info.opacity(0.4), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.md)
            .panelBackground(radius: Theme.Radius.md, fill: Theme.surface, stroke: Theme.info.opacity(0.22))
        }
    }
}
