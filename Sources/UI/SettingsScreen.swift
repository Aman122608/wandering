import SwiftUI
import UniformTypeIdentifiers

struct SettingsScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("holdAtEnd") private var holdAtEnd = true
    @AppStorage("airplaneInit") private var airplaneInit = false
    @AppStorage("airplaneShortcutStyle") private var airplaneShortcutStyle = "singleSwitch"
    @AppStorage("airplaneShortcutOn") private var airplaneShortcutOn = "Wander Cellular Mode"
    @AppStorage("airplaneShortcutOff") private var airplaneShortcutOff = "Airplane Off"

    @State private var importingPairing = false
    @StateObject private var pairHost = PairHostBroker.shared

    private func pairingRow(_ entry: PairingStore.Entry) -> some View {
        let active = state.session.pairingFileURL?.lastPathComponent == entry.name
        return Button {
            state.session.selectPairing(entry)
        } label: {
            HStack(spacing: Tokens.s2) {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(active ? Tokens.accent : Tokens.inkSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(Tokens.mono(12))
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.subtitle)
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.inkSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    state.session.removePairing(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.inkSecondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shortcutField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).font(Tokens.caption)
                .foregroundStyle(Tokens.inkSecondary)
            Spacer()
            TextField("Shortcut", text: text)
                .font(Tokens.mono(12))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
        }
    }

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
                            Toggle(isOn: $state.useRoadSpeeds) {
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
                            SectionLabel(text: "Sharing apps")
                            Toggle(isOn: $state.sharingMode) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Life360 / Find My mode").font(Tokens.body(15))
                                    Text("Forces GPS noise and micro-pauses on and never reports a perfect fix.")
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
                                Picker("Shortcut style", selection: $airplaneShortcutStyle) {
                                    Text("One Shortcut").tag("singleSwitch")
                                    Text("Two Shortcuts").tag("twoShortcuts")
                                }
                                .pickerStyle(.segmented)
                                if airplaneShortcutStyle == "singleSwitch" {
                                    shortcutField("Shortcut name", text: $airplaneShortcutOn)
                                    Text("Run with input text on/off — the same shape the paid app ships.")
                                        .font(Tokens.caption)
                                        .foregroundStyle(Tokens.inkSecondary)
                                } else {
                                    shortcutField("Turns it on", text: $airplaneShortcutOn)
                                    shortcutField("Turns it off", text: $airplaneShortcutOff)
                                }
                                PrimaryButton(title: "Run the sequence",
                                              systemImage: "airplane",
                                              role: .neutral,
                                              isEnabled: !state.airplane.phase.isRunning) {
                                    state.runCellularSequence()
                                }
                            }
                        }
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: Tokens.s3) {
                            SectionLabel(text: "Follow me")
                            Text("Replays the road you actually drive, but never reports "
                                 + "faster than the cap — so you fall behind at speed and "
                                 + "close the gap when you slow down or stop.")
                                .font(Tokens.caption)
                                .foregroundStyle(Tokens.inkSecondary)

                            HStack {
                                Text("Top speed").font(Tokens.body(15))
                                Spacer()
                                Text("\(Int(state.chaser.capMph)) mph")
                                    .font(Tokens.display(18))
                                    .monospacedDigit()
                            }
                            Slider(value: Binding(
                                get: { state.chaser.capMph },
                                set: { state.chaser.capMph = $0.rounded() }
                            ), in: 5...85, step: 1)
                                .tint(Tokens.accent)

                            HStack(spacing: Tokens.s4) {
                                readout("Reported",
                                        String(format: "%.0f",
                                               state.chaser.reportedSpeedKmh / 1.609344) + " mph")
                                readout("Behind by",
                                        String(format: "%.0f", state.chaser.gapMeters) + " m")
                            }

                            PrimaryButton(title: state.chaser.isRunning ? "Stop chase" : "Start chase",
                                          systemImage: state.chaser.isRunning
                                            ? "stop.circle" : "figure.walk.motion",
                                          role: state.chaser.isRunning ? .destructive : .primary) {
                                if state.chaser.isRunning {
                                    state.stopChase()
                                } else {
                                    state.startChase()
                                }
                            }
                            Text(state.chaser.status)
                                .font(Tokens.caption)
                                .foregroundStyle(state.chaser.isRunning ? Tokens.accent
                                                 : Tokens.inkSecondary)
                        }
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: Tokens.s3) {
                            SectionLabel(text: "Playback")
                            HStack {
                                Text("Speed").font(Tokens.body(15))
                                Spacer()
                                Text("\(state.playbackRate, specifier: "%.1f")×")
                                    .font(Tokens.display(18))
                            }
                            Slider(value: $state.playbackRate, in: 0.5...4, step: 0.5)
                                .tint(Tokens.accent)
                        }
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: Tokens.s3) {
                            SectionLabel(text: "Connection")
                            VStack(alignment: .leading, spacing: Tokens.s2) {
                                Text("Tunnel lifetime").font(Tokens.body(15))
                                Text("On this iOS build the simulated location lives inside "
                                     + "the developer session: closing the tunnel reverts it. "
                                     + "Keep it open while a spoof is running.")
                                    .font(Tokens.caption).foregroundStyle(Tokens.inkSecondary)
                                Picker("Tunnel lifetime", selection: Binding(
                                    get: { state.session.lifetime },
                                    set: { state.session.lifetime = $0 }
                                )) {
                                    ForEach(TunnelLifetime.allCases) { option in
                                        Text(option.title).tag(option)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            Button {
                                importingPairing = true
                            } label: {
                                Label("Import pairing files", systemImage: "doc.badge.plus")
                                    .font(Tokens.body(15))
                            }

                            if state.session.pairingEntries.isEmpty {
                                Text("Pick one of your saved pairing files, or drop them into "
                                     + "Files → On My iPhone → Wandering and reopen.")
                                    .font(Tokens.caption)
                                    .foregroundStyle(Tokens.inkSecondary)
                            } else {
                                ForEach(state.session.pairingEntries) { entry in
                                    pairingRow(entry)
                                }
                            }
                            Button {
                                Task { await state.session.connect() }
                            } label: {
                                Label("Connect to the tunnel", systemImage: "antenna.radiowaves.left.and.right")
                                    .font(Tokens.body(15))
                            }
                            Button {
                                pairHost.onPaired = { _ in
                                    Task { await state.session.connect() }
                                }
                                pairHost.start()
                            } label: {
                                Label("Pair with this iPhone", systemImage: "iphone.and.arrow.forward")
                                    .font(Tokens.body(15))
                            }
                            Button {
                                Task { await state.session.pairFromScratch() }
                            } label: {
                                Label("Pair from scratch (legacy)", systemImage: "key.horizontal")
                                    .font(Tokens.body(15))
                            }
                            Text("Discards the current pairing record, makes a new one and "
                                 + "pairs with this iPhone. Use it when connecting resets "
                                 + "the connection immediately.")
                                .font(Tokens.caption)
                                .foregroundStyle(Tokens.inkSecondary)
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
            .onReceive(state.airplane.objectWillChange) { _ in }
            .sheet(isPresented: Binding(
                get: { pairHost.isPairing || pairHost.message != nil },
                set: { if !$0 { pairHost.dismiss() } }
            )) { pairHostSheet }
            .sheet(isPresented: $importingPairing) {
                DocumentPicker { urls in
                    importingPairing = false
                    state.session.importPairingFiles(urls)
                }
                .ignoresSafeArea()
            }
            .alert("Import failed", isPresented: Binding(
                get: { state.session.importError != nil },
                set: { if !$0 { state.session.importError = nil } }
            )) {
                Button("OK", role: .cancel) { state.session.importError = nil }
            } message: {
                Text(state.session.importError ?? "")
            }
            .onAppear { state.session.refreshPairings() }
        }
    }

    private var pairHostSheet: some View {
        VStack(alignment: .leading, spacing: Tokens.s4) {
            Text("Pair with your iPhone").font(Tokens.heading(20))
            VStack(alignment: .leading, spacing: Tokens.s2) {
                Text("1. Turn on Wi-Fi.").font(Tokens.body(15))
                Text("2. Settings → Privacy & Security → Developer Mode → "
                     + "\"Pair with Wandering\".").font(Tokens.body(15))
                Text("3. Type the code below on the iPhone.").font(Tokens.body(15))
            }
            .foregroundStyle(Tokens.inkSecondary)

            if let code = pairHost.code {
                Text(code)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.accent)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if pairHost.isPairing {
                ProgressView().frame(maxWidth: .infinity)
            }

            if let message = pairHost.message {
                Text(message)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.inkSecondary)
            }
            Spacer(minLength: 0)
            PrimaryButton(title: "Close", role: .neutral) { pairHost.dismiss() }
        }
        .padding(Tokens.s4)
        .presentationDetents([.height(380)])
        .background(Tokens.canvas)
    }

    private func readout(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(Tokens.caption)
                .foregroundStyle(Tokens.inkSecondary)
            Text(value).font(Tokens.display(18))
        }
    }
}
