import SwiftUI
import UIKit

/// MDM Design System (Phase 3, Paket B).
///
/// The single source of truth for color, type, spacing, corner radii and the
/// reusable components listed in the redesign brief. Colors are adaptive:
/// the dark values are the brief's premium palette (#0B1220 / #131E30 /
/// #237BFA / #23C8D8) and the light values are the same tokens lightened, so
/// one set of components serves both Premium Dark and Premium Light.
///
/// Constraints honored here: iOS 16.0 deployment target (no
/// `.buttonBorderShape`, no `sensoryFeedback`, no `ContentUnavailableView`),
/// no animation that fights scrolling (progress bars update without explicit
/// animation), and haptics through UIKit so they work on iOS 16. Context
/// menus stay native SwiftUI `.contextMenu` — there is deliberately no
/// custom context-menu component.

// MARK: - Color tokens

private extension Color {
    init(mdmHex: UInt32) {
        self.init(
            red: Double((mdmHex >> 16) & 0xFF) / 255,
            green: Double((mdmHex >> 8) & 0xFF) / 255,
            blue: Double(mdmHex & 0xFF) / 255
        )
    }
}

private extension UIColor {
    convenience init(mdmHex: UInt32) {
        self.init(
            red: CGFloat((mdmHex >> 16) & 0xFF) / 255,
            green: CGFloat((mdmHex >> 8) & 0xFF) / 255,
            blue: CGFloat(mdmHex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private func mdmDynamicColor(dark: UInt32, light: UInt32) -> Color {
    Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(mdmHex: dark) : UIColor(mdmHex: light)
    })
}

extension Color {
    /// Primary app background.
    static let mdmBackground = mdmDynamicColor(dark: 0x0B1220, light: 0xF2F5F9)
    /// Card / secondary surface.
    static let mdmSurface = mdmDynamicColor(dark: 0x131E30, light: 0xFFFFFF)
    /// Lower-emphasis surface (progress tracks, icon wells, chips).
    static let mdmSurfaceMuted = mdmDynamicColor(dark: 0x1B2A44, light: 0xE8EEF5)
    /// 1px card borders.
    static let mdmBorder = mdmDynamicColor(dark: 0x24344F, light: 0xD9E2EC)
    /// Primary accent.
    static let mdmAccent = Color(mdmHex: 0x237BFA)
    /// Secondary accent.
    static let mdmAccent2 = Color(mdmHex: 0x23C8D8)
    static let mdmSuccess = Color(mdmHex: 0x26B77A)
    static let mdmWarning = Color(mdmHex: 0xF0A33B)
    static let mdmError = Color(mdmHex: 0xEF5B65)
    /// Secondary text.
    static let mdmMuted = mdmDynamicColor(dark: 0xA4B1C4, light: 0x5B6B80)
}

// MARK: - Type, spacing, radii

extension Font {
    static let mdmDisplay = Font.system(size: 34, weight: .bold)
    static let mdmTitle = Font.system(size: 20, weight: .semibold)
    static let mdmHeadline = Font.system(size: 17, weight: .semibold)
    static let mdmBody = Font.system(size: 17, weight: .regular)
    static let mdmCaption = Font.system(size: 13, weight: .regular)
    static func mdmMono(size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

enum MDMRadius {
    static let card: CGFloat = 20
    static let control: CGFloat = 14
    static let pill: CGFloat = 999
}

enum MDMSpacing {
    static let section: CGFloat = 20
    static let card: CGFloat = 16
    static let row: CGFloat = 12
    static let compact: CGFloat = 8
}

// MARK: - Haptics (UIKit, iOS 16-safe)

enum MDMHaptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Status tones

enum MDMStatusTone {
    case accent, teal, success, warning, error, muted

    var color: Color {
        switch self {
        case .accent: return .mdmAccent
        case .teal: return .mdmAccent2
        case .success: return .mdmSuccess
        case .warning: return .mdmWarning
        case .error: return .mdmError
        case .muted: return .mdmMuted
        }
    }
}

// MARK: - Cards

/// The standard card container: secondary surface, 20pt radius, 1px border.
struct MDMCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(MDMSpacing.card)
            .background(Color.mdmSurface, in: RoundedRectangle(cornerRadius: MDMRadius.card))
            .overlay(RoundedRectangle(cornerRadius: MDMRadius.card).stroke(Color.mdmBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }
}

/// Compact stat card for dashboard headers (icon + label + value).
struct MDMStatCard: View {
    var icon: String
    var label: String
    var value: String
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(accent).font(.system(size: 16, weight: .semibold))
            Text(label).font(.mdmCaption).foregroundStyle(Color.mdmMuted)
            Text(value).font(.mdmTitle).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.mdmSurface, in: RoundedRectangle(cornerRadius: MDMRadius.card))
        .overlay(RoundedRectangle(cornerRadius: MDMRadius.card).stroke(Color.mdmBorder, lineWidth: 1))
    }
}

// MARK: - Progress

/// Download progress bar with optional segment-boundary ticks. When segments
/// and a total are known the ticks sit at the real byte boundaries; otherwise
/// they divide the bar evenly. No explicit animation: the bar follows the
/// published progress without fighting list scrolling.
struct MDMProgressBar: View {
    var progress: Double
    var segments: [SegmentState] = []
    var totalBytes: Int64? = nil
    var failed: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.mdmSurfaceMuted)
                    .frame(height: 6)
                if failed {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.mdmError)
                        .frame(width: max(0, width * CGFloat(min(1, max(0, progress)))), height: 6)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [Color.mdmAccent, Color.mdmAccent2], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, width * CGFloat(min(1, max(0, progress)))), height: 6)
                }
                ForEach(dividerFractions.indices, id: \.self) { i in
                    Rectangle()
                        .fill(Color.mdmBackground)
                        .frame(width: 2, height: 6)
                        .offset(x: width * dividerFractions[i] - 1)
                }
            }
        }
        .frame(height: 6)
    }

    private var dividerFractions: [CGFloat] {
        guard segments.count > 1 else { return [] }
        if let total = totalBytes, total > 0 {
            var out: [CGFloat] = []
            for seg in segments.dropLast() {
                let end = seg.end >= 0 ? seg.end : total - 1
                let f = CGFloat(end + 1) / CGFloat(total)
                if f > 0.02 && f < 0.98 { out.append(f) }
            }
            return out
        }
        return (1..<segments.count).map { CGFloat($0) / CGFloat(segments.count) }
    }
}

