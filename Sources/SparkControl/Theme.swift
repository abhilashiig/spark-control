import SwiftUI
import AppKit

// MARK: Palette

extension Color {
    /// `nvidia` overrides the dark value under the NVIDIA and Nebula themes (Nebula swaps its green for violet);
    /// without it, a cool Graphite grey turns neutral.
    init(light: UInt32, dark: UInt32, nvidia: UInt32? = nil) {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) {
            let mode = Appearance.current
            return $0.bestMatch(from: [.darkAqua, .vibrantDark]) == nil
                ? ns(mode == .softLight ? Self.soften(light, floor: 0, ceiling: 0xE6) : light)
                : ns(mode == .softDark ? Self.soften(dark, floor: 0x2A, ceiling: 0xFF)
                     : mode.sharp ? nvidia.map { mode == .nebula ? Self.nebula($0) : $0 } ?? Self.neutral(dark) : dark)
        })
    }

    /// The soft themes: greys squeezed into floor...ceiling (whites toned down, or blacks raised to charcoal).
    /// Saturated colours are left alone.
    static func soften(_ v: UInt32, floor: UInt32, ceiling: UInt32) -> UInt32 {
        let c = [v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff]
        guard c.max()! - c.min()! <= 12 else { return v }
        return c.map { floor + $0 * (ceiling - floor) / 255 }.reduce(0) { $0 << 8 | $1 }
    }

    /// Nebula: NVIDIA green and its lighter link green become violet.
    static func nebula(_ v: UInt32) -> UInt32 { [0x76B900: 0x9B7BFF, 0x9BD12E: 0xC4B5FD][v] ?? v }

    static func neutral(_ v: UInt32) -> UInt32 {
        let c = [v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff]
        guard c.max()! - c.min()! <= 12 else { return v }
        let g = c.reduce(0, +) / 3
        return g << 16 | g << 8 | g
    }

    // Graphite: near-black surfaces in dark mode, a periwinkle accent, and light-on-dark primary buttons.
    static let brand = Color(light: 0x4F5BD5, dark: 0x8B9DFF, nvidia: 0x76B900)
    /// Links and the selected sidebar icon.
    static let link = Color(light: 0x4F5BD5, dark: 0xAEB9FF, nvidia: 0x9BD12E)
    /// The app icon's spark.
    static let spark = Color(light: 0xF29A2E, dark: 0xFFB04D)
    /// The app icon's dial background.
    static let sparkNavy = Color(light: 0x24307A, dark: 0x2E3B8F)
    static let pageBackground = Color(light: 0xFFFFFF, dark: 0x0A0A0B, nvidia: 0x000000)
    static let cardBackground = Color(light: 0xFFFFFF, dark: 0x131316, nvidia: 0x1A1A1A)
    static let cardBorder = Color(light: 0xE4E4E7, dark: 0x222227, nvidia: 0x2E2E2E)
    static let sidebar = Color(light: 0xF4F4F5, dark: 0x0E0E10, nvidia: 0x121212)
    /// Model tiles, tracks and wells.
    static let well = Color(light: 0xF2F2F4, dark: 0x1A1A1E, nvidia: 0x222222)
    /// The dark square engine icons sit on.
    static let ink = Color(light: 0x1D1D1F, dark: 0x26262B, nvidia: 0x222222)
    /// Primary buttons: ink on light, near-white on dark.
    static let primaryFill = Color(light: 0x18181B, dark: 0xEDEDEF, nvidia: 0x76B900)
    static let primaryText = Color(light: 0xFFFFFF, dark: 0x0A0A0B, nvidia: 0x000000)
    static let text = Color(light: 0x18181B, dark: 0xEDEDEF, nvidia: 0xEEEEEE)
    /// Labels, column headers and meta lines.
    static let text2 = Color(light: 0x71717A, dark: 0x8A8A93, nvidia: 0x8F8F8F)
    /// Body copy one step down from `text`, and icon buttons.
    static let text3 = Color(light: 0x52525B, dark: 0xA1A1AA, nvidia: 0xA8A8A8)
    static let hairline = Color(light: 0xE4E4E7, dark: 0x1F1F23, nvidia: 0x2A2A2A)
    static let running = Color(light: 0x16A34A, dark: 0x4ADE80)
    static let danger = Color(light: 0xDC2626, dark: 0xF87171)
    /// The segmented control's selected thumb.
    static let thumb = Color(light: 0xFFFFFF, dark: 0x26262B, nvidia: 0x333333)

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
    case system, light, softLight, softDark, dark, nvidia
    case nebula = "ember"  // renamed from Ember; the old raw value keeps saved choices
    static let key = "appearance"
    /// Read while colours resolve, so it holds from the first frame (before `apply` runs).
    static var current: Appearance { UserDefaults.standard.string(forKey: key).flatMap(Appearance.init) ?? .system }
    var id: Self { self }
    /// NVIDIA and Nebula: black, square corners, uppercase condensed titles.
    var sharp: Bool { self == .nvidia || self == .nebula }
    var label: String {
        switch self {
        case .softLight: "Soft Light"
        case .softDark: "Soft Dark"
        case .nvidia: "NVIDIA"
        case .nebula: "Nebula"
        default: rawValue.capitalized
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .softLight: .light
        case .dark, .softDark, .nvidia, .nebula: .dark
        }
    }

    static func apply(_ raw: String) {
        let mode = Appearance(rawValue: raw) ?? .system
        NSApp.appearance = switch mode {
        case .system: nil
        case .light, .softLight: NSAppearance(named: .aqua)
        case .softDark, .dark, .nvidia, .nebula: NSAppearance(named: .darkAqua)
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
        // A soft theme shares its NSAppearance with light or dark, so a switch rebuilds the views to re-resolve colours.
        // SwiftUI-drawn controls (a menu Picker) follow colorScheme, not NSApp.appearance, so set both.
        content.id(appearance)
            .preferredColorScheme((Appearance(rawValue: appearance) ?? .system).scheme)
            .onChange(of: appearance, initial: true) { Appearance.apply(appearance) }
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

extension CGFloat {
    /// Every rounded rectangle's radius: as designed, or near-square under NVIDIA and Nebula.
    static func corner(_ r: CGFloat) -> CGFloat { Appearance.current.sharp ? Swift.min(r, 2) : r }
}

extension Text {
    /// A page title: 17pt semibold, or NVIDIA's uppercase condensed bold.
    func pageTitle() -> some View {
        let nv = Appearance.current.sharp
        return font(.system(size: nv ? 18 : 17, weight: nv ? .bold : .semibold).width(nv ? .condensed : .standard))
            .textCase(nv ? .uppercase : nil).tracking(nv ? 0.4 : -0.2).foregroundStyle(Color.text).lineLimit(1)
    }

    /// A section header: 13pt semibold, or NVIDIA's small uppercase condensed caps.
    func sectionTitle() -> some View {
        let nv = Appearance.current.sharp
        return font(.system(size: nv ? 12 : 13, weight: nv ? .bold : .semibold).width(nv ? .condensed : .standard))
            .textCase(nv ? .uppercase : nil).tracking(nv ? 1.2 : 0).foregroundStyle(Color.text)
    }
}

// MARK: Pages and cards

extension View {
    /// A Form in the app's own style: titled sections as bordered cards with hairlines between rows.
    func page() -> some View {
        formStyle(DesignFormStyle()).background(Color.pageBackground)
    }

    func card(padding: CGFloat = 16, radius: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(radius), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(radius), style: .continuous).strokeBorder(Color.cardBorder))
    }
}

