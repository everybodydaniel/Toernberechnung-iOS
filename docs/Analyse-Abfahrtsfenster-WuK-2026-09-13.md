# Analyse: Abfahrtsfenster, WuK und Datenhorizonte

Analyse begonnen am 13. September 2026, Umsetzung und Verifikation aktualisiert am 15. September 2026. Untersucht wurden der damalige iOS-Quellstand, das bereitgestellte Android-Projekt, beide Seiten der PDF und die genannten Wattsegler-Seiten. BSH-Gezeiten und Wasserstandsvorhersage wurden zusätzlich live abgerufen. Die im Ausgangsstand gefundenen Fehler sind unten dokumentiert; Abschnitt 7 beschreibt den jetzt umgesetzten Stand.

## Ergebnis

Die Grundgleichung des Wassers unter dem Kiel war im Ausgangsstand richtig, ihre Daten- und Fensterlogik jedoch nicht durchgängig belastbar. Nachgewiesen wurden Fehler bei Sicherheitsreserve, unvollständigen Wegepunkten, Tages-/Tidenabdeckung und zeitlicher Gültigkeit von Prognosen. Hinzu kamen nicht ausreichend belegte Tiefendaten und eine Mittelwasser-Näherung, die vorhandene individuelle Tidehöhen nicht verwendete. Diese Punkte sind jetzt im Rechenkern, in der Tagesauswahl und in der Ergebnisanzeige korrigiert; Lotungsalter, Prognosehorizont und Nachbarpegel bleiben sichtbar als Qualitätsgrenzen erhalten.

Android enthält den besseren Ansatz für mehrere Abfahrtsfenster und eine kontinuierliche Tideinterpolation. Es ist jedoch keine fehlerfreie Referenz: Es verwendet vor allem kurzfristige prognostizierte Ereignisse, enthält vereinfachte Strömungsannahmen und stuft berechnete Werte zu großzügig als lokale amtliche Daten ein.

Eine Planung für den 20. September, also eine Woche nach dem Untersuchungstag, ist mit den vorhandenen astronomischen BSH-Daten grundsätzlich möglich. Eine vollständige meteorologische Wasserstandsvorhersage für diesen Tag liegt im untersuchten Datensatz noch nicht vor. Dies sind verschiedene Datenprodukte und müssen getrennte Zustände bekommen.

## 1. Fachliches Rechenmodell

Für einen Ort und einen Zeitpunkt gilt:

```text
WuK = tatsächliche Wassertiefe − Tiefgang
Reserve erfüllt ⇔ WuK ≥ eingestellte Sicherheitsreserve
```

WuK sollte den tatsächlichen Abstand unter dem Kiel darstellen. Die Sicherheitsreserve wird beim Vergleich verwendet, nicht stillschweigend ein zweites Mal von der angezeigten WuK abgezogen.

Es gibt zwei unterschiedliche Tiefenbezüge:

```text
A: Kartentiefe mit Bezug auf SKN
Wassertiefe(t) = Kartentiefe_SKN + Wasserstand_über_SKN(t)

B: Wattsegler-Lottiefe bei mittlerem Hochwasser
Wassertiefe(t) = Lottiefe_MHW + Wasserstand_über_SKN(t) − MHW_über_SKN
```

Die Größen in B müssen denselben örtlichen Bezug haben. Ein entfernter Pegel darf nur mit einem geeigneten Übertragungsmodell verwendet werden. Eine Lottiefe bei MHW enthält den Boden bereits; zusätzliche Kartentiefe wäre eine Doppelzählung. Trockenfallende Höhe über SKN entspricht einer negativen Kartentiefe in der hier verwendeten Vorzeichenkonvention.

Die aktuelle iOS-Näherung lautet:

```text
FmW = Anteil aus Zwölftelregel × mittlerer Tidenhub
Kartentiefenmodus: WT = MHW − FmW + Korrektur + Kartentiefe
Lottiefenmodus:    WT = Lottiefe_MHW − FmW + Korrektur
WuK = WT − Tiefgang
```

