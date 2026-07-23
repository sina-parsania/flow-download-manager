// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// User-facing appearance choice for Flow’s two design-system versions.
public enum FlowAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public static let userDefaultsKey = "flowAppearanceMode"

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var detail: String {
        switch self {
        case .system: return "Follow macOS appearance"
        case .light: return "Mist field, ink type, citrus signal"
        case .dark: return "Night studio, pearl type, citrus signal"
        }
    }

    /// Forced scheme for `.light` / `.dark`; `nil` lets the system decide.
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Resolved color tokens for one Flow design-system version.
public struct FlowPalette: Equatable, Sendable {
    public let mist: Color
    public let mistDeep: Color
    public let ink: Color
    public let inkSoft: Color
    /// Text/icons drawn on ``signal`` fills — always dark for contrast on citrus.
    public let onSignal: Color
    public let signal: Color
    public let signalDeep: Color
    public let ember: Color
    public let pinSurface: Color
    public let pinStroke: Color
    public let chipFill: Color
    public let plateFill: Color
    public let orbCool: Color
    public let orbHighlight: Color
    public let isDark: Bool

    /// Studio mist — cool field, dark ink, citrus signal.
    public static let light = FlowPalette(
        mist: Color(red: 0.90, green: 0.93, blue: 0.95),
        mistDeep: Color(red: 0.82, green: 0.87, blue: 0.91),
        ink: Color(red: 0.08, green: 0.10, blue: 0.12),
        inkSoft: Color(red: 0.32, green: 0.36, blue: 0.40),
        onSignal: Color(red: 0.08, green: 0.10, blue: 0.12),
        signal: Color(red: 0.78, green: 0.95, blue: 0.18),
        signalDeep: Color(red: 0.42, green: 0.68, blue: 0.04),
        ember: Color(red: 0.92, green: 0.32, blue: 0.18),
        pinSurface: Color.white.opacity(0.82),
        pinStroke: Color.white.opacity(0.65),
        chipFill: Color.white.opacity(0.78),
        plateFill: Color.white.opacity(0.42),
        orbCool: Color(red: 0.45, green: 0.72, blue: 0.85),
        orbHighlight: Color.white.opacity(0.55),
        isDark: false
    )

    /// Night studio — same layout language, pearl type on deep charcoal.
    public static let dark = FlowPalette(
        mist: Color(red: 0.07, green: 0.08, blue: 0.10),
        mistDeep: Color(red: 0.11, green: 0.13, blue: 0.16),
        ink: Color(red: 0.96, green: 0.97, blue: 0.98),
        inkSoft: Color(red: 0.84, green: 0.87, blue: 0.90),
        onSignal: Color(red: 0.08, green: 0.10, blue: 0.12),
        signal: Color(red: 0.78, green: 0.92, blue: 0.28),
        signalDeep: Color(red: 0.55, green: 0.82, blue: 0.12),
        ember: Color(red: 1.0, green: 0.48, blue: 0.34),
        pinSurface: Color(red: 0.16, green: 0.18, blue: 0.21).opacity(0.94),
        pinStroke: Color.white.opacity(0.16),
        chipFill: Color.white.opacity(0.10),
        plateFill: Color.white.opacity(0.08),
        orbCool: Color(red: 0.25, green: 0.48, blue: 0.62),
        orbHighlight: Color.white.opacity(0.14),
        isDark: true
    )

    public static func resolved(mode: FlowAppearanceMode, system: ColorScheme) -> FlowPalette {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .system: return system == .dark ? .dark : .light
        }
    }

    /// System appearance without depending on SwiftUI's `colorScheme` environment
    /// (which can lag behind `preferredColorScheme` on the same modifier).
    @MainActor
    public static func resolved(mode: FlowAppearanceMode) -> FlowPalette {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .system:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? .dark : .light
        }
    }
}

public extension EnvironmentValues {
    @Entry var flowPalette: FlowPalette = .light
}

/// Applies appearance preference + injects the matching Flow palette.
public struct FlowAppearanceModifier: ViewModifier {
    @AppStorage(FlowAppearanceMode.userDefaultsKey) private var modeRaw = FlowAppearanceMode.system.rawValue

