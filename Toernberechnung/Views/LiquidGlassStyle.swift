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

    /// Same as `appCardSurface` but without the leading-aligned frame.
    /// Use for metric-style grid cards where the parent already controls
    /// dimensions.
    @ViewBuilder
    func appMetricSurface(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self
                .padding(14)
                .glassEffect(.regular, in: shape)
        } else {
            self
                .padding(14)
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

    /// Circular floating button. Match what the existing `CircleButton`
    /// rendered before so the AppHeader and the FullScreen top-bar can
    /// reuse the same call.
    @ViewBuilder
    func appCircularGlass(diameter: CGFloat = 44, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self
                .frame(width: diameter, height: diameter)
                .glassEffect(
                    (tint.map { Glass.regular.tint($0) } ?? .regular).interactive(),
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
}

// MARK: - Chip surface
//
// Capsule pill used for tiny status indicators (e.g. "Bezug: SKN").

extension View {

    @ViewBuilder
    func appChipSurface(tint: Color = Color(hex: 0x3C82FF)) -> some View {
        if #available(iOS 26.0, *) {
            self
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(Glass.regular.tint(tint.opacity(0.55)), in: Capsule())
        } else {
            self
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(tint.opacity(0.12), in: Capsule())
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
}

// MARK: - TabView minimize behavior
//
// One-call modifier so the TabView code stays readable. iOS 26 enables
// the new auto-minimize tab bar; older OSes are a no-op.

extension View {

    @ViewBuilder
    func appTabBarMinimize() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
