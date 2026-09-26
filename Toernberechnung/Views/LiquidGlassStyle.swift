import SwiftUI

// MARK: - Liquid-Glass-Gestaltung
//
// Zentrale View-Modifier für Liquid Glass ab iOS 26 und eine angepasste
// Darstellung für ältere iOS-Versionen. Gemeinsame Hilfsfunktionen halten
// das Erscheinungsbild der Flächen einheitlich.
//
// Grundregeln:
//   • Glas nur auf äußeren Navigations- und Containerflächen verwenden,
//     nicht auf darin eingebetteten Karten.
//   • Nahe Glasformen in einem `GlassEffectContainer` gruppieren,
//     damit Übergangsanimationen zusammenpassen.
//   • `.tint(...)` für die Bedeutung einer Aktion einsetzen,
//     nicht allein als Dekoration.
//   • Interaktives Glas außerhalb des `Button` anwenden. Innerhalb des Inhalts
//     kann `.interactive()` Tipps abfangen, wenn eine Scrollansicht oder
//     UIKit-Karte darunter liegt. `.contentShape(...)` bleibt der letzte
//     Modifier im Button-Inhalt. `tideHero` in ContentView+Tides.swift
//     zeigt dieses Muster. `interactive:` ist deshalb standardmäßig `false`.
//
// Die Hilfsfunktionen sind zustandslose Erweiterungen von `View` und
// `ButtonStyle`. Die Aufrufstellen brauchen keine eigene Versionsprüfung.

// MARK: - Kartenfläche
//
// Äußere Fläche für Berechnungs- und Gezeitenkarten sowie andere Gruppen.
// Ab iOS 26 ein durchscheinender Liquid-Glass-Bereich, der den Hintergrund
// bricht. Unter älteren Versionen bleibt `Color.cardBackground` mit Schatten.

extension View {

    /// Äußere Kartenfläche mit dem bisherigen Eckenradius.
    /// Der Modifier setzt Hintergrund, Zuschnitt und Schatten.
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

// MARK: - Eingabefläche
//
// Fläche für kleine Elemente innerhalb einer Karte, etwa Auswahlfelder,
// Hinweismarkierungen und Messwertkacheln. Sie liegt innerhalb einer
// Glasfläche und bleibt deshalb auf allen Versionen ohne eigenen Glaseffekt
// bei `Color.fieldBackground`.

extension View {

    /// Eingebettete Feld- oder Schaltfläche ohne eigenen Glaseffekt,
    /// da sie bereits innerhalb einer Glaskarte liegt.
    func appFieldSurface(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fieldBackground, in: shape)
    }
}

// MARK: - Schwebende Ebene
//
// Für AppHeader, obere Navigationsschaltflächen und den unteren Bereich
// in `FullScreenNavigationView`. Ab iOS 26 erhält jede Ebene Liquid Glass;
// ältere Versionen verwenden `.ultraThinMaterial`.

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

    /// Runder schwebender Button für AppHeader und die Vollbildnavigation.
    /// Außerhalb von `Button` anwenden; `.contentShape(Circle())` bleibt
    /// der letzte Modifier im Inhalt.
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

    /// Dunkles Liquid Glass für Bedienelemente über Seekarten. Die Tönung
    /// hält weiße SF Symbols über hellen Kartendetails lesbar, ohne die
    /// Fläche vollständig zu decken.
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

    /// Interaktives Routenelement über der Karte. Ab iOS 26 ohne eigene Tönung,
    /// damit das System die darunterliegende Karte brechen und berücksichtigen kann.
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

    /// Dunkles Liquid Glass für Messwerte vor dem hellen App-Hintergrund.
    /// Die Tönung hebt die Ebene hervor, ohne deckende Karten zu verwenden.
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

    /// Hauptbereich der Kartenübersicht mit einer einzigen Glasfläche.
    /// Innere Zeilen bleiben ohne Material, damit das Glas direkt die Karte aufnimmt.
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

    /// Gemeinsame klare Glasfläche für den Revierbereich. Wetter- und
    /// Gezeitenanimationen bleiben ohne zusätzliche deckende Farbschicht sichtbar.
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

    /// Eine klare Glasfläche für Wetterdetails. Untergeordnete Bereiche
    /// bleiben ohne Glaseffekt, damit keine Glasflächen übereinander liegen.
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

    /// Inhaltsgruppe ohne eigenen Glaseffekt innerhalb der Wetterdetailfläche.
    func appWeatherDetailInset(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.primary.opacity(0.055), in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.7))
    }

    /// Inhaltsgruppe innerhalb der Kartenübersicht. Ab iOS 26 liefert die äußere
    /// Fläche bereits Liquid Glass; ein weiteres Material würde die Brechung
    /// verdecken. Unter iOS 18 bleibt die bisherige eingebettete Karte.
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

// MARK: - Symbolhintergrund

extension View {

    /// Transparenter Liquid-Glass-Hintergrund für kleine runde Symbole.
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


// MARK: - Button-Stile
//
// `.appProminentButton(tint:)` gestaltet hervorgehobene Aktionen wie
// "Berechnen & speichern", "Fahrt starten" und "Fahrt beenden".
// Ab iOS 26 verwendet es `.buttonStyle(.glassProminent)` mit passender
// Tönung, unter iOS 18 die bisherige Farb- oder Verlaufsdarstellung.

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

    /// Hervorgehobene Aktion: ab iOS 26 `.glassProminent`, unter iOS 18 deckende Tönung.
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

    /// Weitere Aktion: ab iOS 26 `.glass`, unter iOS 18
    /// eine Kapsel mit ultraThinMaterial.
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

// MARK: - Hintergrund modaler und Vollbildansichten
//
// Ab iOS 26 erhalten modale Ansichten automatisch Liquid Glass, wenn ihr
// Inhalt keinen deckenden Hintergrund setzt. Der frühere `LinearGradient`
// der Einstellungen würde dies verdecken. Der Modifier behält ihn für
// iOS 18 und blendet ihn ab iOS 26 aus.

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
