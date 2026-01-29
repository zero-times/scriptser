import SwiftUI
import AppKit

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
            if store.isRunning(script) {
                Task {
                    await loadOutput()
                }
            }
        }
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Output: \(script.name.isEmpty ? "Untitled Script" : script.name)")
                    .font(.headline)

                let state = store.status(for: script)
                HStack(spacing: 8) {
                    StatusBadge(status: state.status)
                    if let duration = state.formattedDuration {
                        Text("Duration: \(duration)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)

            Button {
                Task {
                    await loadOutput()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
            .help("Refresh output")

            Button {
                Task {
                    await store.clearOutput(for: script)
                    output = ""
                }
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear output")
        }
    }

    private var outputScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(output.isEmpty ? "No output yet..." : output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .id("output-bottom")
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
            Text("\(output.count) characters")
                .font(.caption)
                .foregroundColor(.secondary)

            if store.isRunning(script) {
                ProgressView()
                    .scaleEffect(0.5)
                Text("Live")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Spacer()

            Button("Copy All") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
            }
            .disabled(output.isEmpty)

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.escape)
        }
    }

    private func loadOutput() async {
        isLoading = true
        output = await store.getOutput(for: script)
        isLoading = false
    }
}
