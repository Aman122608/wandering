import SwiftUI

/// Flat surface with a hairline border. No left-accent stripes, no drop shadows.
struct Panel<Content: View>: View {
    var padding: CGFloat = Tokens.s3
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous)
                    .strokeBorder(Tokens.hairline, lineWidth: 1)
            }
    }
}

/// Screen title with an optional trailing detail. Serif display, tight leading.
struct ScreenTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.s1) {
            Text(title)
                .font(Tokens.display(30))
                .foregroundStyle(Tokens.ink)
            if let subtitle {
                Text(subtitle)
                    .font(Tokens.body(14))
                    .foregroundStyle(Tokens.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Tokens.inkSecondary)
    }
}

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var role: Role = .primary
    var isEnabled: Bool = true
    let action: () -> Void

    enum Role { case primary, neutral, destructive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.s2) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(Tokens.heading(16))
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous))
            .overlay {
                if role == .neutral {
                    RoundedRectangle(cornerRadius: Tokens.rMedium, style: .continuous)
                        .strokeBorder(Tokens.hairline, lineWidth: 1)
                }
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var foreground: Color {
        switch role {
        case .primary: return Color(light: 0xFFF8F4, dark: 0x1A1310)
        case .neutral: return Tokens.ink
        case .destructive: return Tokens.danger
        }
    }

    private var background: Color {
        switch role {
        case .primary: return Tokens.accent
        case .neutral: return Tokens.surface
        case .destructive: return Tokens.surface
        }
    }
}

/// Small state chip: "Live", "Idle", "Connecting".
struct StatusChip: View {
    let text: String
    var tone: Tone = .neutral

    enum Tone { case neutral, live, busy, bad }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(text)
                .font(Tokens.caption)
                .foregroundStyle(Tokens.inkSecondary)
        }
        .padding(.horizontal, Tokens.s2)
        .padding(.vertical, 5)
        .background(Tokens.surfaceRaised, in: Capsule())
        .overlay { Capsule().strokeBorder(Tokens.hairline, lineWidth: 1) }
    }

    private var dotColor: Color {
        switch tone {
        case .neutral: return Tokens.inkSecondary
        case .live: return Tokens.live
        case .busy: return Tokens.accent
        case .bad: return Tokens.danger
        }
    }
}

/// Key/value row used in the diagnostics and connection panels.
struct DetailRow: View {
    let label: String
    let value: String
    var mono: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.s2) {
            Text(label)
                .font(Tokens.caption)
                .foregroundStyle(Tokens.inkSecondary)
            Spacer(minLength: Tokens.s2)
            Text(value)
                .font(mono ? Tokens.mono(12) : Tokens.body(13))
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.trailing)
        }
    }
}