    public init() {}

    private var mode: FlowAppearanceMode {
        FlowAppearanceMode(rawValue: modeRaw) ?? .system
    }

    public func body(content: Content) -> some View {
        content
            .environment(\.flowPalette, FlowPalette.resolved(mode: mode))
            .preferredColorScheme(mode.preferredColorScheme)
    }
}

public extension View {
    func flowAppearance() -> some View {
        modifier(FlowAppearanceModifier())
    }
}

/// Visual language for Flow — shared type + helpers; colors come from ``FlowPalette``.
public enum FlowTheme {
    public static let brandName = "Flow"

    public enum Typeface {
        public static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
            .custom(weight == .heavy || weight == .black ? "AvenirNext-Heavy" : "AvenirNext-Bold", size: size)
                .weight(weight)
        }

        public static func title(_ size: CGFloat = 17) -> Font {
            .custom("AvenirNext-DemiBold", size: size)
        }

        public static func body(_ size: CGFloat = 13) -> Font {
            .custom("AvenirNext-Medium", size: size)
        }

        public static func caption(_ size: CGFloat = 11) -> Font {
            .custom("AvenirNext-Medium", size: size)
        }

        public static func mono(_ size: CGFloat = 12) -> Font {
            .system(size: size, weight: .medium, design: .monospaced)
        }
    }

    public static func signal(for role: JobRowModel.StatusRole, palette: FlowPalette) -> Color {
        switch role {
        case .active: return palette.signalDeep
        case .queued: return palette.inkSoft
        case .paused: return palette.isDark
            ? Color(red: 0.78, green: 0.70, blue: 0.48)
            : Color(red: 0.55, green: 0.48, blue: 0.35)
        case .success: return palette.isDark
            ? Color(red: 0.35, green: 0.82, blue: 0.68)
            : Color(red: 0.12, green: 0.55, blue: 0.42)
        case .failure: return palette.ember
        }
    }

    /// Abstract pin “media” wash — category-tinted, never a stock photo placeholder.
    public static func mediaWash(for category: String, seed: Int) -> [Color] {
        let tilt = Double((seed % 7) - 3) * 0.03
        switch category.lowercased() {
        case "videos":
            return [
                Color(red: 0.12 + tilt, green: 0.18, blue: 0.28),
                Color(red: 0.35, green: 0.55 + tilt, blue: 0.62)
            ]
        case "audio":
            return [
                Color(red: 0.22, green: 0.12, blue: 0.28 + tilt),
                Color(red: 0.75, green: 0.45, blue: 0.55)
            ]
        case "images":
            return [
                Color(red: 0.55 + tilt, green: 0.42, blue: 0.28),
                Color(red: 0.92, green: 0.78, blue: 0.55)
            ]
        case "documents":
            return [
                Color(red: 0.18, green: 0.28 + tilt, blue: 0.32),
                Color(red: 0.55, green: 0.72, blue: 0.68)
            ]
        case "archives":
            return [
                Color(red: 0.25, green: 0.22, blue: 0.18),
                Color(red: 0.62 + tilt, green: 0.55, blue: 0.35)
            ]
        default:
            return [
                Color(red: 0.15, green: 0.22 + tilt, blue: 0.26),
                Color(red: 0.55, green: 0.78, blue: 0.42)
            ]
        }
    }
}

/// Soft luminous field that sits behind the library — one composition, not a dashboard grid.
public struct FlowAtmosphere: View {
    @Environment(\.flowPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.mist, palette.mistDeep, palette.mist],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(palette.signal.opacity(palette.isDark ? 0.16 : 0.28))
                .blur(radius: 90)
                .frame(width: 340, height: 340)
                .offset(x: -160 + phase * 24, y: -120)
            Circle()
                .fill(palette.orbCool.opacity(palette.isDark ? 0.28 : 0.22))
                .blur(radius: 110)
                .frame(width: 420, height: 420)
                .offset(x: 180 - phase * 18, y: 160)
            Circle()
                .fill(palette.orbHighlight)
                .blur(radius: 80)
                .frame(width: 260, height: 260)
                .offset(x: 40, y: -40 + phase * 12)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 10).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }
}
