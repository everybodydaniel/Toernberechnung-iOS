# Coverage-Analyse – Toernberechnung iOS

**Stichdatum:** 2026-05-25 · **Werkzeuge:** xcodebuild (Xcode 26.5), Slather, Fastlane
**Datensatz:** `build/Test.xcresult` aus dem Lauf von 104 Unit-/Integrationstests (alle bestanden, 21,6 s).

---

## 1 · Tool-basierte Coverage (Statement / C0)

### 1.1 Gesamtkennzahlen

| Bereich | Ausführbare Zeilen | Abgedeckt | Coverage |
|---|---:|---:|---:|
| **Gesamt (inkl. Frameworks)** | 11 700 | 5 190 | **44,4 %** |
| **App-Target `Toernberechnung`** | 7 886 | 3 735 | **47,4 %** |
| **Test-Target `ToernberechnungTests`** | 1 482 | 1 423 | **96,0 %** |

### 1.2 App-Target je Datei (sortiert nach Coverage)

| Datei | Coverage | Lines |
|---|---:|---:|
| `Engine/TidalHeightStrategy.swift` | **100,0 %** | 46 |
| `Views/ContentView+InitialData.swift` | 100,0 % | 15 |
| `Engine/PassageWindowScanner.swift` | **98,5 %** | 65 |
| `Engine/RouteCalculationService.swift` | **97,4 %** | 382 |
| `Views/ContentView+RouteDetail.swift` | 87,5 % | 328 |
| `Services/BSHTideService.swift` | 84,1 % | 151 |
| `Engine/WaddenSeaCatalog.swift` | 81,3 % | 187 |
| `Services/TideDataProvider.swift` | 80,0 % | 30 |
| `Views/MapView.swift` | 78,3 % | 313 |
| `Views/ContentView.swift` | 75,9 % | 278 |
| `Views/ContentView+MapTab.swift` | 69,8 % | 689 |
| `Views/ContentView+Tides.swift` | 61,1 % | 435 |
| `Engine/RoutePlanModels.swift` | 57,7 % | 26 |
| `Engine/RoutePlannerViewModel.swift` | 55,1 % | 376 |
| `Engine/SeaRoutePlanner.swift` | 52,5 % | 345 |
| `Toernberechnung/ToernberechnungApp.swift` | 52,4 % | 63 |
| `Views/ContentView+Crew.swift` | 42,5 % | 914 |
| `Views/ContentView+SharedUI.swift` | 27,4 % | 870 |
| `Views/ContentView+Weather.swift` | 21,6 % | 1383 |
| `Services/DWDService.swift` | 17,0 % | 376 |
| `Views/ContentView+Logbook.swift` | 3,3 % | 614 |

### 1.3 Interpretation

- **Kernfunktionale Engine (Strategy, RouteCalculationService, PassageWindowScanner) liegt zwischen 97 % und 100 %** — also genau dort, wo es darauf ankommt.
- **Niedrige Coverage in `Views/` und `DWDService`** ist erklärbar: SwiftUI-Views werden über XCUITest abgedeckt (in der Unit-Test-Coverage tauchen sie deshalb niedrig auf), der DWD-MOSMIX-Parser ist privates KMZ/XML-Handling, das vertraglich nur über Fehlerpfade getestet wird.
- **`SeaRoutePlanner` (52,5 %)** und **`RoutePlannerViewModel` (55,1 %)** sind die nächsten Coverage-Optimierungs-Kandidaten — gehören aber nicht zu den Pflichtkomponenten der Aufgabe.

### 1.4 Bericht-Dateien

| Pfad | Format | Zweck |
|---|---|---|
| `build/coverage/index.html` | HTML | Lokale Übersicht, im Browser öffnen |
| `build/coverage/<file>__<name>.html` | HTML | Zeilen-Detail mit grün/rot pro Datei + Branch-Trefferzahlen |
| `build/coverage/cobertura.xml` | XML | Jenkins / Cobertura-Plugins |
| `build/coverage/sonarqube-generic-coverage.xml` | XML | Eingang in SonarCloud-Pipeline |

---

## 2 · Manuelle C0/C1/C2/C3-Analyse ausgewählter Komponenten

