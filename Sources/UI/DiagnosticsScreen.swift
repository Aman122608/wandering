import SwiftUI
import UIKit

struct DiagnosticsScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var log = DiagLog.shared

    @State private var probing = false
    @State private var probeResult: [String] = []
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.s4) {
                    ScreenTitle(title: "Connection",
                                subtitle: "The tunnel is provided by LocalDevVPN. Wandering only dials it.")

                    Panel {
                        VStack(alignment: .leading, spacing: Tokens.s2) {
                            HStack {
                                StatusChip(text: state.session.connection.label,
                                           tone: state.session.connection.isReady ? .live : .neutral)
                                Spacer()
                                if state.player.phase.isActive {
                                    StatusChip(text: state.player.phase.label, tone: .busy)
                                }
                            }
                            DetailRow(label: "endpoint", value: Transport.shared.dialedAddress ?? "—")
                            DetailRow(label: "developer mode",
                                      value: state.session.developerModeEnabled ? "on" : "off")
                            DetailRow(label: "disk image",
                                      value: state.session.diskImageMounted ? "mounted" : "not mounted")
                            DetailRow(label: "writes", value: "\(state.session.writeCount)")
                            if let last = state.session.lastWrite {
                                DetailRow(label: "last write",
                                          value: last.formatted(date: .omitted, time: .standard))
                            }
                        }
                    }

                    HStack(spacing: Tokens.s2) {
                        PrimaryButton(title: "Connect", systemImage: "link") {
                            Task { await state.session.connect() }
                        }
                        PrimaryButton(title: "Disconnect", systemImage: "xmark.circle",
                                      role: .neutral) {
                            state.session.disconnect()
                        }
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: Tokens.s2) {
                            SectionLabel(text: "Endpoint sweep")
                            Text("Probes port \(TunnelProbe.developerPort) on every candidate address.")
                                .font(Tokens.caption).foregroundStyle(Tokens.inkSecondary)
                            PrimaryButton(title: probing ? "Probing…" : "Run sweep",
                                          systemImage: "dot.radiowaves.left.and.right",
                                          role: .neutral, isEnabled: !probing) {
                                runSweep()
                            }
                            ForEach(probeResult, id: \.self) { line in
                                Text(line)
                                    .font(Tokens.mono(11))
                                    .foregroundStyle(Tokens.inkSecondary)
                            }
                        }
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: Tokens.s2) {
                            HStack {
                                SectionLabel(text: "Log")
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = log.copyBundle()
                                    copied = true
                                } label: {
                                    Label(copied ? "Copied" : "Copy", systemImage: "doc.on.doc")
                                        .font(Tokens.caption)
                                }
                                if let url = log.currentFile {
                                    ShareLink(item: url) {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(Tokens.caption)
                                    }
                                }
                            }
                            ForEach(log.lines.suffix(40).reversed(), id: \.self) { line in
                                Text(line)
                                    .font(Tokens.mono(10.5))
                                    .foregroundStyle(Tokens.inkSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(Tokens.s3)
                .padding(.bottom, Tokens.s6)
            }
            .background(Tokens.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func runSweep() {
        probing = true
        probeResult = []
        Task {
            let candidates = TunnelProbe.candidates()
            var lines: [String] = []
            for candidate in candidates.prefix(10) {
                let reachable = await Task.detached(priority: .userInitiated) {
                    TunnelProbe.canConnect(candidate, timeout: 0.6)
                }.value
                lines.append("\(reachable ? "open  " : "closed") \(candidate.address):\(candidate.port)"
                    + "  · \(candidate.origin)")
            }
            probeResult = lines
            probing = false
        }
    }
}
