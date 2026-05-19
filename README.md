# Toernberechnung iOS

[![CI](https://github.com/everybodydaniel/Toernberechnung-iOS/actions/workflows/ci.yml/badge.svg)](https://github.com/everybodydaniel/Toernberechnung-iOS/actions/workflows/ci.yml)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![Platform iOS 18+](https://img.shields.io/badge/Platform-iOS%2018%2B-blue.svg)](https://developer.apple.com/ios/)
[![License MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Toernberechnung** ist eine iOS-App zur Törn- und Wattenpassageplanung für die ostfriesischen Inseln. Die App kombiniert Routen, Gezeiten, Wasserstand, Wetter und Borddaten in einer SwiftUI-Oberfläche und berechnet daraus eine nachvollziehbare **Go / Warning / No-Go**-Einschätzung.

> **Hinweis:** Die App ist ein Planungstool. Katalogwerte, Peilplanwerte, Wetter- und Gezeitendaten müssen vor der Fahrt skipperseitig mit offiziellen Quellen und der aktuellen Lage abgeglichen werden.

---

## Inhaltsverzeichnis

- [Features](#features)
- [Setup & Installation](#setup--installation)
- [Architektur](#architektur)
- [Datenquellen](#datenquellen)
- [Code Quality](#code-quality)
- [Tests](#tests)
- [CI/CD Pipeline](#cicd-pipeline)
- [Versionierung](#versionierung)
- [Contributing](#contributing)
- [Lizenz](#lizenz)

---

## Features

- Mehrpunkt-Routenplanung zwischen ostfriesischen Häfen und Inseln
- Gezeitenbasierte Berechnung von FmW, WT und WuK nach Zwölftelregel
- Unterstützung für MHW- und Lottiefe-basierte Wegpunktberechnungen
- Automatische Suche nach einem sicheren Abfahrtsfenster
- BSH-Gezeitenabruf für Insel- und Zielpegel
- DWD-MOSMIX-Wetterdaten mit Stunden- und 7-Tage-Ansicht
- Kartenansicht mit MapLibre (nautische Seekarte)
- Logbuch, Crewverwaltung und Audit-Log via SwiftData
- PDF-Export für das Schiffstagebuch
- Unit-Tests für Tidenlogik, Routenberechnung, Statuskombination und Katalogdaten

---

## Setup & Installation

### Voraussetzungen

| Tool       | Version  |
|------------|----------|
| Xcode      | 16.0+    |
| iOS Target | 18.0+    |
| Swift      | 5.9      |
| XcodeGen   | 2.30+    |

### Projekt einrichten

```bash
# 1. Repository klonen
git clone https://github.com/everybodydaniel/Toernberechnung-iOS.git
cd Toernberechnung-iOS

# 2. Xcode-Projekt generieren (optional, .xcodeproj ist im Repo)
xcodegen generate

# 3. Projekt öffnen
open Toernberechnung.xcodeproj
```

Dependencies (MapLibre, ZIPFoundation) werden automatisch über **Swift Package Manager** aufgelöst.

### SwiftLint installieren (empfohlen)

```bash
brew install swiftlint
```

---

## Architektur

Das Projekt folgt einer **MVVM-Architektur** mit klarer Trennung zwischen UI, Geschäftslogik und Datenzugriff:

```
Toernberechnung/
├── Engine/          # Routenmodelle, Tidenstrategie, Berechnungsservice, Kataloglogik
│   ├── RoutePlanModels.swift
│   ├── RouteCalculationService.swift
│   ├── TidalHeightStrategy.swift
│   ├── PassageWindowScanner.swift
│   ├── WaddenSeaCatalog.swift
│   ├── RoutePlannerViewModel.swift
│   └── SeaRoutePlanner.swift
├── Services/        # Externe API-Integration (DWD, BSH)
│   ├── DWDService.swift
│   ├── BSHTideService.swift
│   └── TideDataProvider.swift
├── Views/           # SwiftUI-Tabs, Kartenansicht und Routendetails
│   ├── ContentView.swift (+ Extensions)
│   ├── MapView.swift
│   └── ContentView+RouteDetail.swift
└── Resources/       # Wattenmeer-Katalog (JSON)
    └── wadden_sea_catalog.json

ToernberechnungTests/
└── RouteCalculationTests.swift
```

### Schlüsselkomponenten

| Schicht        | Verantwortung                                              |
|----------------|------------------------------------------------------------|
| **Views**      | SwiftUI-Oberfläche, Tab-Navigation, Kartenanzeige          |
| **ViewModel**  | `RoutePlannerViewModel` – Zustand und Berechnungssteuerung |
| **Engine**     | Tidenberechnung, Routenplanung, Passagefenster-Scan        |
| **Services**   | HTTP-Clients für BSH-Gezeiten und DWD-Wetterdaten          |
| **Resources**  | Kuratierter Wattenmeer-Katalog mit Routen und Wegpunkten   |

---

## Datenquellen

| Quelle            | Zweck                          | URL                                                             |
|--------------------|--------------------------------|-----------------------------------------------------------------|
| BSH Gezeiten       | Hoch-/Niedrigwasser-Vorhersage | `https://gezeiten.bsh.de/data`                                  |
| DWD Open Data      | MOSMIX-Wetterprognosen         | `https://opendata.dwd.de/weather/local_forecasts/mos/MOSMIX_L/` |
| Lokaler Katalog    | Routen, Wegpunkte, Tiefenwerte | `wadden_sea_catalog.json`                                       |

---

## Code Quality

### SwiftLint

Das Projekt nutzt [SwiftLint](https://github.com/realm/SwiftLint) für statische Code-Analyse. Die Konfiguration liegt in `.swiftlint.yml`.

```bash
# Lokal ausführen
swiftlint lint --config .swiftlint.yml

# Automatische Korrektur (wo möglich)
swiftlint --fix --config .swiftlint.yml
```

### DocC-Dokumentation

Swift-Quellcode ist mit `///`-DocC-Kommentaren dokumentiert. Dokumentation kompilieren:

```bash
# Via Xcode: Product → Build Documentation (⌃⇧⌘D)

# Via Terminal
xcodebuild docbuild \
  -scheme Toernberechnung \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

---

## Tests

Unit-Tests liegen unter `ToernberechnungTests/` und decken ab:

- Zwölftelregel und Hochwasserabweichungen
- Reisezeiten, SOG und Etappenberechnung
- Kombination von Gezeiten- und Wetterstatus
- Regression für Emden → Norderney
- Laden und Konsistenz des Wattenmeer-Katalogs

```bash
# Tests über CLI ausführen
xcodebuild test \
  -project Toernberechnung.xcodeproj \
  -scheme Toernberechnung \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

---

## CI/CD Pipeline

Die GitHub Actions Pipeline (`.github/workflows/ci.yml`) führt bei jedem Push/PR auf `main` aus:

| Job            | Beschreibung                               |
|----------------|--------------------------------------------|
| 🧹 SwiftLint  | Statische Code-Analyse                     |
| 🏗️ Build & Test | Kompilierung und Unit Tests auf iOS Simulator |
| 📊 SonarCloud  | Code-Qualitätsanalyse *(Platzhalter)*      |

---

## Versionierung

Das Projekt nutzt [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`):

| Xcode-Feld              | Bedeutung                                  | Beispiel |
|--------------------------|--------------------------------------------|----------|
| `MARKETING_VERSION`     | Öffentliche Version (SemVer)               | `1.2.0`  |
| `CURRENT_PROJECT_VERSION`| Build-Nummer (inkrementell)               | `42`     |

---

## Lizenz

Dieses Projekt steht unter der [MIT-Lizenz](LICENSE).

Copyright © 2026 everybodydaniel