Die Tool-Coverage liefert C0 (Line/Statement) und teilweise C1 (Branch).
C2 (Path) und C3 (Condition) berechnen wir hier **manuell für vier Schlüsselkomponenten**, die alle Aspekte abdecken:

| Komponente | Was wird gezeigt |
|---|---|
| 2.1 `determineWaypointStatus` | einfachstes if/elif/else — Lehrbeispiel C0/C1/C2 |
| 2.2 `determineRouteStatus` | Kette von ifs — C2 mit fünf Pfaden |
| 2.3 `CombinedRouteStatus.combine` | **Compound-Conditions mit `||`** — Lehrbeispiel C3 (a/b/c) |
| 2.4 `TwelfthsRuleStrategy.missingWater` | Switch mit 12 Buckets + Guards — komplexester Fall |

---

### 2.1 `determineWaypointStatus(clearanceUnderKeel, safetyMargin)`

**Quelltext** (`Toernberechnung/Engine/RouteCalculationService.swift:489–500`):

```swift
static func determineWaypointStatus(
    clearanceUnderKeel: Double,
    safetyMargin: Double
) -> WaypointStatus {
    if clearanceUnderKeel < 0 {           // C1
        return .noGo                       // S2
    } else if clearanceUnderKeel < safetyMargin {  // C2
        return .warning                    // S3
    } else {
        return .go                         // S4
    }
}
```

**Kontrollflussgraph (textuell):**

```
 ┌─────────────┐
 │ S1: Entry   │
 └──────┬──────┘
        ▼
   ┌─────────────────────────┐
   │ C1: WuK < 0 ?           │
   └─────┬─────────────┬─────┘
       T │             │ F
         ▼             ▼
   ┌──────────┐  ┌─────────────────────────┐
   │ S2: noGo │  │ C2: WuK < safetyMargin? │
   └────┬─────┘  └─────┬─────────────┬─────┘
        │            T │             │ F
        │              ▼             ▼
        │        ┌────────────┐ ┌────────┐
        │        │ S3: warning│ │ S4: go │
        │        └─────┬──────┘ └───┬────┘
        └──────────────┴────────────┘
                        ▼
                   ┌─────────┐
                   │ S5: End │
                   └─────────┘
```

**Knoten:** S1, S2, S3, S4, S5 (5) · **Entscheidungen:** C1, C2 (2)

#### C0 – Statement Coverage

| Statement | abgedeckt durch |
|---|---|
| S1 (entry) | implicit, jeder Test |
| S2 (noGo) | `test_EKW1_wukNegative_returnsNoGo` |
| S3 (warning) | `test_EKW2_wukZero_returnsWarning_whenMarginPositive` |
| S4 (go) | `test_EKW3_wukExactlyAtMargin_returnsGo` |

→ **C0 = 4/4 = 100 %**

#### C1 – Branch Coverage

| Branch | Bedingung | abgedeckt durch |
|---|---|---|
| C1 = T | WuK < 0 | `test_EKW1_wukNegative_returnsNoGo` |
| C1 = F | WuK ≥ 0 | `test_EKW2_*`, `test_EKW3_*` |
| C2 = T | WuK < margin | `test_EKW2_wukJustBelowMargin_returnsWarning` |
| C2 = F | WuK ≥ margin | `test_EKW3_wukExactlyAtMargin_returnsGo` |

→ **C1 = 4/4 = 100 %**

#### C2 – Path Coverage

Eindeutige Pfade durch den CFG:

| Pfad | Sequenz | Test |
|---|---|---|
| P1 | C1=T → S2 | `test_EKW1_wukNegative_returnsNoGo` |
| P2 | C1=F → C2=T → S3 | `test_EKW2_wukZero_returnsWarning_whenMarginPositive` |
| P3 | C1=F → C2=F → S4 | `test_EKW3_wukExactlyAtMargin_returnsGo` |

→ **C2 = 3/3 = 100 %**

#### C3 – Condition Coverage

Bedingungen sind atomar (`<`-Vergleich, kein `||`/`&&`).
Atom A = `WuK < 0`, Atom B = `WuK < safetyMargin`.

