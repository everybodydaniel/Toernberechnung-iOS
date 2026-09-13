import SwiftUI

// MARK: - Liquid Glass Style System
//
// Central set of view modifiers that switch between the iOS 26 Liquid
// Glass APIs and a hand-tuned iOS 18 fallback. Every UI surface in the
// app routes through these helpers — there are no raw `.glassEffect`
// calls anywhere else in the code. That gives us one place to evolve
// the design language and guarantees a clean fallback on iOS 18/25.
//
// Apple guidance baked in:
//   • Glass cannot sample other glass. We only put Glass on top-level
//     navigation/container surfaces — never on nested cards inside them.
//   • Group multiple glass shapes that sit close to each other inside
//     a `GlassEffectContainer` so the morphing animation is consistent.
//   • Use `.tint(...)` for semantic glass colour (prominent action),
//     never just for decoration.
//   • NEVER apply interactive glass inside a `Button` label. The
//     `.interactive()` effect installs its own press handling and
//     swallows the tap as soon as a scroll view or a UIKit map sits
//     underneath the control. Put the glass modifier OUTSIDE the button
//     and make `.contentShape(...)` the last modifier inside the label
//     (see `tideHero` in ContentView+Tides.swift for the reference
//     shape). Every `interactive:` parameter below therefore defaults
//     to `false`.
//
// All helpers are non-mutating extensions on `View` and `ButtonStyle`,
// so existing call sites stay compact and the fallback path is invisible
// to consumers.

// MARK: - Card Surface
//
// The hero surface used by the calculator cards, tide cards and any
// other top-level grouping. On iOS 26 this is a translucent Liquid Glass
// panel that lenses the gradient app background; on iOS 18 it's the
// existing `Color.cardBackground` with the same shadow.

extension View {

    /// Top-level card surface. Pass the same corner radius you used
    /// before; the modifier handles background, clipping and shadow.
    @ViewBuilder
    func appCardSurface(cornerRadius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: shape)
        } else {
            self
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardBackground)
                .clipShape(shape)
                .shadow(color: .black.opacity(0.05), radius: 12, y: 8)
        }
    }

}

// MARK: - Field Surface
//
// Secondary surface for small inline controls (pickers embedded in a
// card, info chips, dashboard tiles). These sit INSIDE a glass card, so
// they must NOT also become glass (Apple: "glass cannot sample other
// glass"). We render them as a flat `Color.fieldBackground` on both OS
// versions for a clean, calm hierarchy.

extension View {

    /// Inline field/pill surface. Always flat — even on iOS 26 — because
    /// it sits inside a glass card.
    func appFieldSurface(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fieldBackground, in: shape)
    }
}

// MARK: - Floating Overlay
//
// Used by edge-to-edge overlays such as the AppHeader, the navigation
// top-bar pills and the bottom dashboard inside `FullScreenNavigationView`.
// On iOS 26 each overlay becomes its own Liquid Glass panel; on iOS 18
// it falls back to `.ultraThinMaterial` so the look already approximates
// the design language.

extension View {

    @ViewBuilder
    func appFloatingOverlay(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(
                tint.map { Glass.regular.tint($0) } ?? .regular,
                in: shape
            )
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
    }