/// Lays a Form out as the redesign's cards: section header above, rows split by hairlines, footer below.
/// Rows are label left, control right; a label's second Text is its grey subtitle, as in a grouped Form.
struct DesignFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(sections: configuration.content) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        if !section.header.isEmpty {
                            let nv = Appearance.current.sharp
                            Group { section.header }
                                .font(.system(size: nv ? 12 : 13, weight: nv ? .bold : .semibold).width(nv ? .condensed : .standard))
                                .tracking(nv ? 1.2 : 0).foregroundStyle(Color.text)
                                .textCase(nv ? .uppercase : nil)
                        }
                        Group(subviews: section.content) { rows in
                            if !rows.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(rows) { row in
                                        row.padding(.horizontal, 16).padding(.vertical, 11)
                                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        if row.id != rows.last?.id { Hairline() }
                                    }
                                }
                                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(12), style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: .corner(12), style: .continuous).strokeBorder(Color.cardBorder))
                            }
                        }
                        if !section.footer.isEmpty {
                            Group { section.footer }.font(.system(size: 12)).foregroundStyle(Color.text2)
                        }
                    }
                }
            }
            .font(.system(size: 13))
            .labeledContentStyle(DesignRowStyle())
            .toggleStyle(DesignToggleStyle())
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Title (and grey subtitle) left, value right.
struct DesignRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 16) {
            RowLabel { configuration.label }
            Spacer(minLength: 8)
            configuration.content.foregroundStyle(Color.text3).multilineTextAlignment(.trailing)
        }
    }
}