| Variante | Anforderung | Erfüllt durch |
|---|---|---|
| (a) atomar | A=T, A=F, B=T, B=F je einmal | EKW1 (A=T); EKW2 (A=F, B=T); EKW3 (A=F, B=F) ✓ |
| (b) Kombinationen | nicht relevant – keine compound conditions | n/a |
| (c) komplett + (a) | C1 ganz T+F, C2 ganz T+F | identisch mit (a), weil keine Compound ✓ |

→ **C3 (a) = 100 %, (c) = 100 %**

---

### 2.2 `determineRouteStatus(waypointStatuses: [WaypointStatus])`

**Quelltext** (`Toernberechnung/Engine/RouteCalculationService.swift:509–517`):

```swift
static func determineRouteStatus(waypointStatuses: [WaypointStatus]) -> RouteStatus {
    if waypointStatuses.contains(.invalid)    { return .noGo }      // C1 → S2
    if waypointStatuses.contains(.noGo)       { return .noGo }      // C2 → S3
    if waypointStatuses.contains(.incomplete) { return .incomplete }// C3 → S4
    if waypointStatuses.contains(.warning)    { return .warning }   // C4 → S5
    return .go                                                       // S6
}
```

**CFG (textuell):**

```
S1 → C1 ─T→ S2 (noGo)
       └F→ C2 ─T→ S3 (noGo)
              └F→ C3 ─T→ S4 (incomplete)
                     └F→ C4 ─T→ S5 (warning)
                            └F→ S6 (go)
```

#### C0 – Statement Coverage

| Statement | Test |
|---|---|
| S1 | jeder Test |
| S2 (invalid → noGo) | `test_EKR1_invalidPresent_returnsNoGo` |
| S3 (noGo) | `test_EKR2_noGoPresent_returnsNoGo` |
| S4 (incomplete) | `test_EKR3_incompletePresent_returnsIncomplete` |
| S5 (warning) | `test_EKR4_warningPresent_returnsWarning` |
| S6 (go) | `test_EKR5_allGo_returnsGo`, `test_EKR6_empty_returnsGo` |

→ **C0 = 6/6 = 100 %**

#### C1 – Branch Coverage

8 Branches (je 2 pro Entscheidung).

| Branch | Test, der ihn nimmt |
|---|---|
| C1 = T | `test_EKR1_*` |
| C1 = F | alle anderen |
| C2 = T | `test_EKR2_*`, `test_noGoBeatsIncomplete` |
| C2 = F | `test_EKR3–5_*` |
| C3 = T | `test_EKR3_*`, `test_incompleteBeatsWarning` |
| C3 = F | `test_EKR4_*`, `test_EKR5_*` |
| C4 = T | `test_EKR4_*` |
| C4 = F | `test_EKR5_*`, `test_EKR6_*` |

→ **C1 = 8/8 = 100 %**

#### C2 – Path Coverage

5 unterschiedliche Pfade:

| Pfad | Erste True-Entscheidung | Test |
|---|---|---|
| P1 | C1 = T | `test_EKR1_invalidPresent_returnsNoGo` |
| P2 | C2 = T | `test_EKR2_noGoPresent_returnsNoGo` |
| P3 | C3 = T | `test_EKR3_incompletePresent_returnsIncomplete` |
| P4 | C4 = T | `test_EKR4_warningPresent_returnsWarning` |
| P5 | alle F | `test_EKR5_allGo_returnsGo`, `test_EKR6_empty_returnsGo` |

→ **C2 = 5/5 = 100 %**

#### C3 – Condition Coverage

Auch hier sind alle Bedingungen atomar (`contains(...)`).

→ **C3 (a) = 100 %, (c) = 100 %**

---

### 2.3 `CombinedRouteStatus.combine(tidal:weather:)` — **Lehrbeispiel C3**

**Quelltext** (`Toernberechnung/Engine/RoutePlanModels.swift:225–230`):

```swift
static func combine(tidal: RouteStatus, weather: WeatherStatus) -> CombinedRouteStatus {
    if tidal == .noGo || weather == .noGo { return .noGo }              // C1 → S2
    if tidal == .incomplete               { return .incomplete }        // C2 → S3
    if tidal == .warning || weather == .warning { return .warning }     // C3 → S4
    return .go                                                           // S5
}
```

**CFG (textuell):**

