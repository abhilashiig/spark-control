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

    static let brand = Color(light: 0x0A66D8, dark: 0x3B8EEA)
    /// The app icon's spark.
    static let spark = Color(light: 0xF29A2E, dark: 0xFFB04D)
    /// The app icon's dial background.
    static let sparkNavy = Color(light: 0x24307A, dark: 0x2E3B8F)
    static let pageBackground = Color(light: 0xFFFFFF, dark: 0x1E1E20)
    static let cardBackground = Color(light: 0xFFFFFF, dark: 0x252527)
    static let cardBorder = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.08)
    static let sidebar = Color(light: 0xF3F3F5, dark: 0x262628)
    /// Model tiles, tracks and wells.
    static let well = Color(light: 0xF2F2F4, dark: 0x2C2C2F)
    /// The dark square engine icons sit on, and the memory in use.
    static let ink = Color(light: 0x1D1D1F, dark: 0x3A3A3D)
    static let text = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let text2 = Color(light: 0x6E6E73, dark: 0x98989D)
    /// Body copy one step down from `text`, and icon buttons.
    static let text3 = Color(light: 0x5E5E63, dark: 0xA1A1A6)
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.08)
    static let running = Color(light: 0x28A745, dark: 0x32C25A)
    static let danger = Color(light: 0xC4302B, dark: 0xFF5A52)
    /// The segmented control's selected thumb.
    static let thumb = Color(light: 0xFFFFFF, dark: 0x5B5B5F)

    /// Hover, selection and track fills: black over light backgrounds, a stronger white over dark ones.
    static func overlay(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor.white.withAlphaComponent(opacity * 1.6) : NSColor.black.withAlphaComponent(opacity)
        })
    }
}

