import SwiftUI
import UniformTypeIdentifiers

struct SettingsScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("holdAtEnd") private var holdAtEnd = true
    @AppStorage("useRoadSpeeds") private var useRoadSpeeds = true
    @AppStorage("airplaneInit") private var airplaneInit = false
    @AppStorage("airplaneShortcut") private var airplaneShortcut = "Wandering Airplane"
    @AppStorage("playbackRate") private var playbackRate = 1.0

    @State private var importingPairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.s4) {
                    ScreenTitle(title: "Settings",
                                subtitle: "Everything runs on your phone. Nothing is sent anywhere.")

                    Panel {
                        VStack(alignment: .leading, spacing: Tokens.s3) {
                            SectionLabel(text: "Keeping the session alive")
                            Toggle(isOn: $keepAliveAudio) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Silent audio").font(Tokens.body(15))
                                    Text("Plays an inaudible looping buffer so iOS keeps the app running.")
                                        .font(Tokens.caption).foregroundStyle(Tokens.inkSecondary)
                                }
                            }
                            Toggle(isOn: $keepAliveLocation) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Background location").font(Tokens.body(15))
                                    Text("Coarse updates, used only to stay awake — it never feeds the spoof.")
                                        .font(Tokens.caption).foregroundStyle(Tokens.inkSecondary)
                                }
                            }
                            Toggle(isOn: $holdAtEnd) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Hold at the end").font(Tokens.body(15))
                                    Text("Keep re-asserting the last point instead of stopping there.")
                                        .font(Tokens.caption).foregroundStyle(Tokens.inkSecondary)
                                }
                            }
                            Toggle(isOn: $useRoadSpeeds) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Follow road speeds").font(Tokens.body(15))
                                    Text("Pace driving and car presets from the route's per-street speeds.")
                                        .font(Tokens.caption).foregroundStyle(Tokens.inkSecondary)
                                }
                            }
                        }
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: Tokens.s3) {
                            SectionLabel(text: "Without Wi-Fi")
                            Toggle(isOn: $airplaneInit) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Airplane-mode start").font(Tokens.body(15))
                                    Text("Runs your Shortcut: airplane on → connect → move → airplane off.")
                                        .font(Tokens.caption).foregroundStyle(Tokens.inkSecondary)
                                }
                            }
                            if airplaneInit {
                                HStack {
                                    Text("Shortcut name").font(Tokens.caption)
                                        .foregroundStyle(Tokens.inkSecondary)
                                    Spacer()
                                    TextField("Shortcut", text: $airplaneShortcut)
                                        .font(Tokens.mono(12))
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: Tokens.s3) {
                            SectionLabel(text: "Playback")
                            HStack {
                                Text("Speed").font(Tokens.body(15))
                                Spacer()
                                Text("\(playbackRate, specifier: "%.1f")×")
                                    .font(Tokens.display(18))
                            }
                            Slider(value: $playbackRate, in: 0.5...4, step: 0.5)
                                .tint(Tokens.accent)
                        }
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: Tokens.s3) {
                            SectionLabel(text: "Connection")
                            Button {
                                importingPairing = true
                            } label: {
                                Label(state.session.pairingFileURL == nil
                                      ? "Import pairing file"
                                      : "Replace pairing file",
                                      systemImage: "doc.badge.plus")
                                    .font(Tokens.body(15))
                            }
                            if let url = state.session.pairingFileURL {
                                DetailRow(label: "on device", value: url.lastPathComponent)
                            }
                            Button {
                                Task { await state.session.connect() }
                            } label: {
                                Label("Connect to the tunnel", systemImage: "antenna.radiowaves.left.and.right")
                                    .font(Tokens.body(15))
                            }
                            Button(role: .destructive) {
                                state.stop(clear: true)
                            } label: {
                                Label("Restore real GPS", systemImage: "location.slash")
                                    .font(Tokens.body(15))
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
            .fileImporter(isPresented: $importingPairing,
                          allowedContentTypes: [.propertyList, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    state.session.importPairingFile(url)
                }
            }
        }
    }
}