struct DesignToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            RowLabel { configuration.label }
            Spacer(minLength: 8)
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

/// A row label's first view in the body style; any after it as the grey subtitle.
private struct RowLabel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Group(subviews: content) { parts in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(parts) { part in
                    if part.id == parts.first?.id {
                        part.font(.system(size: 13)).foregroundStyle(Color.text)
                    } else {
                        part.font(.system(size: 12)).foregroundStyle(Color.text2)
                    }
                }
            }
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).sectionTitle() }
            content
        }
        .card()
    }
}

// MARK: Layout

/// Tiles in rows that stay full: as many per row as fit at `minWidth` (never more than `maxPerRow`), each one filling
/// its share of the row at the tallest tile's height. When the last row would be left with a single tile, the tiles
/// spread over the rows instead, so a group whose size divides evenly never strands one — four tiles are 2 + 2 where
/// only three would fit, never 3 + 1.
struct BalancedGrid: Layout {
    var minWidth: CGFloat
    var spacing: CGFloat = 12
    var maxPerRow: Int = .max

    private struct Slot { var x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 0, h: CGFloat = 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(width: bounds.width, subviews: subviews)
        for (slot, v) in zip(r.slots, subviews) {
            v.place(at: CGPoint(x: bounds.minX + slot.x, y: bounds.minY + slot.y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: slot.w, height: slot.h))
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> (slots: [Slot], size: CGSize) {
        let n = subviews.count
        var cols = width.isFinite ? Int((width + spacing) / (minWidth + spacing)) : .max
        cols = max(1, min(cols, maxPerRow, n))
        let rowCount = n == 0 ? 0 : (n + cols - 1) / cols          // rows as equal in length as cols allow
        var slots = Array(repeating: Slot(), count: n), y: CGFloat = 0, widest: CGFloat = 0, at = 0
        for row in 0..<rowCount {
            let count = n / rowCount + (row < n % rowCount ? 1 : 0)
            let w = width.isFinite ? max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count)) : minWidth
            var tall: CGFloat = 0
            for k in 0..<count {
                let h = subviews[at + k].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
                slots[at + k] = Slot(x: CGFloat(k) * (w + spacing), y: y, w: w, h: h)
                tall = max(tall, h)
            }
            for k in 0..<count { slots[at + k].h = tall }   // top-align rows at the tallest tile
            widest = max(widest, CGFloat(count) * w + CGFloat(count - 1) * spacing)
            at += count; y += tall + spacing
        }
        return (slots, CGSize(width: width.isFinite ? max(widest, width) : widest, height: max(0, y - spacing)))
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
        RoundedRectangle(cornerRadius: .corner(size * (size < 40 ? 0.263 : 0.25)), style: .continuous)
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
                    .background(Color.ink, in: RoundedRectangle(cornerRadius: .corner(size * 0.24), style: .continuous))
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
            .foregroundStyle(Color.primaryText)
            .frame(width: size, height: size)
            .background(Color.primaryFill, in: RoundedRectangle(cornerRadius: .corner(size * 0.27), style: .continuous))
            .accessibilityHidden(true)
    }
}