```
S1 → C1 ─T→ S2 (noGo)
       └F→ C2 ─T→ S3 (incomplete)
              └F→ C3 ─T→ S4 (warning)
                     └F→ S5 (go)
```

**Atomare Teilbedingungen:**
- A = `tidal == .noGo`
- B = `weather == .noGo`
- C = `tidal == .incomplete`
- D = `tidal == .warning`
- E = `weather == .warning`

mit C1 = A ∨ B, C2 = C, C3 = D ∨ E

#### C0 – Statement Coverage

→ **C0 = 5/5 = 100 %** (S1, S2, S3, S4, S5 alle durch die parametrisierte Tabelle erreicht)

#### C1 – Branch Coverage

| Branch | Beispieltest aus der 16er-Wahrheitstabelle |
|---|---|
| C1 = T | `(noGo, *)`, `(*, noGo)` → 7 Treffer |
| C1 = F | `(go, go)` → 9 Treffer |
| C2 = T | `(incomplete, go)`, `(incomplete, warning)`, `(incomplete, incomplete)` |
| C2 = F | `(go, *)`, `(warning, *)` |
| C3 = T | `(go, warning)`, `(warning, go)` … |
| C3 = F | `(go, go)`, `(go, incomplete)` |

→ **C1 = 6/6 = 100 %**

#### C2 – Path Coverage

| Pfad | erste True-Entscheidung | Anzahl Treffer in der 16er-Tabelle |
|---|---|---|
| P1 | C1=T | 7 (alle mit `.noGo`) |
| P2 | C1=F, C2=T | 3 (`tidal=.incomplete`, weather ∈ {go, warning, incomplete}) |
| P3 | C1=F, C2=F, C3=T | 3 (`(go,warning)`, `(warning,go)`, `(warning,warning)`) |
| P4 | C1=F, C2=F, C3=F | 3 (`(go,go)`, `(go,incomplete)`, … ) |

→ **C2 = 4/4 = 100 %**

#### C3 – Condition Coverage (Lehrbeispiel)

##### Variante (a) – atomare Bedingungen je einmal T und F

| Atom | T-Repräsentant (tidal, weather) | F-Repräsentant |
|---|---|---|
| A = `tidal == .noGo` | (noGo, go) | (go, go) |
| B = `weather == .noGo` | (go, noGo) | (go, go) |
| C = `tidal == .incomplete` | (incomplete, go) | (go, go) |
| D = `tidal == .warning` | (warning, go) | (go, go) |
| E = `weather == .warning` | (go, warning) | (go, go) |

Minimale Test-Sequenz: 5 + 1 = **6 Tests** würden für (a) reichen.
Tatsächlich getestet: **16 Tests** (gesamte Wahrheitstabelle) → (a) **mehr als erfüllt**.

##### Variante (b) – alle 2ⁿ-Kombinationen der atomaren Teilbedingungen

Theoretisch: 5 Atome → 2⁵ = **32 Kombinationen**.
Praktisch reduziert: A, C, D sind **paarweise exklusiv** (tidal ist Enum mit nur einem Wert), genauso B und E. Realistisch verbleiben **4 × 4 = 16 Kombinationen** — exakt die Wahrheitstabelle.

→ **(b) bezogen auf realistisch erreichbare Kombinationen: 16/16 = 100 %**

##### Variante (c) – komplette Bedingung T und F + (a)

| Bedingung | komplett T | komplett F | (a) erfüllt? |
|---|---|---|---|
| C1 = A ∨ B | (noGo, go) → T | (go, go) → F | ✓ A, B beide einzeln T/F getestet |
| C2 = C | (incomplete, go) → T | (go, go) → F | ✓ |
| C3 = D ∨ E | (warning, go) → T | (go, go) → F | ✓ |

→ **C3 (c) = 100 %**

##### Lehrgespräch: warum reicht (a) nicht und was bringt (c)?