// MARK: - Badges, headers, chips

struct MDMStatusBadge: View {
    var text: String
    var tone: MDMStatusTone

    var body: some View {
        Text(text)
            .font(.caption).fontWeight(.semibold)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tone.color.opacity(0.16), in: Capsule())
            .foregroundStyle(tone.color)
    }
}

struct MDMSectionHeader: View {
    var title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.mdmHeadline)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle) {
                    MDMHaptics.tap()
                    action()
                }
                .font(.subheadline)
                .foregroundStyle(Color.mdmAccent)
            }
        }
    }
}

struct MDMChip: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button {
            MDMHaptics.select()
            action()
        } label: {
            Text(title)
                .font(.subheadline).fontWeight(selected ? .semibold : .regular)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(selected ? Color.mdmAccent : Color.mdmSurfaceMuted, in: Capsule())
                .foregroundStyle(selected ? .white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Buttons

struct MDMPrimaryButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button {
            MDMHaptics.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.mdmAccent, in: RoundedRectangle(cornerRadius: MDMRadius.control))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

struct MDMSecondaryButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button {
            MDMHaptics.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.mdmSurfaceMuted, in: RoundedRectangle(cornerRadius: MDMRadius.control))
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct MDMIconButton: View {
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button {
            MDMHaptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Color.mdmSurfaceMuted, in: RoundedRectangle(cornerRadius: 11))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - States

struct MDMEmptyState: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(Color.mdmMuted)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.mdmMuted)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                MDMPrimaryButton(title: actionTitle, action: action)
                    .frame(maxWidth: 260)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

struct MDMErrorState: View {
    var message: String
    var retryTitle: String = "Coba lagi"
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.mdmError)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.mdmMuted)
                .multilineTextAlignment(.center)
            if let retry {
                MDMSecondaryButton(title: retryTitle, systemImage: "arrow.counterclockwise", action: retry)
                    .frame(maxWidth: 260)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

struct MDMLoadingState: View {
    var text: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(Color.mdmMuted)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// MARK: - Search, settings rows, tool/file/activity cards

struct MDMSearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.mdmMuted)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.mdmMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.mdmSurfaceMuted, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MDMSettingsRow<Trailing: View>: View {
    var icon: String
    var iconTint: Color
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(iconTint.opacity(0.16))
                    .frame(width: 32, height: 32)
                Image(systemName: icon).foregroundStyle(iconTint).font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(Color.mdmMuted)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 4)
    }
}

struct MDMToolCard: View {
    var icon: String
    var accent: Color
    var title: String
    var subtitle: String
    var action: () -> Void

    var body: some View {
        Button {
            MDMHaptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accent.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon).foregroundStyle(accent).font(.system(size: 19, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Color.primary)
                    Text(subtitle).font(.caption).foregroundStyle(Color.mdmMuted).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.mdmSurface, in: RoundedRectangle(cornerRadius: MDMRadius.card))
            .overlay(RoundedRectangle(cornerRadius: MDMRadius.card).stroke(Color.mdmBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct MDMFileCard: View {
    var icon: String
    var accent: Color
    var name: String
    var meta: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(accent.opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: icon).foregroundStyle(accent).font(.system(size: 17, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body).lineLimit(1)
                Text(meta).font(.caption).foregroundStyle(Color.mdmMuted).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.mdmMuted)
        }
        .padding(12)
        .background(Color.mdmSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.mdmBorder, lineWidth: 1))
    }
}

struct MDMActivityCard: View {
    var icon: String
    var accent: Color
    var title: String
    var detail: String
    var time: String
    var tone: MDMStatusTone

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.16)).frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(accent).font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(Color.mdmMuted).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Circle().fill(tone.color).frame(width: 8, height: 8)
                Text(time).font(.caption).foregroundStyle(Color.mdmMuted)
            }
        }
        .padding(12)
        .background(Color.mdmSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.mdmBorder, lineWidth: 1))
    }
}

/// Sheet content container: grabber + surface background. Use with
/// `.presentationDetents` at the call site.
struct MDMBottomSheet<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.mdmMuted.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 6)
            content
        }
        .background(Color.mdmBackground)
    }
}

// MARK: - Category tints (palette-disciplined)

extension DownloadCategory {
    var mdmTint: Color {
        switch self {
        case .all: return .mdmAccent
        case .video: return .mdmAccent
        case .music: return .mdmAccent2
        case .documents: return .mdmSuccess
        case .compressed: return .mdmWarning
        case .programs: return .mdmAccent
        case .images: return .mdmAccent2
        case .torrents: return .mdmWarning
        case .other: return .mdmMuted
        }
    }
}