struct EngineBadge: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Self.color(name).opacity(0.12), in: RoundedRectangle(cornerRadius: .corner(6), style: .continuous))
            .foregroundStyle(Self.text(name))
            .lineLimit(1)
            .fixedSize()
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "TensorFold": Color(light: 0x5B6CF0, dark: 0x8B9DFF, nvidia: 0x76B900)
        case "vLLM": Color(light: 0xD97706, dark: 0xFBBF24)
        case "Ollama": Color(light: 0x0D9488, dark: 0x2DD4BF)
        case "ComfyUI": Color(light: 0xDB2777, dark: 0xF472B6)
        default: Color(light: 0x71717A, dark: 0x8A8A93)
        }
    }

    static func text(_ name: String) -> Color {
        switch name {
        case "TensorFold": Color(light: 0x4338CA, dark: 0xB7C1FF, nvidia: 0x9BD12E)
        case "vLLM": Color(light: 0xB45309, dark: 0xFCD34D)
        case "Ollama": Color(light: 0x0F766E, dark: 0x5EEAD4)
        case "ComfyUI": Color(light: 0xBE185D, dark: 0xF9A8D4)
        default: Color(light: 0x52525B, dark: 0xC4C4CC)
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
        .background(VizColor.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: .corner(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(12), style: .continuous).strokeBorder(VizColor.warning.opacity(0.4)))
    }
}

// MARK: Page chrome

/// A page's 52pt title bar: title left, controls right, hairline below. Drags the window, which has no title bar.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(title).pageTitle()
            Spacer(minLength: 0)
            trailing
                .labelStyle(.iconOnly)
                .buttonStyle(GhostIconStyle())
                .menuStyle(.button)
                .menuIndicator(.hidden)
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
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
            .background(hover && !active ? color : .clear, in: RoundedRectangle(cornerRadius: .corner(radius), style: .continuous))
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
            .font(.system(size: size * 0.86, weight: Appearance.current.sharp ? .regular : .light))
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
                            in: RoundedRectangle(cornerRadius: .corner(7), style: .continuous))
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
            .font(.system(size: 14.5, weight: Appearance.current.sharp ? .regular : .light))
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
        .padding(.horizontal, 2)
        .frame(width: width, height: 32)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(Color(light: 0xF4F4F5, dark: 0x131316, nvidia: 0x1A1A1A), in: RoundedRectangle(cornerRadius: .corner(9), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(9), style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B, nvidia: 0x333333)))
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
                        .foregroundStyle(on ? Color.text : Color.text3)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: .corner(6), style: .continuous).fill(Color.thumb)
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
        .padding(3)
        .background(Color(light: 0xF4F4F5, dark: 0x131316, nvidia: 0x1A1A1A), in: RoundedRectangle(cornerRadius: .corner(9), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(9), style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B, nvidia: 0x333333)))
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
                .font(.system(size: 13, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Color.primaryText : Color.text)
                .padding(.horizontal, 14)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .background(prominent ? Color.primaryFill : hover ? Color.overlay(0.04) : .clear, in: RoundedRectangle(cornerRadius: .corner(9), style: .continuous))
                .overlay {
                    if !prominent { RoundedRectangle(cornerRadius: .corner(9), style: .continuous).strokeBorder(Color(light: 0xD4D4D8, dark: 0x2E2E34, nvidia: 0x3D3D3D)) }
                }
                .brightness(prominent && hover ? -0.06 : 0)
                .opacity(configuration.isPressed ? 0.85 : enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// 30pt buttons on catalog rows: outlined ("Download"), or the primary fill ("Add to Models").
/// `large` is the 34pt engine button ("Install").
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
                .foregroundStyle(filled ? Color.primaryText : tint == .brand ? Color.text : tint)
                .lineLimit(1)
                .padding(.horizontal, large ? 16 : 12)
                .frame(height: large ? 34 : 30)
                .background(filled ? Color.primaryFill : hover ? Color.overlay(0.04) : .clear, in: RoundedRectangle(cornerRadius: .corner(8), style: .continuous))
                .overlay {
                    if !filled { RoundedRectangle(cornerRadius: .corner(8), style: .continuous).strokeBorder(Color(light: 0xD4D4D8, dark: 0x2E2E34, nvidia: 0x3D3D3D)) }
                }
                .brightness(filled && hover ? -0.06 : 0)
                .opacity(configuration.isPressed ? 0.85 : enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: .corner(8), style: .continuous))
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
