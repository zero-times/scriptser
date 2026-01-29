import SwiftUI

/// Visual status indicator badge
struct StatusBadge: View {
    let status: RunStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
            Text(status.label)
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