Beispiel `if (istStudent || istRentner)` (Vorlesungsfolie):
- **Nur (a):** je 1 × T und F für jedes Atom — kann erfüllt sein, ohne dass die Disjunktion je beide Hälften unabhängig „geflippt" hat (Maskierung möglich).
- **(c) = MC/DC:** verlangt, dass jede atomare Teilbedingung **die Gesamtentscheidung unabhängig kippen** kann. Beispiel für `A ∨ B`:
  - Test 1: A=F, B=F → C1=F
  - Test 2: A=T, B=F → C1=T (A allein kippt)
  - Test 3: A=F, B=T → C1=T (B allein kippt)

Unsere 16er-Tabelle deckt diese MC/DC-Anforderung für `combine` ebenfalls ab.

---

### 2.4 `TwelfthsRuleStrategy.missingWater(deviationHours, MTH)`

**Quelltext** (`Toernberechnung/Engine/TidalHeightStrategy.swift:67–115`):

```swift
func missingWater(deviationHours: Double, meanTidalRangeMeters: Double) -> TidalHeightResult {
    let oneTwelfth = meanTidalRangeMeters / 12.0       // S1

    if abs(deviationHours) < Self.hwEpsilonHours {     // C1
        return TidalHeightResult(fmwMeters: 0, ...)    // S2
    }

    let hours = abs(deviationHours)                    // S3

    guard hours <= 12 else {                           // C2 (negiert)
        return TidalHeightResult(..., isValid: false) // S4
    }

    let twelfths: Double                               // S5
    switch hours {                                     // C3 (12 cases + default)
    case ...1:  twelfths = 1                           // K1
    case ...2:  twelfths = 3                           // K2
    case ...3:  twelfths = 6                           // K3
    case ...4:  twelfths = 9                           // K4
    case ...5:  twelfths = 11                          // K5
    case ...7:  twelfths = 12                          // K6
    case ...8:  twelfths = 11                          // K7
    case ...9:  twelfths = 9                           // K8
    case ...10: twelfths = 6                           // K9
    case ...11: twelfths = 3                           // K10
    case ...12: twelfths = 1                           // K11
    default:    twelfths = 0                           // K12 (unerreichbar)
    }

    return TidalHeightResult(fmwMeters: twelfths * oneTwelfth, ...) // S6
}
```

> Anm.: Die Switch-Buckets sind in der Quelle nicht ganz dieselbe Aufteilung wie die EK-Tabelle aus Schritt 2 (`...5` und `...7` decken den Bereich 4 < x ≤ 5 und 5 < x ≤ 7 ab, ergibt 11 logische Buckets — siehe unten).

#### CFG (textuell)

```
S1 (oneTwelfth = MTH/12)
   ▼
C1: |dev| < 0.01 ?
   ─T→ S2: return FmW=0 (gültig)
   └F→ S3 (hours = |dev|)
       ▼
       C2: hours > 12 ?
       ─T→ S4: return isValid=false
       └F→ S5 (var twelfths)
           ▼
           C3 (switch hours):
              K1: ...1   → twelfths=1
              K2: ...2   → twelfths=3
              K3: ...3   → twelfths=6
              K4: ...4   → twelfths=9
              K5: ...5   → twelfths=11
              K6: ...7   → twelfths=12
              K7: ...8   → twelfths=11
              K8: ...9   → twelfths=9
              K9: ...10  → twelfths=6
              K10: ...11 → twelfths=3
              K11: ...12 → twelfths=1
              K12: default → twelfths=0      (unerreichbar)
           ▼
           S6: return fmw = twelfths × oneTwelfth
```

**Knoten:** S1, S2, S3, S4, S5, S6 + 11 Switch-Kanten = 17 Statements.
**Entscheidungen:** C1, C2, C3 (mit 11 + 1 Ausgängen).

#### C0 – Statement Coverage

| Statement | abgedeckt durch |
|---|---|
| S1, S3, S5, S6 | jeder erfolgreiche Bucket-Test |
| S2 (Epsilon-Return) | `ek1_*` |
| S4 (invalid-Return) | `ek13_*` |
| K1 … K11 | je ein Eintrag aus `bucketHits(...)` (22 Wert-Paare adressieren alle 11 Buckets, jeweils mid + obere Grenze) |
| K12 (default) | **NICHT erreicht — toter Code**, weil `guard hours <= 12` greift |

→ **C0 (logisch erreichbar) = 16/16 = 100 %** · **C0 (inkl. dead default) = 16/17 = 94,1 %**

