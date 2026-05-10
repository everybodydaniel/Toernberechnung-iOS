# Toernberechnung iOS

Toernberechnung ist eine iOS-App zur Törn- und Wattenpassageplanung für die ostfriesischen Inseln. Die App kombiniert Routen, Gezeiten, Wasserstand, Wetter und Borddaten in einer SwiftUI-Oberfläche und berechnet daraus eine nachvollziehbare Go-/Warning-/No-Go-Einschätzung.

> Hinweis: Die App ist ein Planungstool. Katalogwerte, Peilplanwerte, Wetter- und Gezeitendaten müssen vor der Fahrt skipperseitig mit offiziellen Quellen und der aktuellen Lage abgeglichen werden.

## Funktionen

- Mehrpunkt-Routenplanung zwischen ostfriesischen Häfen und Inseln
- Gezeitenbasierte Berechnung von FmW, WT und WuK nach Zwölftelregel
- Unterstützung für MHW- und Lottiefe-basierte Wegpunktberechnungen
- Automatische Suche nach einem sicheren Abfahrtsfenster
- BSH-Gezeitenabruf für Insel- und Zielpegel
- DWD-MOSMIX-Wetterdaten mit Stunden- und 7-Tage-Ansicht
- Kartenansicht mit MapLibre
- Logbuch, Crewverwaltung und Audit-Log via SwiftData
- PDF-Ansicht für Peilplan-/Planungsunterlagen
- Unit-Tests für Tidenlogik, Routenberechnung, Statuskombination und Katalogdaten

## Datenquellen

- BSH-Gezeiten: `https://gezeiten.bsh.de/data`
- DWD Open Data MOSMIX: `https://opendata.dwd.de/weather/local_forecasts/mos/MOSMIX_L/`
- Lokaler Wattenmeer-Katalog: `Toernberechnung/Resources/wadden_sea_catalog.json`

Der lokale Katalog enthält Routen-Templates, Wegpunkte, Peilplan-/Katalogwerte, Tidenreferenzen und Standarddistanzen. Neue Routen oder Inseln können datengetrieben ergänzt werden, ohne die Berechnungslogik umzuschreiben.

## Technik

- SwiftUI und SwiftData
- iOS Deployment Target: 18.0
- Swift 5.9
- MapLibre für Karten
- ZIPFoundation zum Entpacken der DWD-KMZ-Dateien
- XcodeGen-Projektbeschreibung in `project.yml`

## Projekt öffnen

Das Xcode-Projekt ist bereits im Repository enthalten:

```bash
open Toernberechnung.xcodeproj
```

Falls das Projekt aus `project.yml` neu erzeugt werden soll:

```bash
xcodegen generate
```

Danach in Xcode das Scheme `Toernberechnung` auswählen und auf einem iOS-Simulator oder Gerät starten.

## Tests

Die Unit-Tests liegen unter `ToernberechnungTests/` und prüfen unter anderem:

- Zwölftelregel und Hochwasserabweichungen
- Reisezeiten, SOG und Etappenberechnung
- Kombination von Gezeiten- und Wetterstatus
- Regression für Emden nach Norderney
- Laden und Konsistenz des Wattenmeer-Katalogs

Beispiel:

```bash
xcodebuild test -scheme Toernberechnung -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4.1'
```

## Repository-Struktur

```text
Toernberechnung/
  Engine/      Routenmodelle, Tidenstrategie, Berechnungsservice, Kataloglogik
  Services/    DWD-, BSH- und TideDataProvider-Integration
  Views/       SwiftUI-Tabs, Kartenansicht, Routen- und PDF-Ansichten
  Resources/   Wattenmeer-Katalog

ToernberechnungTests/
  Unit- und Regressionstests
```

## Status

Das Projekt ist auf die ostfriesischen Inseln fokussiert und für eine spätere Erweiterung auf weitere Wattenmeer-Reviere vorbereitet.
