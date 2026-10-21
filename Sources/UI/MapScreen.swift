import CoreLocation
import MapKit
import SwiftUI

struct MapScreen: View {
    @EnvironmentObject private var state: AppState
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var pendingPin: CLLocationCoordinate2D?
    @State private var pendingTitle: String = ""

    var body: some View {
        MapReader { proxy in
            Map(position: $state.camera, interactionModes: [.pan, .zoom]) {
                routeLayers
                waypointPins
                if let current = state.player.current {
                    Annotation("Simulated", coordinate: current) { liveMarker }
                }
                if let pin = pendingPin {
                    Annotation("", coordinate: pin) { pendingMarker }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .ignoresSafeArea(edges: .bottom)
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                pendingPin = coordinate
                Task {
                    pendingTitle = await state.describe(coordinate)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { controlPanel }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsScreen() }
        .sheet(isPresented: $showSettings) { SettingsScreen() }
        .alert("No Wi-Fi right now", isPresented: Binding(
            get: { state.cellularConsentNeeded },
            set: { if !$0 { state.cancelCellularStart() } }
        )) {
            Button("Use cellular mode") { state.confirmCellularStart() }
            Button("Cancel", role: .cancel) { state.cancelCellularStart() }
        } message: {
            Text("Wandering will run your cellular Shortcut, set the location, then "
                 + "turn the radios back on. About 10 seconds, and your connection "
                 + "drops briefly.")
        }
        .overlay(alignment: .top) { searchResultsOverlay }
        .overlay(alignment: .center) { pendingPinCard }
    }

    // MARK: - Map layers

    @MapContentBuilder
    private var routeLayers: some MapContent {
        if let route = state.selectedRoute {
            MapPolyline(coordinates: route.coordinates)
                .stroke(Tokens.accent.opacity(0.20),
                        style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: route.coordinates)
                .stroke(Tokens.accent,
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        }
        ForEach(state.routes.filter { $0.id != state.selectedRoute?.id }) { route in
            MapPolyline(coordinates: route.coordinates)
                .stroke(Tokens.inkSecondary.opacity(0.45),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round,
                                           dash: [7, 6]))
        }
    }

    @MapContentBuilder
    private var waypointPins: some MapContent {
        ForEach(Array(state.waypoints.enumerated()), id: \.element.id) { index, waypoint in
            Annotation("", coordinate: waypoint.coordinate) {
                Text(Self.letter(index))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(light: 0xFFF8F4, dark: 0x1A1310))
                    .frame(width: 28, height: 28)
                    .background(Tokens.accent, in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5) }
            }
        }
    }

    private var liveMarker: some View {
        ZStack {
            Circle().fill(Tokens.live.opacity(0.18)).frame(width: 46, height: 46)
            Circle().fill(Tokens.live).frame(width: 15, height: 15)
                .overlay { Circle().strokeBorder(.white, lineWidth: 2.5) }
        }
    }

    private var pendingMarker: some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 34))
            .foregroundStyle(Tokens.accent)
            .background(Circle().fill(.white).padding(6))
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack(spacing: Tokens.s2) {
            HStack(spacing: Tokens.s2) {
                HStack(spacing: Tokens.s2) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Tokens.inkSecondary)
                    TextField("Search an address or paste lat, lon", text: $state.searchQuery)
                        .font(Tokens.body(15))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .onChange(of: state.searchQuery) { _, query in
                            state.search(query, near: state.waypoints.last?.coordinate)
                        }
                        .submitLabel(.search)
                    if !state.searchQuery.isEmpty {
                        Button {
                            state.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Tokens.inkSecondary)
                        }
                    }
                }
                .padding(.horizontal, Tokens.s3)
                .frame(height: 46)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.rMedium,
                                                                 style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous)
                        .strokeBorder(Tokens.hairline, lineWidth: 1)
                }

                Button {
                    showDiagnostics = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(state.session.connection.isReady ? Tokens.live : Tokens.inkSecondary)
                        .frame(width: 46, height: 46)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.rMedium,
                                                                        style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous)
                                .strokeBorder(Tokens.hairline, lineWidth: 1)
                        }
                }
                .accessibilityLabel("Connection and diagnostics")
            }

            if !state.waypoints.isEmpty { waypointStrip }
        }
        .padding(.horizontal, Tokens.s3)
        .padding(.top, Tokens.s2)
        .padding(.bottom, Tokens.s2)
        .background(.ultraThinMaterial)
    }

    private var waypointStrip: some View {
        HStack(spacing: Tokens.s2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.s2) {
                    ForEach(Array(state.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                        HStack(spacing: 6) {
                            Text(Self.letter(index))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Tokens.accent)
                            Text(waypoint.title)
                                .font(Tokens.caption)
                                .lineLimit(1)
                            Button {
                                state.removeWaypoint(waypoint)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Tokens.inkSecondary)
                            }
                            .accessibilityLabel("Remove \(waypoint.title)")
                        }
                        .padding(.horizontal, Tokens.s2)
                        .padding(.vertical, 7)
                        .background(Tokens.surfaceRaised, in: Capsule())
                        .overlay { Capsule().strokeBorder(Tokens.hairline, lineWidth: 1) }
                    }
                }
            }
            if state.waypoints.count >= 2 {
                Button {
                    state.reversePlan()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.inkSecondary)
                        .frame(width: 34, height: 34)
                        .background(Tokens.surfaceRaised, in: Circle())
                }
                .accessibilityLabel("Reverse route")
            }
            Button {
                state.clearPlan()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.danger)
                    .frame(width: 34, height: 34)
                    .background(Tokens.surfaceRaised, in: Circle())
            }
            .accessibilityLabel("Clear waypoints")
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResultsOverlay: some View {
        if !state.searchResults.isEmpty {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(state.searchResults) { place in
                            Button {
                                state.addWaypoint(place)
                            } label: {
                                HStack(spacing: Tokens.s3) {
                                    Image(systemName: place.symbol)
                                        .foregroundStyle(Tokens.accent)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.title)
                                            .font(Tokens.body(15))
                                            .foregroundStyle(Tokens.ink)
                                            .lineLimit(1)
                                        if !place.subtitle.isEmpty {
                                            Text(place.subtitle)
                                                .font(Tokens.caption)
                                                .foregroundStyle(Tokens.inkSecondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(Tokens.inkSecondary)
                                }
                                .padding(.horizontal, Tokens.s3)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Tokens.hairline)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.rMedium,
                                                             style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous)
                    .strokeBorder(Tokens.hairline, lineWidth: 1)
            }
            .padding(.horizontal, Tokens.s3)
            .padding(.top, 108)
            .transition(.opacity)
        }
    }

    // MARK: - Pending pin

    @ViewBuilder
    private var pendingPinCard: some View {
        if let pin = pendingPin {
            Panel {
                VStack(alignment: .leading, spacing: Tokens.s3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dropped pin")
                            .font(Tokens.caption)
                            .foregroundStyle(Tokens.inkSecondary)
                        Text(pendingTitle.isEmpty ? Router.format(pin) : pendingTitle)
                            .font(Tokens.heading(16))
                            .foregroundStyle(Tokens.ink)
                            .lineLimit(2)
                        Text(Router.format(pin))
                            .font(Tokens.mono(11))
                            .foregroundStyle(Tokens.inkSecondary)
                    }
                    HStack(spacing: Tokens.s2) {
                        PrimaryButton(title: "Teleport", systemImage: "location.fill") {
                            state.teleport(to: pin)
                            pendingPin = nil
                        }
                        PrimaryButton(title: "Add stop", systemImage: "plus",
                                      role: .neutral) {
                            state.addWaypoint(coordinate: pin, title: pendingTitle)
                            pendingPin = nil
                        }
                    }
                    Button {
                        pendingPin = nil
                    } label: {
                        Text("Cancel")
                            .font(Tokens.caption)
                            .foregroundStyle(Tokens.inkSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, Tokens.s3)
            .frame(maxWidth: 420)
        }
    }

    // MARK: - Control panel

    private var controlPanel: some View {
        VStack(spacing: Tokens.s3) {
            if !state.routes.isEmpty { routeOptions }

            HStack(spacing: Tokens.s2) {
                ForEach(TravelPreset.allCases) { preset in
                    presetButton(preset)
                }
            }

            speedRow

            HStack(spacing: Tokens.s2) {
                PrimaryButton(
                    title: primaryTitle,
                    systemImage: primarySymbol,
                    isEnabled: canStart
                ) {
                    primaryAction()
                }
                Button {
                    state.stop(clear: true)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(state.isLive ? Tokens.danger : Tokens.inkSecondary)
                        .frame(width: 50, height: 50)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.rMedium,
                                                                        style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous)
                                .strokeBorder(Tokens.hairline, lineWidth: 1)
                        }
                }
                .disabled(!state.isLive)
                .accessibilityLabel("Stop and restore real GPS")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Tokens.inkSecondary)
                        .frame(width: 50, height: 50)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.rMedium,
                                                                        style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous)
                                .strokeBorder(Tokens.hairline, lineWidth: 1)
                        }
                }
                .accessibilityLabel("Settings")
            }

            HStack(spacing: Tokens.s2) {
                StatusChip(text: state.supervisor.health.label,
                           tone: supervisorTone)
                if !state.supervisor.note.isEmpty {
                    Text(state.supervisor.note)
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let error = state.player.lastError ?? state.planError {
                Text(error)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.danger)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Tokens.s3)
        .background(Tokens.canvas)
        .overlay(alignment: .top) { Divider().overlay(Tokens.hairline) }
    }

    private var supervisorTone: StatusChip.Tone {
        switch state.supervisor.health {
        case .streaming, .established: return .live
        case .repairing: return .busy
        case .lost: return .bad
        case .idle: return .neutral
        }
    }

    private var routeOptions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.s2) {
                ForEach(state.routes) { route in
                    let selected = route.id == state.selectedRoute?.id
                    Button {
                        state.selectedRouteID = route.id
                        state.fitCamera()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.duration(route.expectedTravelTime))
                                .font(Tokens.display(17))
                                .foregroundStyle(selected ? Tokens.accent : Tokens.ink)
                            Text("\(route.name) · \(String(format: "%.1f", route.distanceKm)) km")
                                .font(Tokens.caption)
                                .foregroundStyle(Tokens.inkSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Tokens.s3)
                        .padding(.vertical, 9)
                        .frame(minWidth: 132, alignment: .leading)
                        .background(selected ? Tokens.accent.opacity(0.10) : Tokens.surface,
                                    in: RoundedRectangle(cornerRadius: Tokens.rMedium,
                                                         style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous)
                                .strokeBorder(selected ? Tokens.accent.opacity(0.55) : Tokens.hairline,
                                              lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func presetButton(_ preset: TravelPreset) -> some View {
        let selected = state.preset == preset
        return Button {
            state.preset = preset
            state.maxSpeedKmh = Geo.clamp(state.maxSpeedKmh, preset.speedRange.lowerBound,
                                          preset.speedRange.upperBound)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(preset.title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(selected ? Color(light: 0xFFF8F4, dark: 0x1A1310) : Tokens.inkSecondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? Tokens.accent : Tokens.surface,
                        in: RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous))
            .overlay {
                if !selected {
                    RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous)
                        .strokeBorder(Tokens.hairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var speedRow: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Max speed")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.inkSecondary)
                Spacer()
                Text("\(Int(state.maxSpeedKmh)) km/h")
                    .font(Tokens.display(19))
                    .foregroundStyle(Tokens.ink)
                    .monospacedDigit()
                if state.isLive {
                    Text("· \(Int(state.player.speedKmh)) now")
                        .font(Tokens.mono(11))
                        .foregroundStyle(Tokens.live)
                        .monospacedDigit()
                }
            }
            Slider(value: $state.maxSpeedKmh,
                   in: state.preset.speedRange,
                   step: 1)
                .tint(Tokens.accent)
        }
    }

    private var primaryTitle: String {
        switch state.player.phase {
        case .playing: return "Pause"
        case .paused: return "Resume"
        case .holding: return "Pause"
        default: return state.routes.isEmpty ? "Connect" : "Move"
        }
    }

    private var primarySymbol: String {
        switch state.player.phase {
        case .playing, .holding: return "pause.fill"
        case .paused: return "play.fill"
        default: return state.routes.isEmpty ? "bolt.horizontal.fill" : "play.fill"
        }
    }

    private var canStart: Bool {
        if state.player.phase == .playing || state.player.phase == .holding
            || state.player.phase == .paused { return true }
        return state.selectedRoute != nil
    }

    private func primaryAction() {
        switch state.player.phase {
        case .playing, .holding:
            state.player.pause()
        case .paused:
            state.player.resume()
        default:
            guard state.selectedRoute != nil else {
                Task { await state.session.connect() }
                return
            }
            state.startSelectedRoute()
        }
    }

    // MARK: - Formatting

    static func letter(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < letters.count ? String(letters[index]) : "\(index + 1)"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60)"
    }
}
