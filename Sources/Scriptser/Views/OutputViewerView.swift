import SwiftUI
import AppKit
import Combine

/// View for displaying and managing script output
struct OutputViewerView: View {
    @EnvironmentObject private var store: ScriptStore
    let script: ScriptEntry
    @State private var output: String = ""
    @State private var isLoading = false
    @State private var autoScroll = true
    @Environment(\.dismiss) private var dismiss

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            headerView

            // Output area
            outputScrollView

            // Footer
            footerView
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await loadOutput()
        }
        .onReceive(timer) { _ in
            Task { await loadOutput() }
        }
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(L10n.format("Output: %@", script.name.isEmpty ? L10n.text("Untitled Script") : script.name))
                    .font(.headline)

                let state = store.status(for: script)
                HStack(spacing: 8) {
                    StatusBadge(status: state.status)
                    if let duration = state.formattedDuration {
                        Text(L10n.format("Duration: %@", duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Toggle(L10n.text("Auto-scroll"), isOn: $autoScroll)
                .toggleStyle(.checkbox)

            Button {
                Task {
                    await loadOutput()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
            .help(L10n.text("Refresh output")).accessibilityLabel(L10n.text("Refresh output"))

            Button {
                Task {
                    await store.clearOutput(for: script)
                    output = ""
                }
            } label: {
                Image(systemName: "trash")
            }
            .help(L10n.text("Clear output")).accessibilityLabel(L10n.text("Clear output"))
        }
    }

    private var outputScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(output.isEmpty ? L10n.text("No output yet...") : output)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                    Color.clear.frame(height: 1).id("output-bottom")
                }
            }
            .onChange(of: output) { newValue in
                if autoScroll {
                    withAnimation {
                        proxy.scrollTo("output-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private var footerView: some View {
        HStack {
            Text(L10n.format("%d characters", output.count))
                .font(.caption)
                .foregroundColor(.secondary)

            if store.isRunning(script) {
                ProgressView()
                    .scaleEffect(0.5)
                Text(L10n.text("Live"))
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Spacer()

            Button(L10n.text("Copy All")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
            }
            .disabled(output.isEmpty)

            Button(L10n.text("Close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private func loadOutput() async {
        isLoading = true
        output = await store.getOutput(for: script)
        isLoading = false
    }
}