    /// Circular floating button used by the AppHeader and the FullScreen
    /// top-bar. Apply it OUTSIDE the `Button`, with `.contentShape(Circle())`
    /// as the last modifier inside the label.
    @ViewBuilder
    func appCircularGlass(diameter: CGFloat = 44, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self
                .frame(width: diameter, height: diameter)
                .glassEffect(
                    interactive ? glass.interactive() : glass,
                    in: Circle()
                )
        } else {
            self
                .frame(width: diameter, height: diameter)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 6)
        }
    }

    /// Dark, high-contrast Liquid Glass for controls floating over charts
    /// and nautical maps. The dark tint keeps white SF Symbols legible over
    /// bright chart details without turning the control into an opaque chip.
    @ViewBuilder
    func appDarkCircularLiquidGlass(diameter: CGFloat = 44, interactive: Bool = false) -> some View {
        let tint = Color(hex: 0x08243A).opacity(0.78)
        if #available(iOS 26.0, *) {
            self
                .frame(width: diameter, height: diameter)
                .glassEffect(interactive ? Glass.regular.interactive() : .regular, in: Circle())
        } else {
            self
                .frame(width: diameter, height: diameter)
                .background(.ultraThinMaterial, in: Circle())
                .background(tint, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.24), radius: 12, y: 7)
        }
    }

    /// Interactive route control over the map. iOS 26 deliberately stays
    /// untinted so the system can refract and adapt to the chart underneath.
    @ViewBuilder
    func appDarkFloatingOverlay(cornerRadius: CGFloat = 18, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tint = Color(hex: 0x202746)
        if #available(iOS 26.0, *) {
            self
                .glassEffect(interactive ? Glass.regular.interactive() : .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(tint.opacity(0.80), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.11), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
        }
    }

    /// Dark marine Liquid Glass for dashboard data placed on the light app
    /// canvas. The tint creates hierarchy without resorting to opaque cards.
    @ViewBuilder
    func appMarineDashboardGlass(cornerRadius: CGFloat = 24, tint: Color = Color(hex: 0x073A5B)) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self
                .glassEffect(Glass.regular.tint(tint.opacity(0.72)), in: shape)
                .shadow(color: tint.opacity(0.18), radius: 18, y: 10)
        } else {
            self
                .background(.thinMaterial, in: shape)
                .background(tint.opacity(0.84), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.8))
                .shadow(color: tint.opacity(0.22), radius: 18, y: 10)
        }
    }

    /// Main map dashboard. This is the only glass layer around its contents;
    /// nested rows stay flat so Liquid Glass samples the map directly.
    @ViewBuilder
    func appGraphiteMapOverlay(cornerRadius: CGFloat = 24) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tint = Color(hex: 0x202746)
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(tint.opacity(0.80), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.11), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.18), radius: 20, y: 12)
        }
    }

    /// Clear Liquid Glass shared by the complete Revier surface. Weather and
    /// tide animations remain visible without adding an opaque colour layer.
    @ViewBuilder
    func appWeatherLiquidGlass(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    interactive
                        ? Glass.clear.interactive()
                        : Glass.clear,
                    in: shape
                )
                .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.24), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
        }
    }

    /// Single clear-glass surface for a presented weather detail. Its child
    /// panels intentionally stay flat so the system never composites glass
    /// directly on top of another glass layer.
    @ViewBuilder
    func appWeatherDetailSheetGlass(cornerRadius: CGFloat = 32) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self
                .glassEffect(Glass.clear, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.24), lineWidth: 0.8))
        }
    }

    /// Flat grouping used inside the weather detail's single glass surface.
    func appWeatherDetailInset(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.primary.opacity(0.055), in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.7))
    }

    /// Flat content grouping inside the map dashboard. On iOS 26 the parent
    /// already provides Liquid Glass, so another material here would block
    /// refraction. iOS 18 keeps the established inset-card fallback.
    @ViewBuilder
    func appMapDashboardInset(cornerRadius: CGFloat = 18) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.background(
                Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

// MARK: - Icon Background

extension View {

    /// Transparent Liquid Glass background for small circular icons.
    @ViewBuilder
    func appGlassIconBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}


// MARK: - Button Styles
//
// `.appProminentButton(tint:)` is the equivalent of the prominent
// CTAs ("Berechnen & speichern", "Fahrt starten", "Fahrt beenden"). On
// iOS 26 we lean on `.buttonStyle(.glassProminent)` with a semantic tint;
// on iOS 18 we recreate the existing solid/gradient look so nothing
// regresses visually.

private struct LegacyProminentButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .foregroundStyle(.white)
            .background(tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct LegacyGlassButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(tint)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.8))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension View {

    /// Prominent CTA. iOS 26 = `.glassProminent`, iOS 18 = solid tint.
    @ViewBuilder
    func appProminentButton(tint: Color = .appPrimary) -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .tint(tint)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        } else {
            self.buttonStyle(LegacyProminentButtonStyle(tint: tint))
        }
    }

    /// Secondary action wrapped in glass. iOS 26 = `.glass`, iOS 18 =
    /// ultraThinMaterial capsule.
    @ViewBuilder
    func appGlassButton(tint: Color = Color(hex: 0x3C82FF)) -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .tint(tint)
        } else {
            self.buttonStyle(LegacyGlassButtonStyle(tint: tint))
        }
    }
}

// MARK: - Sheet / Cover background
//
// iOS 26 sheets adopt Liquid Glass automatically as long as the inner
// content does NOT paint an opaque background. The `LinearGradient` we
// used to put behind the SettingsSheet would block that. This modifier
// keeps the gradient on iOS 18 and hides it on iOS 26 so the system can
// render its own glass.

extension View {

    @ViewBuilder
    func appSheetBackground<Background: View>(@ViewBuilder fallback: () -> Background) -> some View {
        if #available(iOS 26.0, *) {
            self.background(Color.clear)
        } else {
            self.background(fallback())
        }
    }

    @ViewBuilder
    func appSheetGlassBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.presentationBackground {
                Color.clear.glassEffect(.regular, in: Rectangle())
            }
        } else {
            self.presentationBackground(.ultraThinMaterial)
        }
    }
}