`WaypointDepthSolver.swift:79` setzt diese zwei Ketten korrekt auseinander. Die PDF bestätigt insbesondere den MHW-Bezug der Lotungen und das Weglassen der zusätzlichen Kartentiefe. Die PDF ist eine Erläuterung, keine mitgelieferte Excel-Arbeitsmappe: Die behauptete vollständige Zellformel-Parität lässt sich damit allein nicht beweisen. Ihr Hinweis, Tageswechsel seien nicht vorgesehen, beschreibt eine Grenze des alten Tools; er ist keine Anforderung an die App. Die Division der Fahrzeit durch 24 ist die Excel-Darstellung als Tagesbruchteil. Die App rechnet sinnvollerweise Stunden als Seemeilen/Knoten.

Quelle: bereitgestellte PDF, Seiten 1–2; [Wattsegler-Erklärung](https://www.wattsegler.de/?view=article&id=3621:berechnung-der-wassertiefe&catid=117:lottiefen-a-mehr.).

## 2. Nachgewiesene iOS-Fehler im Ausgangsstand

### 2.1 Sicherheitsreserve fehlt in der Fenstersuche

`PassageWindowSolver.swift:204` nimmt `safetyMarginMeters` entgegen, benutzt den Wert aber nicht. Die Fensterprüfung verwendet WuK ≥ 0; auch `WaypointTideContext.missingWaterBudgetMeters` zieht nur den Tiefgang ab. Die separate Routenbewertung berücksichtigt dagegen die Reserve (`RouteCalculationService.swift:303`).

Ausgeführter Reproduktionsfall mit unverändertem Swift-Kern: Lottiefe 1,45 m, Tiefgang 1,10 m, MTH 2,40 m. Bei einer Stunde Abstand zum HW bleiben 0,15 m WuK. Mit 0,30 m Reserve darf diese Zeit nicht enthalten sein. Die Fenstersuche liefert mit 0,00 und 0,30 m Reserve trotzdem dasselbe Fenster.

Folge: Die Beschriftung „Sicheres Abfahrtsfenster“ kann einem Zeitpunkt gelten, der die eingestellte Reserve unterschreitet.

### 2.2 Fehlende Wegepunkte werden aus der Prüfung entfernt

`WaypointTideContext.resolve` liefert bei fehlender Tiefe, MTH oder HW `nil`. `PassageWindowSolver.swift:193` verwirft diese Ergebnisse. Anschließend wird nur geprüft, ob überhaupt ein Kontext vorhanden ist, nicht ob alle erforderlichen Wegepunkte abgedeckt sind.

Ausgeführter Reproduktionsfall: Zwei Wegepunkte, beim zweiten fehlt die Lottiefe. Ergebnis: ein berechnetes Routenfenster, aber nur einer von zwei Punkten ausgewertet.

Zusätzlich erzeugt ein nicht berechenbarer WuK bei einem bereits vorhandenen Kontext `shortfall = 0`; `isPassableAtPlannedTime` kann so fehlende Werte als passierbar behandeln. Im Kartentiefenmodus setzt die Budgetrechnung eine fehlende Kartentiefe außerdem auf null, während die eigentliche Tiefenrechnung sie ablehnt.

Erforderlich: Fehlende Daten müssen explizit erhalten bleiben. Eine unvollständig geprüfte Strecke darf kein vollständig bestätigtes Fenster erhalten.

### 2.3 Nur ein ausgewähltes Hochwasser pro Wegepunkt

`passableArrivalWindow` wählt das zum bisherigen Ankunftszeitpunkt nächstgelegene HW und berechnet nur dessen Fenster. Die Schnittmenge entsteht aus genau diesen Einzelintervallen. `Solution` und ViewModel speichern nur ein Routenfenster.

Das ist nicht die Suche nach allen Abfahrten eines Tages. Weitere Tiden werden nicht systematisch berücksichtigt. Verschiedene Wegepunkte können zudem unpassend verschiedenen Zyklen zugeordnet werden. Ein leeres Ergebnis beweist deshalb nicht, dass an diesem Tag keine passende Abfahrt existiert.

Ausgeführter Reproduktionsfall: Zwei identische flache Wegepunkte ohne Fahrzeit, zwei HW-Ereignisse im Abstand von 12,4 Stunden. Das zweite ebenfalls befahrbare HW liegt innerhalb des Suchbereichs, erscheint aber nicht im Ergebnis.

### 2.4 Zeitbereich der Daten kleiner als Zeitbereich der Suche

Die Suche läuft standardmäßig von ausgewählter Abfahrt minus 12 Stunden bis plus 24 Stunden. Die Kontexte fordern HW-Daten einmal um den Mittelpunkt an; `BSHTideService.swift:213` liefert jedoch nur ±14 Stunden. Das deckt bereits den 36-stündigen Suchbereich nicht vollständig ab. Für Tideinterpolation wären zusätzlich die angrenzenden HW/NW außerhalb der Randzeiten nötig.

### 2.5 Prognosequalität gilt fälschlich unabhängig vom Zeitpunkt

`WaterLevelCorrectionSeries.swift:48` liefert außerhalb der Kurve einen konstanten Ersatzwert mit unveränderter Qualität. Eine ursprünglich lokal amtliche Korrektur bleibt dadurch auch außerhalb ihrer zeitlichen Abdeckung `localOfficial`.

Ausgeführter Reproduktionsfall: Kurve von HW bis HW+1 h, Abfrage bei HW+12,4 h. Ergebnis: weiterhin `localOfficial`, 0,30 m Ersatzwert. Außerdem verwendet die Serie dieselbe Unsicherheit eines einzigen HW-Ereignisses für den gesamten Zeitraum, einschließlich weiterer Tiden.

Erforderlich: Qualität und Unsicherheit müssen vom abgefragten Zeitpunkt und verwendeten Produkt abhängen. Keine Fortschreibung positiver Wasserstandskorrekturen als bestätigte Prognose.

### 2.6 Einzelberechnung und Fenstersuche wählen HW unterschiedlich

`RouteCalculationService.swift:185` wählt erst das nächstgelegene Referenz-HW und addiert anschließend den örtlichen HW-Versatz. `WaypointTideContext` verschiebt dagegen alle HW-Ereignisse und sucht dann das nächste örtliche HW. Nahe der Grenze zwischen zwei Tiden können unterschiedliche Ereignisse gewählt werden. Der gemeinsame Tiefensolver verhindert diese vorgelagerte Abweichung nicht.

### 2.7 WuK-Sprung durch diskrete Stundenklassen

`TwelfthsRuleStrategy` ist eine Treppenfunktion. Ausgeführter Fall bei MTH 3,00 m: FmW nach genau einer Stunde = 0,25 m; eine Sekunde später = 0,75 m. Das ist kein physischer Wasserstandsverlauf. Fenstergrenzen sind dadurch grob quantisiert. Die Sonderbehandlung rund um exaktes HW umfasst zudem 36 Sekunden.

Die Fortsetzung der Staffel bis 12 Stunden simuliert bei großem Abstand wieder steigendes Wasser, ohne ein tatsächlich verfügbares nächstes HW zu benötigen. Fehlende Nachbarereignisse sollten stattdessen eine Datenlücke erzeugen.

## 3. Warum der WuK im Ausgangsstand trotz richtiger Grundgleichung abweichen konnte

### Individuelle Tidehöhen bleiben ungenutzt

Der BSH-Parser liest Ereignishöhen und Tidephase ein. Der Rechenkern verwendet jedoch nur HW-Zeitpunkte, mittlere Hochwasserhöhe und mittleren Tidenhub. Die neue Route erhält sogar fest die Beschriftung „Mitteltide“ (`RoutePlannerViewModel.swift:369`).

Live-Beispiel Norderney, 20.09.2026: MHW 6,26 m über Pegelnull, SKN 3,16 m über Pegelnull, also MHW = 3,10 m über SKN. Die beiden vorausberechneten HW liegen bei 6,01 und 5,82 m über Pegelnull, entsprechend 2,85 und 2,66 m über SKN. Die Mittelwertbasis liegt an diesen HW also 25 bzw. 44 cm über der tatsächlichen astronomischen Vorausberechnung.

Die automatische iOS-Korrektur ist Prognose minus astronomische Vorausberechnung minus Unsicherheit. Sie ergänzt daher den meteorologischen Anteil, aber nicht den Unterschied zwischen individuellem HW und MHW. Dieser astronomische Unterschied bleibt in der aktuellen Rechenkette unberücksichtigt. Eine manuelle Korrektur könnte ihn enthalten; deren fachlicher Bezug muss dann ausdrücklich definiert sein.

Quelle: [BSH-Jahresdaten Norderney](https://gezeiten.bsh.de/data/DE__111P_tides.json), live gelesen am 13.09.2026. Zeitstempel tragen eigene UTC-Offsets; für die Anzeige ist nach Europe/Berlin umzurechnen, nicht lediglich die Uhrzeitzeichenfolge zu übernehmen.

### Tiefenkatalog ist nicht gleich aktuelle Wattsegler-Lotung

Die normale Planung baut Hafentemplates und anschließend Knoten aus `NauticalRouter` ein. Es gibt keinen gefundenen automatischen Import der aktuellen Wattsegler-Lotungen. Der statische JSON-Katalog enthält überwiegend Planungswerte; die Routingknoten tragen weder belastbares Lotdatum noch eindeutige Herkunft pro Tiefe.

Besonders kritisch: `NauticalRouter.swift:24` beschreibt `chartDepth` als Tiefe bei MHW, während `RouteExpander.swift:137` sie ausdrücklich als Kartentiefe im MHW-Modus übergibt. Wenn die Dokumentation stimmt, wird Wasser doppelt addiert. Die Zahlen und negativen Werte allein beweisen ihren tatsächlichen Ursprung nicht. Deshalb ist dies ein belegter Widerspruch im Datenvertrag, noch kein Beweis, dass jeder einzelne Knoten doppelt gerechnet wird. Jeden Wert als MHW-Lotung umzudeuten wäre ebenfalls falsch.

Wattsegler listet beispielsweise Juist-Zufahrt mit 1,90 m bei MHW, Norderneyer Wattfahrwasser mit 1,90 m und Baltrumer Wattfahrwasser mit 1,60 m, jeweils 08.2026. Solche Abschnittslotungen dürfen nicht ohne räumliche Zuordnung auf beliebige Hafen- oder Routingpunkte übertragen werden. Auch Einschränkungen wie das nicht durchgängig passierbare Harlesieler Wattfahrwasser sind keine bloßen Tiefenzahlen.

Quelle: [Wattsegler-Lotungen](https://www.wattsegler.de/lotungen.html), Seitenstand 31.08.2026.

### Laufzeit, Strom und Anzeige

Fahrzeit = Entfernung / Geschwindigkeit über Grund ist korrekt. In der normalen iOS-Routenerstellung wird Strom aber auf null gesetzt. Der Rechenkern erlaubt eine konstante additive Stromkomponente; er integriert keine zeit- und ortsabhängige Strömung. Ein um eine Stunde verschobener Start kann real eine andere Fahrtzeit erzeugen.

Die Routenexpansion bewertet diskrete Knoten; das garantiert ohne passende Abschnittstiefen nicht, dass jede Untiefe zwischen den Knoten abgedeckt ist. Die Engstelle des Fensters wird anhand des WuK zur zuvor eingestellten Abfahrt benannt, nicht anhand der tatsächlich begrenzenden Fensterkante.

Der große WuK-Wert stammt ebenfalls aus der Berechnung zur eingestellten Abfahrt. Er ist kein WuK für eine automatisch empfohlene Abfahrt im gefundenen Fenster. Das erklärt einen Teil der wahrgenommenen Widersprüche.

## 4. Tatsächliche Datenhorizonte

| Datenprodukt | Live-Befund / verifizierte Fähigkeit | Konsequenz |
|---|---|---|
| Astronomische Gezeiten Norderney | 1.411 HW/NW-Ereignisse für 2026, 1.410 für 2027 | Eine Woche Vorlauf ist abgedeckt. Nicht auf alle Stationen ohne Prüfung verallgemeinern. |
| Kurzfristige Scheitelprognosen | `forecast_value` und `forecast_uncertainty` bei vier Ereignissen bis 14.09.2026, 14:20 MESZ | Der im Ausgangsstand verwendete strenge Korrekturpfad hatte einen sehr kurzen Horizont. |
| Automatische BSH-Kurve | `automated_curve_forecast` bis 19.09.2026, 13:00 MESZ | Mehrtägige Modellwerte sind vorhanden, benötigen eine eigene Qualitäts-/Unsicherheitsbehandlung. |
| BSH-MOS-Ereignisfelder | `mos_forecast_r0_value` und weitere Läufe bis 19.09.2026 | Parser ignoriert diese Felder. Ihre Produktsemantik muss vor Nutzung anhand der BSH-Dokumentation geprüft werden. |
| WeatherKit | Apple dokumentiert zehn Tage stündliche Vorhersagen | Wetterplanung für +7 Tage grundsätzlich möglich. |

Die überarbeitete iOS-Serie nutzt die automatische Kurve zeitabhängig. Weil diese Kurve keine punktweise konservative Untergrenze mitliefert, wird positiver Modell-Windstau nicht als zusätzliche Tiefe gutgeschrieben; negativer Windstau wird abgezogen. Außerhalb der tatsächlich gelieferten Kurve wird ausdrücklich „nur astronomisch“ gerechnet und die Qualität als vorläufig angezeigt.

Für den 20.09. reichte die am 13.09. untersuchte meteorologische BSH-Vorhersage noch nicht. Die überarbeitete App plant in diesem Fall astronomisch weiter und kennzeichnet die fehlende meteorologische Korrektur. Null ist damit eine offen ausgewiesene Szenarioannahme und keine bestätigte Wetterwirkung.

Die Wetter-Routenabfrage fordert jetzt ausschließlich die 48 stündlichen Werte **ab der gewählten Abfahrt** an. Sie verlangt für einen zukünftigen Törn nicht zusätzlich aktuelle Bedingungen, die den gesamten Abruf zuvor scheitern lassen konnten. Der allgemeine Hafenbericht fragt weiterhin ab jetzt an. Die +7-Tage-Abfrage ist mit einem kontrollierten WeatherKit-Client als Regressionstest geprüft; ein Liveabruf mit dem App-Entitlement wurde nicht ausgeführt.

Quellen: [BSH-Wasserstandsdatensatz Norderney](https://gdi.bsh.de/ldproxy/rest/services/WaterLevelForecast/collections/waterlevelforecastdata/items/norderney_riffgat?f=json), [Apple WeatherKit](https://developer.apple.com/weatherkit/).

## 5. Android-Vergleich

| Aspekt | Android-Befund | Bewertung |
|---|---|---|
| Fenster | `findSafeWindows` prüft Abfahrtskandidaten und liefert mehrere Intervalle | Geeigneter Ausgangspunkt für Tagesplanung. |
| Vollständigkeit | Erwartete Punktzahl und valide Tiefen erforderlich | Besser als aktuelles iOS-Verwerfen fehlender Kontexte. |
| Reserve | WuK ≥ Reserve minus 1 cm | Reserve berücksichtigt; 1 cm ist fachliche Toleranz, kein notwendiger Gleitkommafehlerausgleich. |
| Tidekurve | Kontinuierliche Zwölftelinterpolation zwischen benachbarten HW/NW, auf tatsächliche Dauer skaliert | Besser als starre Stundenklassen, weiterhin Näherung. |
| Datenbasis | Mapper übernimmt `forecastValue`, nicht Jahresvorausberechnungen | Löst die langfristige Planung nicht. |
| Datenqualität | Bei vorhandener Station, Tiefe und Tide pauschal `LOCAL_OFFICIAL` | Herkunft, Alter, örtliche Übertragung und Modellannahmen werden nicht hinreichend abgebildet. |
| Höhenbezug | Pegelnull → SKN wird grundsätzlich umgerechnet; fehlender Offset fällt auf 0 zurück | Fehlender Bezug darf nicht als bekannter Nullwert behandelt werden. |
| Manuelle Korrektur | Wird zu bereits prognostizierten Tidehöhen addiert | Bei erneutem Eintragen des Windstaus droht Doppelzählung; Bedeutung muss klar sein. |
| Strom | Sinusmodell mit maximal 2,5 kn, fester Ost-/Westachse | Im Code ausdrücklich Platzhalter, keine belastbare lokale Stromprognose. |
| Gegenstrom | SOG wird für Fahrzeit mindestens auf 0,1 kn gesetzt | Nicht fortkommendes Boot wird nicht konsequent als unmöglicher Fahrtabschnitt behandelt. |
| Wetter | Starker Wind sperrt Kandidaten; fehlendes Wetter allein sperrt sie nicht | Vorläufiges Tiefenfenster denkbar, aber kein umfassend bestätigtes sicheres Fenster. |

Weitere Grenzen: Zehn-Minuten-Raster kann schmale Fenster übersehen oder kurze Sperren zwischen Proben überbrücken. Die Zusammenführung von Fenstern kann bei Austausch des repräsentativen Kandidaten vorherige schlechtere Qualitätswerte verlieren. Die Tideinterpolation benutzt `LocalDateTime` und verliert dadurch die echte Zeitdauer bei Sommerzeitwechseln. Der lokale Datenbankrückweg rekonstruiert Stationen ohne Gezeitenereignisse.

Wichtige Android-Dateien unter dem bereitgestellten Projekt: `mapplanning/PassageWindowScanner.kt`, `mapplanning/AndroidRouteAssessmentProvider.kt`, `logic/RuleOfTwelfths.kt`, `tides/TideStationExtensions.kt`, `model/MappingExtensions.kt`, `mapplanning/SimpleTidalCurrentProvider.kt`.

## 6. Zielmodell für die zentrale Funktion

Die Eingabe ist der **Abfahrtstag**, die Ausgabe sind **alle berechenbaren Abfahrtsfenster dieses Tages**. Intern bleibt für jede geprüfte Abfahrt ein exakter Zeitstempel notwendig.

1. Den lokalen Kalendertag in Europe/Berlin bestimmen: Tagesbeginn bis nächster Tagesbeginn, exklusiv. Keine pauschalen 24 Stunden an Tagen mit Zeitumstellung.
2. Dieselbe tatsächlich dargestellte Fahrroute mit zugeordneten Engstellen, Abschnittstiefen, Quellen und Bezugssystemen verwenden.
3. Tideereignisse/-kurven für den gesamten Tag zuzüglich maximaler Fahrtzeit und angrenzender Tiden laden. Die Ankunft darf am Folgetag liegen.
4. Für jeden Abfahrtskandidaten die Ankunftszeiten entlang der Route berechnen. Bei zeitabhängigem Strom muss dies pro Kandidat erfolgen; nur bei konstanter Fahrtzeit ist bloßes Verschieben lokaler Fenster korrekt.
5. An jeder relevanten Position WuK und Datenqualität für die konkrete Ankunft berechnen. Alle Stellen müssen die Reserve erfüllen. Fehlende Bodentiefe oder fehlende astronomische Tide sind nicht durch einen Nullwert ersetzbar.
6. Alle zusammenhängenden geeigneten Abfahrtsintervalle bestimmen und Grenzen verfeinern. Netzwerkzugriffe bleiben außerhalb der Kandidatenschleife. Bei diskreten Modellen müssen Sprungstellen berücksichtigt werden; bloßes grobes Sampling beweist keine lückenlose Passierbarkeit.
7. Pro Fenster früheste/späteste Abfahrt, Engstelle, Passagezeit, geringsten WuK, Ankunft und Qualitätsstatus anzeigen. Eine empfohlene Abfahrt kann die kleinste Reserve entlang der Route maximieren; bei Gleichstand z.B. die frühere Zeit wählen. Das ist eine zu definierende Produktregel.
8. Bei Auswahl einer empfohlenen Abfahrt WuK, ETAs und Wetter gemeinsam neu auf diesen Zeitpunkt beziehen.

Empfohlene Zustände: „Abfahrtsfenster“, „Vorläufig – nur astronomisch“, „Automatische Wasserstandsprognose“, „Mit kurzfristiger lokaler Prognose“, „Daten unvollständig“, „Kein Fenster mit ausreichender Reserve“. Nicht alle Zustände lassen sich sinnvoll auf ein einziges grünes/rotes Flag reduzieren.

Wetter kann Fenster zusätzlich einschränken, sollte aber getrennt erkennen lassen, ob die Wassertiefe oder das Wetter die Ursache ist. Die heutige iOS-Fenstersuche wertet das Wetter gar nicht aus; die Wetterbewertung bezieht sich separat auf die eingestellte Fahrt.

## 7. Umgesetzter Stand

1. Die sichtbare Eingabe ist ein Abfahrtstag. Der Solver durchsucht den lokalen Kalendertag in `Europe/Berlin`, darf Ankünfte am Folgetag haben und liefert alle berechenbaren Tagesfenster. Die empfohlene Abfahrt maximiert den kleinsten WuK der gesamten Route.
2. Die Sicherheitsreserve ist Teil jeder Engstellenbedingung. Fehlende Tide- oder Tiefendaten schließen ein vollständig bestätigtes Fenster und nennen die betroffenen Wegepunkte. Ungültige Fahrtabschnitte werden nicht mehr übersprungen.
3. Die Routenrechnung und die Fenstersuche verwenden denselben `WaypointDepthSolver`. Tatsächliche BSH-HW-/NW-Ereignishöhen werden zu einer kontinuierlichen, an die jeweilige Tidedauer angepassten Zwölftelkurve verbunden. Wo eine Station keine Ereignishöhen liefert, werden MHW und MTH als klar markierte Näherung verwendet.
4. Lottiefen bei MHW und Kartentiefen relativ zu SKN sind getrennte Rechenmodi. Die Wattsegler-Lotungen wurden mit Abschnitt, Bezugsart, Monat und Quelle den relevanten Fahrwasserknoten zugeordnet. Diese Drittanbieterwerte bleiben vorläufig und können keinen grünen Status erzeugen.
5. Borkum verwendet für den meteorologischen Restwasserstand fest Emden, Juist fest Norderney. Die örtlichen astronomischen Zeiten bleiben Borkum beziehungsweise Juist. Baltrum verwendet entsprechend Langeoog. Eine beliebige automatische Auswahl des geografisch nächsten Pegels findet in der Berechnung nicht statt.
6. Die automatische BSH-Wasserstandskurve wird nur innerhalb ihrer zeitlichen Abdeckung verwendet. Negative Abweichungen verringern den WuK; positive Modellabweichungen ohne belastbare Untergrenze erhöhen ihn nicht. Außerhalb der Kurve bleibt das astronomische Fenster verfügbar, aber gelb und mit dem Hinweis „Windstau noch nicht vorhergesagt“.
7. Die Anzeige nennt Fenstergrenzen, empfohlene Abfahrt, den kleinsten WuK, die tatsächlich begrenzende Engstelle, deren Passagezeit und den verwendeten Tiefenstand. Mehrere Tagestiden sind als Alternativen auswählbar; WuK, ETAs und Routenwetter werden anschließend auf die ausgewählte Abfahrt neu berechnet.
8. WeatherKit wird für eine Route mit einem 48-Stunden-Intervall ab der ausgewählten Abfahrt angefragt. Damit ist die technische Abfrage für einen Törn in einer Woche möglich, solange er innerhalb des von Apple gelieferten Vorhersagehorizonts liegt.

Die acht auswählbaren Häfen Borkum, Emden, Juist, Norderney, Baltrum, Langeoog, Spiekeroog und Wangerooge wurden paarweise gegen den Fahrwassergraphen geprüft. Das sind 56 gerichtete Start-Ziel-Kombinationen.

Abnahmeszenarien: zwei Tiden an einem Tag; nur die zweite Tide geeignet; mehrere Engstellen mit verschiedenen Fahrtzeiten; ein fehlender Wegepunkt; Reserve 0,30 m; negative Kartentiefe; MHW-Lotung ohne Doppelzählung; abweichende Spring-/Nipphöhen; Wechsel der Prognoseprodukte; +7 Tage; Jahreswechsel; Sommerzeitwechsel; Gegenstrom ohne Fortschritt; Wetterlücke; Route über Mitternacht.

## 8. Verifikation und verbleibende Grenzen

- Beide PDF-Seiten vollständig extrahiert, gerendert und visuell geprüft.
- Beide Wattsegler-Seiten gelesen; Jahres- und Wasserstandsdaten Norderney live als JSON abgerufen und Felder/Zeiträume ausgewertet.
- Der iOS-Testbuild ist erfolgreich. Die gezielte Simulator-Suite für Passagefenster, WuK-/Excel-Parität, BSH-Zuordnung, Wasserstandsqualität, Tiefenkatalog, alle Hafenpaare und +7-Tage-Wetterabfrage läuft vollständig durch.
- Der vollständige Projektlauf erreicht darüber hinaus fünf UI-Testfehler in Crew-Kalender und Nauti-Darstellung. Diese Tests betreffen die Passage- und WuK-Logik nicht.
- Android wurde statisch geprüft, nicht gebaut oder auf einem Gerät ausgeführt.
- Die Wattsegler-Werte sind keine amtliche Dauerzusage und können sich nach Verlagerung eines Fahrwassers schnell ändern. Deshalb zeigt die App Quelle und Stand und stuft solche Fenster höchstens gelb ein.
- Die räumliche Zuordnung der Lotungsabschnitte auf den bestehenden, aus der Android-App übernommenen Fahrwassergraphen ist eine Planungszuordnung. Vor einer grünen Freigabe wären amtlich gepflegte Abschnittsgeometrien und ein regelmäßig aktualisierter Tiefenimport nötig.
- Ein belastbares zeit- und ortsabhängiges Strömungsmodell ist noch nicht vorhanden. Die Fahrtzeit verwendet die eingestellte Fahrt durchs Wasser plus den derzeit pro Abschnitt konstanten Stromwert.
- Wetter wird für die empfohlene Route bewertet, begrenzt das reine Wassertiefenfenster aber noch nicht als zweite Intervallbedingung. Dadurch bleibt erkennbar, ob die Tiefe rechnerisch reicht und das Wetter separat dagegen spricht.
