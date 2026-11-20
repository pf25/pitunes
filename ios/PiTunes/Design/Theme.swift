import SwiftUI

/// The PiTunes design system: every color, size and reusable control lives
/// here. Views should use these tokens instead of hardcoded numbers/colors.
/// See docs/design.md for the rules.
enum Theme {
    // MARK: Colors (dark-only app)

    /// Screen background.
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.059)          // #0B0B0F
    /// Cards, tiles, mini player.
    static let surface = Color(red: 0.090, green: 0.090, blue: 0.114)     // #17171D
    /// Controls sitting on a surface (chips, secondary buttons).
    static let surfaceRaised = Color(red: 0.145, green: 0.145, blue: 0.180) // #25252E
    /// Brand color, taken from the app icon. Primary actions, "now playing", likes.
    static let accent = Color(red: 1.0, green: 0.302, blue: 0.404)        // #FF4D67
    /// Second brand color; only used in gradients with `accent`.
    static let accent2 = Color(red: 0.545, green: 0.361, blue: 0.965)     // #8B5CF6
    /// Text/icons on top of `accent` (dark passes contrast; white doesn't).
    static let onAccent = Color(red: 0.07, green: 0.03, blue: 0.05)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.40)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.42)

    static let brandGradient = LinearGradient(colors: [accent, accent2],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Spacing (4-pt grid)

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16   // screen side margin
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32 // between shelves
    }

    // MARK: Corner radii

    enum Radius {
        static let s: CGFloat = 6    // row artwork
        static let m: CGFloat = 10   // cards
        static let l: CGFloat = 16   // hero artwork, mini player, tiles
    }

    // MARK: Sizes

    enum Size {
        static let rowArt: CGFloat = 48
        static let miniArt: CGFloat = 40
        /// Height of the mini player bar plus a little air (see MiniPlayerHost).
        static let miniPlayerClearance: CGFloat = 76
        static let card: CGFloat = 148
        static let cardLarge: CGFloat = 200   // lead shelf on Podcasts
        static let hero: CGFloat = 220
        static let tap: CGFloat = 44   // minimum tap target
    }
}

// MARK: - Text roles

extension Text {
    func sectionTitle() -> some View { font(.title2.bold()).foregroundStyle(.white) }
    func rowTitle() -> some View { font(.body).lineLimit(1) }
    func rowSubtitle() -> some View { font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
}

// MARK: - Buttons

/// The one main action on a screen (Play). Filled with the brand color.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.tap)
            .background(Theme.accent, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Supporting actions (Shuffle, Radio, Charts).
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.tap)
            .background(Theme.surfaceRaised, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Small pill for filters and moods. `selected` fills it with the brand color.
struct ChipStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? Theme.onAccent : .white)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(selected ? Theme.accent : Theme.surfaceRaised, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle { static var primary: Self { .init() } }
extension ButtonStyle where Self == SecondaryButtonStyle { static var secondary: Self { .init() } }

// MARK: - Small components

/// An icon in a rounded gradient tile (Library rows).
struct IconTile: View {
    let systemImage: String
    var gradient = true

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.m)
            .fill(gradient ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.surfaceRaised))
            .frame(width: Theme.Size.rowArt, height: Theme.Size.rowArt)
            .overlay(Image(systemName: systemImage).font(.headline).foregroundStyle(.white))
    }
}

/// Inline message for errors and "offline" notes (instead of bare red text).
struct Notice: View {
    let text: String
    var isError = true

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(.caption)
            .foregroundStyle(isError ? Theme.danger : Theme.textSecondary)
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension View {
    /// Standard look for every List screen.
    func themedList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
    }

    /// Standard background for ScrollView screens.
    func screenBackground() -> some View {
        background(Theme.bg.ignoresSafeArea())
    }

    /// Rows in themed lists: transparent background, subtle separators.
    func themedRow() -> some View {
        listRowBackground(Color.clear).listRowSeparatorTint(.white.opacity(0.08))
    }
}
