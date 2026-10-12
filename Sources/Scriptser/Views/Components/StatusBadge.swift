import SwiftUI

/// Visual status indicator badge
struct StatusBadge: View {
    @Environment(\.locale) private var locale
    let status: RunStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
            Text(L10n.text(status.localizationKey, language: AppLanguage(rawValue: locale.identifier) ?? .current))
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        StatusBadge(status: .idle)
        StatusBadge(status: .running)
        StatusBadge(status: .success)
        StatusBadge(status: .failed)
        StatusBadge(status: .stopped)
    }
    .padding()
}
