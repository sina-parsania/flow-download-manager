// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Semantic appearance adapter (`03-design-system-ui-ux.md` §11,
/// `00-master-plan.md` §4). One code path, two implementations: standard Liquid
/// Glass on macOS 26 (Xcode 26+ SDK), native materials on macOS 14/15 and on
/// older toolchains that do not yet know the glass APIs. Behavior and data are
/// identical; only the surface differs. Reduce Transparency is honored by the
/// system for both materials and glass.
public extension View {
    /// Apply a functional floating-control surface: system Liquid Glass on
    /// macOS 26, `Material.regular` on macOS 14/15. Use sparingly for
    /// navigation/controls floating above content — never behind dense table rows.
    @ViewBuilder
    func floatingControlSurface(in shape: some Shape = Capsule()) -> some View {
        // `glassEffect` / `GlassEffectContainer` exist only in the macOS 26 SDK.
        // Runtime `#available` is not enough — Xcode 16.4 (CI) cannot type-check
        // those symbols at all, so gate on the compiler/SDK that ships them.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: shape)
        }
        #else
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: shape)
        #endif
    }
}

/// Groups nearby custom glass controls so they morph/coordinate on macOS 26; a
/// plain container on 14/15 (and on toolchains without the glass SDK).
public struct FloatingControlGroup<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