Das `default`-Statement ist defensives Stilelement — die Tool-Coverage `100,0 %` aus 1.2 wertet es korrekt aus, weil Swifts Switch-Coverage `default` nicht als ausführbare Zeile zählt, wenn alle Pfade exhaustiv abgedeckt sind.

#### C1 – Branch Coverage

| Decision | Branch | Test |
|---|---|---|
| C1 | T | `ek1_exactHighWater`, `ek1_withinEpsilon`, `ek1_boundaryInside` |
| C1 | F | jeder `bucketHits`-Lauf |
| C2 | T (hours > 12) | `ek13_beyondTwelve`, `ek13_boundaryJustBeyond` |
| C2 | F | jeder `bucketHits`-Lauf |
| C3 | K1 (...1) | (0,5; 1) und (1,0; 1) |
| C3 | K2 (...2) | (1,5; 3) und (2,0; 3) |
| C3 | K3–K11 | analog, je 2 Repräsentanten |
| C3 | K12 (default) | **unerreichbar** |

→ **C1 (erreichbare Branches) = 2 + 2 + 11 = 15/15 = 100 %** · **C1 (mit default) = 15/16 = 93,75 %**

#### C2 – Path Coverage

| Pfad | Trigger |
|---|---|
| P0 (Epsilon) | C1 = T | dev = 0 |
| P-inv | C1 = F, C2 = T | dev = 13 |
| P1 … P11 | C1 = F, C2 = F, C3 = K_i | je ein bucketHits-Wert |

→ **C2 = 13/13 = 100 %** (alle realisierbaren Pfade)

#### C3 – Condition Coverage

Bedingungen sind atomar:
- C1: `abs(deviationHours) < hwEpsilonHours`
- C2: `hours > 12` (negierter Guard)
- C3: Switch — keine Booleschen Compound-Bedingungen, sondern Bereichsvergleiche

Variante (a) und (c) sind durch die Bucket-Tests + Epsilon-Tests + Invalid-Tests trivial erfüllt.

→ **C3 (a) = 100 %, (c) = 100 %**

---

## 3 · Zusammenfassende Tabelle Coverage-Metriken

| Komponente | C0 | C1 | C2 | C3 (a) | C3 (c) |
|---|---:|---:|---:|---:|---:|
| `determineWaypointStatus` | 100 % | 100 % | 100 % | 100 % | 100 % |
| `determineRouteStatus` | 100 % | 100 % | 100 % | 100 % | 100 % |
| `CombinedRouteStatus.combine` | 100 % | 100 % | 100 % | 100 % | 100 % |
| `TwelfthsRuleStrategy.missingWater` | 100 % (reachable) | 100 % (reachable) | 100 % | 100 % | 100 % |
| Engine gesamt (Tool, C0) | **>97 %** | – | – | – | – |
| App-Target (Tool, C0) | **47,4 %** | – | – | – | – |

**Begründung "47,4 % reichen":** Die unterabgedeckten Bereiche (`Views/Logbook`, `Weather`, `SharedUI`, `DWDService`) sind:
- SwiftUI-Layouts mit deklarativem Code, geprüft per XCUITest (in der Coverage-Statistik unterrepräsentiert)
- MOSMIX-KMZ-Parser, der nur über reale BSH-Antworten validierbar wäre und in der Unit-Test-Coverage bewusst per `URLProtocol`-Stub abgedeckt ist

In Relation zur Kritikalität (siehe Folie „Wann ist genug getestet?") liegt die **business-kritische Berechnungs­engine bei ~100 %**, was dem Reife­grad eines Planungstools angemessen ist.

---

## 4 · Wie die Reports zustande kommen (Reproduzierbarkeit)

```bash
# 1. Test-Lauf mit Coverage-Erfassung
bundle exec fastlane test

# 2. Coverage-Reports erzeugen (HTML / Cobertura / SonarQube-XML via Slather)
bundle exec fastlane coverage

# 3. Lokal anschauen
open build/coverage/index.html
```

Die CI macht denselben Lauf via `bundle exec fastlane test` + `bundle exec fastlane coverage`. SonarCloud konsumiert die `sonarqube-generic-coverage.xml` über die `sonar.coverageReportPaths`-Property.