/// The app's light or dark look: the system's by default, or fixed in Settings → General.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    var id: Self { self }
    var label: String { rawValue.capitalized }

    static func apply(_ raw: String) {
        NSApp.appearance = switch Appearance(rawValue: raw) ?? .system {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension View {
    /// Keeps the app's appearance in step with the setting while this view is on screen.
    func appliesAppearance() -> some View { modifier(AppliesAppearance()) }
}

private struct AppliesAppearance: ViewModifier {
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    func body(content: Content) -> some View {
        content.onChange(of: appearance, initial: true) { Appearance.apply(appearance) }
    }
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

/// A model's tile: its size ("27B") or version ("3.8") on a neutral square, with a status dot unless it's stopped.
struct ModelAvatar: View {
    let name: String
    var phase: Phase?
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * (size < 40 ? 0.263 : 0.25), style: .continuous)
            .fill(Color.well)
            .frame(width: size, height: size)
            .overlay {
                Text(Self.tag(name))
                    .font(.system(size: size < 30 ? size * 0.36 : size < 40 ? 11.5 : size < 52 ? 12.5 : 15, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.text3)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
            .overlay(alignment: .bottomTrailing) {
                if let phase, phase != .stopped {
                    Circle().fill(phase == .ready ? Color.running : phase.color)
                        .frame(width: 6, height: 6)
                        .padding(2)
                        .background(Circle().fill(Color.pageBackground))
                        .offset(x: 2, y: 2)
                        .phaseAnimator(phase.busy ? [0.35, 1] : [1]) { v, o in v.opacity(o) }
                }
            }
            .accessibilityHidden(true)
    }

    /// "Qwen3.6 35B-A3B" → "35B", "Qwen3.8 Flash" → "3.8", "Gemma" → "G".
    static func tag(_ name: String) -> String {
        if let m = name.firstMatch(of: #/(?i)\b(\d+(?:\.\d+)?)b\b/#) { return m.1 + "B" }
        if let m = name.firstMatch(of: #/\d+(?:\.\d+)?/#) { return String(m.0) }
        let s = name.split(whereSeparator: { !$0.isLetter }).prefix(2).compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

/// Small: a plain line symbol in its tint, as in the sidebar. Large (32+): white on a dark square, for page headers.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22
    var body: some View {
        Group {
            if size >= 32 {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.ink, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.68, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The app's bolt on the icon's navy, for headers.
struct BoltTile: View {
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.ink, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
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

// MARK: Page chrome

/// A page's 52pt title bar: title left, controls right, hairline below. Drags the window, which has no title bar.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.text).lineLimit(1)
            Spacer(minLength: 0)
            trailing
                .labelStyle(.iconOnly)
                .buttonStyle(GhostIconStyle())
                .menuStyle(.button)
                .menuIndicator(.hidden)
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .background { Color.pageBackground.gesture(WindowDragGesture()) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }
}

extension View {
    /// Puts the page under a `PageHeader`, in place of a navigation title and toolbar.
    func pageHeader<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        VStack(spacing: 0) {
            PageHeader(title: title, trailing: trailing)
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func pageHeader(_ title: String) -> some View { pageHeader(title) { EmptyView() } }

    /// A rounded fill that shows while the pointer is over the view.
    func hoverFill(_ color: Color = Color.overlay(0.035), radius: CGFloat = 7, active: Bool = false) -> some View {
        modifier(HoverFill(color: color, radius: radius, active: active))
    }
}

private struct HoverFill: ViewModifier {
    let color: Color
    let radius: CGFloat
    let active: Bool
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(hover && !active ? color : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hover = $0 }
    }
}

/// A line icon at the design's 17pt size.
struct LineIcon: View {
    let symbol: String
    var size: CGFloat = 17
    var body: some View {
        Image(systemName: symbol)
            .symbolVariant(.none)
            .font(.system(size: size * 0.86, weight: .light))
            .frame(width: size, height: size)
    }
}

/// 28pt square, borderless, grey icon that lights up on hover; labels show as icons.
struct GhostIconStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View { GhostBody(configuration: configuration, size: size) }

    private struct GhostBody: View {
        let configuration: Configuration
        let size: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .labelStyle(GhostLabelStyle())
                .foregroundStyle(Color.text3)
                .frame(minWidth: size, minHeight: size)
                .background((configuration.isPressed ? Color.overlay(0.09) : hover ? Color.overlay(0.05) : .clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hover = $0 }
        }
    }
}

/// Icon-only labels in the design's line style; plain text labels get side padding.
struct GhostLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .symbolVariant(.none)
            .font(.system(size: 14.5, weight: .light))
            .frame(width: 17, height: 17)
    }
}

/// The header search field: 200 wide, 28 high, on a faint grey.
struct HeaderSearch: View {
    @Binding var text: String
    var prompt = "Search"
    var width: CGFloat? = 200
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .regular))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.text)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .foregroundStyle(Color.text2)
        .padding(.horizontal, 8)
        .frame(width: width, height: 28)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(Color.overlay(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The design's segmented control: a grey track with a white, shadowed thumb.
struct Segments<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 12, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Color.text : Color(light: 0x48484A, dark: 0xC7C7CC))
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.thumb)
                                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                                    .shadow(color: .black.opacity(0.06), radius: 0, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.overlay(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 32pt rounded-rectangle buttons: accent fill, or white with a hairline border.
struct DesignButtonStyle: ButtonStyle {
    var prominent = true
    var height: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, prominent: prominent, height: height) }

    private struct StyledBody: View {
        let configuration: Configuration
        let prominent: Bool
        let height: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominent ? Color.white : Color.text)
                .padding(.horizontal, 14)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .background(prominent ? Color.brand : Color.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if !prominent { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.overlay(0.12)) }
                }
                .brightness(prominent && hover ? 0.06 : 0)
                .opacity(configuration.isPressed ? 0.85 : enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// 28pt capsules on catalog rows: accent text on grey ("Download"), or white on accent ("Add to Models").
/// `large` is the 32pt engine button ("Install").
struct PillButtonStyle: ButtonStyle {
    var filled = false
    var large = false
    var tint = Color.brand
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, filled: filled, large: large, tint: tint) }

    private struct StyledBody: View {
        let configuration: Configuration
        let filled: Bool
        let large: Bool
        let tint: Color
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: large ? 13.5 : 12.5, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint)
                .lineLimit(1)
                .padding(.horizontal, large ? 22 : 14)
                .frame(height: large ? 32 : 28)
                .background(filled ? tint : Color.well, in: Capsule())
                .brightness(hover ? (filled ? 0.06 : -0.03) : 0)
                .opacity(configuration.isPressed ? 0.85 : enabled ? 1 : 0.45)
                .contentShape(Capsule())
                .onHover { hover = $0 }
        }
    }
}

/// A 1pt hairline, as the design's borders.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Color.hairline).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// A vertical hairline you drag to resize the column on its left.
struct ResizeHairline: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var dragStart: Double?

    var body: some View {
        Hairline(vertical: true).overlay {
            Color.clear.frame(width: 8).contentShape(Rectangle())
                .pointerStyle(.columnResize)
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? width
                        dragStart = start
                        width = min(max(start + drag.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil })
        }
    }
}
