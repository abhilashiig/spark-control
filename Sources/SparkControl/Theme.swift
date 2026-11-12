import SwiftUI
import AppKit

// MARK: Palette

extension Color {
    init(light: UInt32, dark: UInt32) {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? ns(dark) : ns(light) })
    }

    /// The iPhone app's accent.
    static let brand = Color(light: 0x4F5BD5, dark: 0x7E8AF4)
    /// The app icon's spark.
    static let spark = Color(light: 0xF29A2E, dark: 0xFFB04D)
    /// The app icon's dial background.
    static let sparkNavy = Color(light: 0x24307A, dark: 0x2E3B8F)
    static let pageBackground = Color(light: 0xF2F2F7, dark: 0x161618)
    static let cardBackground = Color(light: 0xFFFFFF, dark: 0x232326)
    static let cardBorder = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.07)
}

/// The validated categorical slots (light and dark steps), in fixed order, and the reserved status colours.
enum VizColor {
    static let series = [Color(light: 0x2a78d6, dark: 0x3987e5), Color(light: 0xeb6834, dark: 0xd95926),
                         Color(light: 0x1baf7a, dark: 0x199e70), Color(light: 0xeda100, dark: 0xc98500),
                         Color(light: 0xe87ba4, dark: 0xd55181)]
    static let good = Color(light: 0x0ca30c, dark: 0x0ca30c)
    static let warning = Color(light: 0xfab219, dark: 0xfab219)
    static let critical = Color(light: 0xd03b3b, dark: 0xd03b3b)
}

// MARK: Pages and cards

extension View {
    /// A grouped Form on the soft page background, so its sections read as cards.
    func page() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden).background(Color.pageBackground)
    }

    func card(padding: CGFloat = 16, radius: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.cardBorder))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline) }
            content
        }
        .card()
    }
}

// MARK: Status

extension Phase {
    var color: Color {
        switch self {
        case .ready: .green
        case .starting, .stopping: .orange
        case .failed, .offline: .red
        case .stopped: Color.secondary.opacity(0.4)
        }
    }
}

struct StatusDot: View {
    let phase: Phase
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(phase.color).frame(width: size, height: size)
            .overlay {
                if phase.busy {
                    Circle().stroke(phase.color.opacity(0.5), lineWidth: 2).scaleEffect(1.8)
                        .phaseAnimator([0.3, 1]) { v, p in v.opacity(p) }
                }
            }
            .accessibilityLabel(phase.label)
    }
}

/// A model's avatar: its initials on a colour picked from its name, with a status dot like a presence badge.
struct ModelAvatar: View {
    let name: String
    var phase: Phase?
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint, tint.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Text(initials).font(.system(size: size * 0.38, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                if let phase {
                    StatusDot(phase: phase, size: max(6, size * 0.28))
                        .padding(2)
                        .background(Circle().fill(Color.cardBackground))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let s = words.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    static let palette: [Color] = [.indigo, .purple, .pink, .orange, .teal, .blue, .mint, .cyan, Color.sparkNavy, .brown]
    private var tint: Color {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return Self.palette[sum % Self.palette.count]
    }
}

struct UserAvatar: View {
    var size: CGFloat = 28
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color.spark.gradient)
            .frame(width: size, height: size)
            .overlay { Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.white) }
            .accessibilityHidden(true)
    }
}

/// A symbol on a gradient rounded square, as in iOS Settings rows.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The app's bolt on the icon's navy, for headers.
struct BoltTile: View {
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Color.spark.gradient)
            .frame(width: size, height: size)
            .background(Color.sparkNavy.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct EngineBadge: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Self.color(name).opacity(0.15), in: Capsule())
            .foregroundStyle(Self.color(name))
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "TensorFold": .indigo
        case "vLLM": .teal
        case "Ollama": .brown
        case "ComfyUI": .pink
        default: .gray
        }
    }
}

/// A warning shown at the top of a page until dismissed (e.g. a model stopped to make room for another).
struct NoticeBanner: View {
    @Environment(AppState.self) private var state
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VizColor.warning)
            Text(text)
            Spacer(minLength: 0)
            Button { state.notice = nil } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(12)
        .background(VizColor.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(VizColor.warning.opacity(0.4)))
    }
}
