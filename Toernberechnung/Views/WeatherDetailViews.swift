import Charts
import MapKit
import SwiftUI

struct WeatherDaySelection: Identifiable {
    let day: MarineDailyForecast
    let harbour: HarbourOption
    let initialHours: [MarineHourlyForecast]

    var id: String { "\(harbour.id)-\(day.date.timeIntervalSince1970)" }
}

struct WeatherGlassPanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
            content()
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appWeatherLiquidGlass(cornerRadius: 22)
    }
}

struct WeatherDetailPanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
        .foregroundStyle(.primary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appWeatherDetailInset(cornerRadius: 22)
    }
}

enum WeatherAtmosphereKind: Equatable {
    case clear
    case cloudy
    case rain
    case thunder
    case fog
    case snow
    case night

    init(current: MarineCurrentWeather?) {
        guard let current else {
            self = .cloudy
            return
        }

        let condition = "\(current.condition) \(current.symbolName)".lowercased()
        if condition.contains("gewitter") || condition.contains("thunder") || condition.contains("bolt") {
            self = .thunder
        } else if condition.contains("schnee") || condition.contains("graupel") || condition.contains("snow") {
            self = .snow
        } else if condition.contains("regen") || condition.contains("niesel") || condition.contains("schauer")
                    || condition.contains("rain") || condition.contains("drizzle") {
            self = .rain
        } else if condition.contains("nebel") || condition.contains("dunst") || condition.contains("fog") {
            self = .fog
        } else if !current.isDaylight {
            self = .night
        } else if current.cloudCoverPercent > 55 || condition.contains("bewölkt") || condition.contains("wolkig") {
            self = .cloudy
        } else {
            self = .clear
        }
    }
}

struct WeatherAtmosphereView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let current: MarineCurrentWeather?
    var isPaused = false

    private var kind: WeatherAtmosphereKind {
        WeatherAtmosphereKind(current: current)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 18.0, paused: reduceMotion || isPaused)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                switch kind {
                case .clear:
                    drawSun(in: &context, size: size, time: time)
                case .cloudy:
                    drawClouds(in: &context, size: size, time: time, opacity: 0.24, storm: false)
                case .rain:
                    drawClouds(in: &context, size: size, time: time, opacity: 0.22, storm: false)
                    drawRain(in: &context, size: size, time: time)
                case .thunder:
                    drawClouds(in: &context, size: size, time: time, opacity: 0.28, storm: true)
                    drawRain(in: &context, size: size, time: time)
                    drawLightning(in: &context, size: size, time: time)
                case .fog:
                    drawFog(in: &context, size: size, time: time)
                case .snow:
                    drawClouds(in: &context, size: size, time: time, opacity: 0.2, storm: false)
                    drawSnow(in: &context, size: size, time: time)
                case .night:
                    drawNightSky(in: &context, size: size, time: time)
                }
            }
        }
        .animation(.easeInOut(duration: 1.2), value: kind)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawSun(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let minimumDimension = min(size.width, size.height)
        let radius = max(minimumDimension * 0.095, 42)
        let center = CGPoint(
            x: size.width * 0.78 + sinCGFloat(time * 0.035) * size.width * 0.025,
            y: size.height * 0.14 + sinCGFloat(time * 0.027 + 1.2) * size.height * 0.012
        )
        let breathing = 1 + sinCGFloat(time * 0.42) * 0.045

        context.drawLayer { glow in
            glow.addFilter(.blur(radius: radius * 0.34))
            for index in stride(from: 5, through: 1, by: -1) {
                let scale = CGFloat(index) * 0.48 * breathing
                let glowRadius = radius * scale
                glow.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - glowRadius,
                        y: center.y - glowRadius,
                        width: glowRadius * 2,
                        height: glowRadius * 2
                    )),
                    with: .color(Color.yellow.opacity(0.018 + Double(6 - index) * 0.012))
                )
            }
        }

        let rotation = time * 0.055
        for index in 0..<16 {
            let angle = rotation + Double(index) * (.pi * 2 / 16)
            let pulse = 1 + sinCGFloat(time * 0.5 + Double(index) * 0.7) * 0.11
            let innerRadius = radius * 1.28
            let outerRadius = radius * 1.78 * pulse
            var ray = Path()
            ray.move(to: point(center: center, radius: innerRadius, angle: angle))
            ray.addLine(to: point(center: center, radius: outerRadius, angle: angle))
            context.stroke(
                ray,
                with: .color(Color.white.opacity(index.isMultiple(of: 2) ? 0.18 : 0.1)),
                style: StrokeStyle(lineWidth: index.isMultiple(of: 2) ? 2.2 : 1.2, lineCap: .round)
            )
        }

        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )),
            with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.96), Color.yellow.opacity(0.94), Color.orange.opacity(0.72)]),
                startPoint: CGPoint(x: center.x - radius * 0.6, y: center.y - radius * 0.7),
                endPoint: CGPoint(x: center.x + radius, y: center.y + radius)
            )
        )

        for index in 0..<3 {
            let phase = time * (0.075 + Double(index) * 0.012) + Double(index) * 2.1
            let x = size.width * (0.12 + CGFloat(index) * 0.27) + sinCGFloat(phase) * size.width * 0.08
            var beam = Path()
            beam.move(to: CGPoint(x: center.x, y: center.y + radius * 0.6))
            beam.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(beam, with: .color(Color.white.opacity(0.028)), lineWidth: 28 + CGFloat(index) * 9)
        }
    }

    private func drawClouds(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        opacity: Double,
        storm: Bool
    ) {
        context.drawLayer { clouds in
            clouds.addFilter(.blur(radius: storm ? 2.8 : 1.6))
            for index in 0..<7 {
                let cloudWidth = size.width * (0.27 + hash(index, salt: 11) * 0.16)
                let margin = cloudWidth * 0.62
                let span = size.width + margin * 2
                let speed = CGFloat(storm ? 10 + index * 2 : 4 + index)
                let x = positiveModulo(
                    CGFloat(time) * speed + hash(index, salt: 17) * span,
                    span
                ) - margin
                let baseY = size.height * (0.05 + hash(index, salt: 23) * 0.36)
                let y = baseY + sinCGFloat(time * (0.07 + Double(index) * 0.006) + Double(index)) * 8
                let cloudOpacity = opacity * (0.56 + Double(hash(index, salt: 29)) * 0.44)
                drawCloud(
                    in: &clouds,
                    center: CGPoint(x: x, y: y),
                    width: cloudWidth,
                    color: storm ? Color(hex: 0xD8E2EF) : .white,
                    opacity: cloudOpacity
                )
            }
        }
    }

    private func drawRain(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let verticalSpan = max(size.height + 100, 1)
        for index in 0..<82 {
            let depth = 0.45 + hash(index, salt: 31) * 0.75
            let speed = 150 + depth * 150
            let phase = hash(index, salt: 37) * verticalSpan
            let y = positiveModulo(CGFloat(time) * speed + phase, verticalSpan) - 50
            let baseX = hash(index, salt: 41) * (size.width + 80) - 40
            let x = baseX - y * (0.055 + depth * 0.025)
            let length = 14 + depth * 24
            var drop = Path()
            drop.move(to: CGPoint(x: x, y: y - length))
            drop.addLine(to: CGPoint(x: x - length * 0.2, y: y))
            context.stroke(
                drop,
                with: .color(Color.white.opacity(0.1 + Double(depth) * 0.14)),
                style: StrokeStyle(lineWidth: 0.8 + depth * 0.85, lineCap: .round)
            )
        }

        let waterline = size.height * 0.9
        for index in 0..<12 {
            let phase = time * (1.4 + Double(index % 3) * 0.14) + Double(index) * 0.63
            let pulse = CGFloat((sin(phase) + 1) * 0.5)
            let width = 8 + pulse * 28
            let x = hash(index, salt: 47) * size.width
            let ripple = Path(ellipseIn: CGRect(x: x - width / 2, y: waterline + hash(index, salt: 53) * 55, width: width, height: 4 + pulse * 4))
            context.stroke(ripple, with: .color(Color.white.opacity(Double(1 - pulse) * 0.1)), lineWidth: 0.8)
        }
    }

    private func drawLightning(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let period = 9.7
        let phase = positiveModulo(time, period)
        let firstPulse = gaussian(phase, center: 2.1, width: 0.055)
        let secondPulse = gaussian(phase, center: 2.28, width: 0.036) * 0.72
        let intensity = min(firstPulse + secondPulse, 1)
        guard intensity > 0.008 else { return }

        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color(hex: 0xDCEBFF).opacity(intensity * 0.16))
        )

        let cycle = Int(floor(time / period))
        let bolt = lightningPath(size: size, seed: cycle)
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 7))
            glow.stroke(
                bolt,
                with: .color(Color(hex: 0xC8E6FF).opacity(intensity * 0.72)),
                style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
            )
        }
        context.stroke(
            bolt,
            with: .color(Color.white.opacity(intensity)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        )

        let branch = lightningBranchPath(size: size, seed: cycle)
        context.stroke(
            branch,
            with: .color(Color.white.opacity(intensity * 0.72)),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawFog(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        context.drawLayer { fog in
            fog.addFilter(.blur(radius: 10))
            for index in 0..<8 {
                let y = size.height * (0.12 + CGFloat(index) * 0.105)
                let drift = sinCGFloat(time * (0.075 + Double(index) * 0.004) + Double(index)) * 34
                var band = Path()
                band.move(to: CGPoint(x: -80 + drift, y: y))
                band.addCurve(
                    to: CGPoint(x: size.width + 80 + drift, y: y + sinCGFloat(time * 0.09 + Double(index)) * 7),
                    control1: CGPoint(x: size.width * 0.25 + drift, y: y - 12),
                    control2: CGPoint(x: size.width * 0.72 + drift, y: y + 12)
                )
                fog.stroke(band, with: .color(Color.white.opacity(0.08 + Double(index % 3) * 0.025)), lineWidth: 18)
            }
        }
    }

    private func drawSnow(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let verticalSpan = max(size.height + 40, 1)
        for index in 0..<46 {
            let depth = 0.45 + hash(index, salt: 59) * 0.9
            let y = positiveModulo(
                CGFloat(time) * (18 + depth * 32) + hash(index, salt: 61) * verticalSpan,
                verticalSpan
            ) - 20
            let x = hash(index, salt: 67) * size.width
                + sinCGFloat(time * (0.45 + Double(depth) * 0.2) + Double(index)) * (8 + depth * 12)
            let diameter = 1.5 + depth * 3.2
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                with: .color(Color.white.opacity(0.24 + Double(depth) * 0.3))
            )
        }
    }

    private func drawNightSky(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let starHeight = max(size.height * 0.76, 1)
        for index in 0..<58 {
            let x = hash(index, salt: 71) * size.width + sinCGFloat(time * 0.025 + Double(index)) * 2
            let y = hash(index, salt: 73) * starHeight + sinCGFloat(time * 0.018 + Double(index) * 0.4)
            let shimmer = 0.16 + 0.42 * (sin(time * (0.34 + Double(hash(index, salt: 79)) * 0.72) + Double(index)) + 1) / 2
            let diameter = 1.1 + hash(index, salt: 83) * 2.2
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                with: .color(Color.white.opacity(shimmer))
            )
        }

        let moonCenter = CGPoint(
            x: size.width * 0.76 + sinCGFloat(time * 0.018) * size.width * 0.018,
            y: size.height * 0.13 + sinCGFloat(time * 0.022 + 0.8) * 5
        )
        let moonRadius = max(min(size.width, size.height) * 0.06, 26)
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: moonRadius * 0.5))
            glow.fill(
                Path(ellipseIn: CGRect(
                    x: moonCenter.x - moonRadius * 1.55,
                    y: moonCenter.y - moonRadius * 1.55,
                    width: moonRadius * 3.1,
                    height: moonRadius * 3.1
                )),
                with: .color(Color(hex: 0xBFD8FF).opacity(0.16))
            )
        }
        context.fill(
            Path(ellipseIn: CGRect(
                x: moonCenter.x - moonRadius,
                y: moonCenter.y - moonRadius,
                width: moonRadius * 2,
                height: moonRadius * 2
            )),
            with: .color(Color(hex: 0xF3F7FF).opacity(0.88))
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: moonCenter.x - moonRadius * 0.28,
                y: moonCenter.y - moonRadius * 1.08,
                width: moonRadius * 1.65,
                height: moonRadius * 1.85
            )),
            with: .color(Color(hex: 0x162545).opacity(0.94))
        )

        drawShootingStar(in: &context, size: size, time: time)
    }

    private func drawShootingStar(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let period = 18.0
        let phase = positiveModulo(time, period)
        let start = 6.2
        let duration = 1.45
        guard phase >= start, phase <= start + duration else { return }
        let progress = CGFloat((phase - start) / duration)
        let visibility = sin(Double(progress) * .pi)
        let head = CGPoint(
            x: size.width * (0.12 + progress * 0.68),
            y: size.height * (0.11 + progress * 0.21)
        )
        let tail = CGPoint(x: head.x - size.width * 0.16, y: head.y - size.height * 0.07)
        var trail = Path()
        trail.move(to: tail)
        trail.addLine(to: head)
        context.stroke(
            trail,
            with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0), Color.white.opacity(visibility * 0.78)]),
                startPoint: tail,
                endPoint: head
            ),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
        )
        context.fill(
            Path(ellipseIn: CGRect(x: head.x - 2, y: head.y - 2, width: 4, height: 4)),
            with: .color(Color.white.opacity(visibility))
        )
    }

    private func drawCloud(
        in context: inout GraphicsContext,
        center: CGPoint,
        width: CGFloat,
        color: Color,
        opacity: Double
    ) {
        let height = width * 0.42
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - width * 0.48, y: center.y, width: width * 0.96, height: height * 0.54))
        path.addEllipse(in: CGRect(x: center.x - width * 0.36, y: center.y - height * 0.28, width: width * 0.42, height: height * 0.7))
        path.addEllipse(in: CGRect(x: center.x - width * 0.06, y: center.y - height * 0.48, width: width * 0.5, height: height * 0.9))
        path.addEllipse(in: CGRect(x: center.x + width * 0.2, y: center.y - height * 0.18, width: width * 0.3, height: height * 0.58))
        context.fill(path, with: .color(color.opacity(opacity)))
    }

    private func lightningPath(size: CGSize, seed: Int) -> Path {
        let points = lightningPoints(size: size, seed: seed)
        var path = Path()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func lightningBranchPath(size: CGSize, seed: Int) -> Path {
        let points = lightningPoints(size: size, seed: seed)
        guard points.count > 4 else { return Path() }
        let branchStart = points[4]
        var path = Path()
        path.move(to: branchStart)
        path.addLine(to: CGPoint(
            x: branchStart.x + (hash(seed, salt: 101) - 0.5) * size.width * 0.24,
            y: branchStart.y + size.height * 0.13
        ))
        path.addLine(to: CGPoint(
            x: branchStart.x + (hash(seed, salt: 103) - 0.5) * size.width * 0.34,
            y: branchStart.y + size.height * 0.22
        ))
        return path
    }

    private func lightningPoints(size: CGSize, seed: Int) -> [CGPoint] {
        let startX = size.width * (0.28 + hash(seed, salt: 89) * 0.44)
        var points = [CGPoint(x: startX, y: size.height * 0.09)]
        for segment in 1...8 {
            let previous = points[segment - 1]
            let direction = hash(seed + segment, salt: 97) - 0.5
            points.append(CGPoint(
                x: previous.x + direction * size.width * 0.12,
                y: size.height * (0.09 + CGFloat(segment) * 0.095)
            ))
        }
        return points
    }

    private func point(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(
            x: center.x + CGFloat(cos(angle)) * radius,
            y: center.y + CGFloat(sin(angle)) * radius
        )
    }

    private func hash(_ value: Int, salt: Int) -> CGFloat {
        let raw = sin(Double(value &* 1_103 &+ salt &* 313) * 12.9898) * 43_758.5453
        return CGFloat(raw - floor(raw))
    }

    private func sinCGFloat(_ value: Double) -> CGFloat {
        CGFloat(sin(value))
    }

    private func positiveModulo(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        guard modulus > 0 else { return 0 }
        return value - floor(value / modulus) * modulus
    }

    private func positiveModulo(_ value: TimeInterval, _ modulus: TimeInterval) -> TimeInterval {
        guard modulus > 0 else { return 0 }
        return value - floor(value / modulus) * modulus
    }

    private func gaussian(_ value: Double, center: Double, width: Double) -> Double {
        let distance = (value - center) / width
        return exp(-(distance * distance))
    }
}

struct WindCompassRose: View {
    let wind: MarineWind

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.12))
                .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))

            ForEach(0..<16, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.7 : 0.35))
                    .frame(width: index.isMultiple(of: 2) ? 2 : 1, height: index.isMultiple(of: 2) ? 9 : 6)
                    .offset(y: -59)
                    .rotationEffect(.degrees(Double(index) * 22.5))
            }

            compassLabel("N", y: -47)
            compassLabel("O", x: 47)
            compassLabel("S", y: 47)
            compassLabel("W", x: -47)

            Image(systemName: "arrow.down")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.cyan)
                .rotationEffect(.degrees(wind.flowArrowRotationDegrees))
                .shadow(color: .cyan.opacity(0.35), radius: 8)

            VStack(spacing: 1) {
                Text(wind.compassDirection)
                    .font(.system(size: 12, weight: .heavy))
                Text("\(wind.directionDegrees)°")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.7)
            }
            .padding(6)
            .background(Color.black.opacity(0.38), in: Circle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wind aus \(wind.compassDescription), \(wind.directionDegrees) Grad, \(Int(wind.speedKnots.rounded())) Knoten, Böen \(Int(wind.effectiveGustKnots.rounded())) Knoten")
    }

    private func compassLabel(_ text: String, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.72))
            .offset(x: x, y: y)
    }
}

struct IslandWindMapView: View {
    let harbours: [HarbourOption]
    let forecasts: [String: [MarineHourlyForecast]]
    let selectedDate: Date

    private let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.67, longitude: 7.32),
        span: MKCoordinateSpan(latitudeDelta: 0.62, longitudeDelta: 1.75)
    )

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: [.pan, .zoom]) {
            ForEach(harbours) { harbour in
                Annotation(shortName(harbour.name), coordinate: CLLocationCoordinate2D(latitude: harbour.latitude, longitude: harbour.longitude)) {
                    if let wind = wind(for: harbour) {
                        VStack(spacing: 3) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 15, weight: .bold))
                                .rotationEffect(.degrees(wind.flowArrowRotationDegrees))
                            Text("\(Int(wind.speedKnots.rounded()))/\(Int(wind.effectiveGustKnots.rounded()))")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                            Text(wind.compassDirection)
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Color(hex: 0x173A57).opacity(0.9), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.cyan.opacity(0.65), lineWidth: 1))
                    } else {
                        Text("–")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 30, height: 30)
                            .background(Color(hex: 0x173A57).opacity(0.72), in: Circle())
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
    }

    private func wind(for harbour: HarbourOption) -> MarineWind? {
        guard let hours = forecasts[harbour.id] else { return nil }
        return hours.min(by: {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }).flatMap {
            abs($0.date.timeIntervalSince(selectedDate)) <= 2 * 3_600 ? $0.wind : nil
        }
    }

    private func shortName(_ name: String) -> String {
        name.components(separatedBy: ",").first ?? name
    }
}

struct WindSpeedChart: View {
    let hours: [MarineHourlyForecast]
    let axisColor: Color
    @State private var selectedDate: Date?

    init(hours: [MarineHourlyForecast], axisColor: Color = .white) {
        self.hours = hours
        self.axisColor = axisColor
    }

    private var chartHours: [MarineHourlyForecast] {
        Array(hours.sorted { $0.date < $1.date }.prefix(48))
    }

    private var selectedHour: MarineHourlyForecast? {
        guard let selectedDate else { return chartHours.first }
        return chartHours.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selectedHour {
                windSummary(for: selectedHour)
            }

            Chart {
                ForEach(chartHours) { hour in
                    AreaMark(
                        x: .value("Zeit", hour.date),
                        yStart: .value("Grundwind", hour.wind.speedKnots),
                        yEnd: .value("Böen", hour.wind.effectiveGustKnots)
                    )
                    .foregroundStyle(Color.orange.opacity(0.16))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Zeit", hour.date),
                        y: .value("Grundwind", hour.wind.speedKnots),
                        series: .value("Serie", "Grundwind")
                    )
                    .foregroundStyle(Color.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Zeit", hour.date),
                        y: .value("Böen", hour.wind.effectiveGustKnots),
                        series: .value("Serie", "Böen")
                    )
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round, dash: [7, 5]))
                    .interpolationMethod(.catmullRom)
                }

                if selectedDate != nil, let selectedHour {
                    RuleMark(x: .value("Ausgewählte Zeit", selectedHour.date))
                        .foregroundStyle(axisColor.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    PointMark(
                        x: .value("Zeit", selectedHour.date),
                        y: .value("Grundwind", selectedHour.wind.speedKnots)
                    )
                    .foregroundStyle(Color.cyan)
                    .symbolSize(55)

                    PointMark(
                        x: .value("Zeit", selectedHour.date),
                        y: .value("Böen", selectedHour.wind.effectiveGustKnots)
                    )
                    .foregroundStyle(Color.orange)
                    .symbolSize(55)
                }
            }
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: 12 * 3_600)
            .chartXSelection(value: $selectedDate)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                    AxisGridLine().foregroundStyle(axisColor.opacity(0.12))
                    AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                        .foregroundStyle(axisColor.opacity(0.82))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(axisColor.opacity(0.12))
                    AxisValueLabel {
                        if let knots = value.as(Double.self) {
                            Text("\(Int(knots)) kn")
                                .foregroundStyle(axisColor.opacity(0.82))
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 18) {
                chartLegendItem("Grundwind", color: .cyan, dashed: false)
                chartLegendItem("Böen", color: .orange, dashed: true)
            }
        }
    }

    private func windSummary(for hour: MarineHourlyForecast) -> some View {
        HStack(spacing: 0) {
            windSummaryMetric(
                title: "GRUNDWIND",
                value: hour.wind.speedKnots,
                color: .cyan,
                symbol: "wind"
            )

            Rectangle()
                .fill(axisColor.opacity(0.18))
                .frame(width: 1, height: 38)
                .padding(.horizontal, 14)

            windSummaryMetric(
                title: "BÖEN",
                value: hour.wind.effectiveGustKnots,
                color: .orange,
                symbol: "wind.circle.fill"
            )

            Spacer(minLength: 12)

            Text(selectedDate == nil ? "JETZT" : AppDateFormatters.hourMinute.string(from: hour.date))
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(axisColor.opacity(0.9))
        }
    }

    private func windSummaryMetric(title: String, value: Double, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(title)
                    .foregroundStyle(axisColor.opacity(0.94))
            }
            .font(.system(size: 9, weight: .heavy))
            Text("\(Int(value.rounded())) kn")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(axisColor)
                .contentTransition(.numericText())
        }
    }

    private func chartLegendItem(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dashed ? [5, 3] : [])
                )
                .frame(width: 22, height: 3)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(axisColor.opacity(0.94))
        }
    }
}

struct TemperatureRangeBar: View {
    let day: MarineDailyForecast
    let allDays: [MarineDailyForecast]

    var body: some View {
        GeometryReader { proxy in
            let overallLow = allDays.map(\.lowTemperatureC).min() ?? day.lowTemperatureC
            let overallHigh = allDays.map(\.highTemperatureC).max() ?? day.highTemperatureC
            let span = max(overallHigh - overallLow, 1)
            let leading = (day.lowTemperatureC - overallLow) / span * proxy.size.width
            let width = max((day.highTemperatureC - day.lowTemperatureC) / span * proxy.size.width, 8)

            Capsule()
                .fill(Color.white.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [Color.cyan, Color.yellow, Color.orange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: min(width, proxy.size.width - leading))
                        .offset(x: leading)
                }
        }
    }
}

struct WeatherAttributionView: View {
    let attribution: MarineWeatherAttribution

    var body: some View {
        Link(destination: attribution.legalPageURL) {
            HStack {
                if let markURL = attribution.combinedMarkDarkURL ?? attribution.combinedMarkLightURL {
                    AsyncImage(url: markURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text(attribution.serviceName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(height: 20)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "apple.logo")
                        Text("Wetter")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
        }
    }
}

struct WeatherDayDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.maritimeWeatherService) private var maritimeWeatherService
    let selection: WeatherDaySelection

    @State private var hours: [MarineHourlyForecast]
    @State private var isLoading = false
    @State private var errorText: String?

    init(selection: WeatherDaySelection) {
        self.selection = selection
        _hours = State(initialValue: selection.initialHours)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    detailHero

                    if isLoading {
                        ProgressView("Stundendaten werden geladen …")
                            .tint(Color.appPrimary)
                            .foregroundStyle(.primary)
                            .padding()
                    } else if let errorText {
                        detailError(errorText)
                    }

                    if !hours.isEmpty {
                        WeatherDetailPanel(title: "TAGESVERLAUF WIND", icon: "wind") {
                            WindSpeedChart(hours: hours, axisColor: .primary)
                                .frame(height: 300)
                        }
                    }

                    detailMetrics
                    sunAndMoonPanel
                    precipitationPanel
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(Color.clear)
            .navigationTitle(AppDateFormatters.weekdayLong.string(from: selection.day.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .foregroundStyle(Color.appPrimary)
                }
            }
        }
        .background(Color.clear)
        .appWeatherDetailSheetGlass(cornerRadius: 32)
        .task { await loadHoursIfNeeded() }
    }

    private var detailHero: some View {
        VStack(spacing: 8) {
            MarineWeatherConditionSymbol(
                symbolName: selection.day.symbolName,
                pointSize: 54,
                accessibilityLabel: selection.day.condition
            )
            Text(selection.day.condition)
                .font(.system(size: 25, weight: .bold))
            Text("\(Int(selection.day.lowTemperatureC.rounded()))° – \(Int(selection.day.highTemperatureC.rounded()))°")
                .font(.system(size: 42, weight: .light))
            Text(selection.harbour.name)
                .font(.system(size: 14, weight: .semibold))
                .opacity(0.72)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var detailMetrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            detailMetric("Grundwind", "\(Int(selection.day.daytimeWind.speedKnots.rounded())) kn", "wind")
            detailMetric("Maximalwind", "\(Int((selection.day.highWindKnots ?? selection.day.daytimeWind.effectiveGustKnots).rounded())) kn", "wind.circle.fill")
            detailMetric("Richtung", "\(selection.day.daytimeWind.compassDirection) · \(selection.day.daytimeWind.directionDegrees)°", "location.north.fill")
            detailMetric("Feuchte", "\(selection.day.minimumHumidityPercent)–\(selection.day.maximumHumidityPercent)%", "humidity.fill")
            detailMetric("Sicht", String(format: "%.1f–%.1f km", selection.day.minimumVisibilityKM, selection.day.maximumVisibilityKM), "eye.fill")
            detailMetric("UV-Index", "\(selection.day.uvIndex) · \(selection.day.uvCategory)", "sun.max.fill")
            detailMetric("Tageswetter", selection.day.daytimeCondition, "sun.horizon.fill")
            detailMetric("Nachtwetter", selection.day.overnightCondition, "moon.stars.fill")

            if let pressureRange {
                detailMetric("Luftdruck", pressureRange, "gauge.with.dots.needle.50percent")
            }
        }
    }

    private var pressureRange: String? {
        guard let minimum = hours.map(\.pressureHPA).min(), let maximum = hours.map(\.pressureHPA).max() else { return nil }
        return "\(Int(minimum.rounded()))–\(Int(maximum.rounded())) hPa"
    }

    private func detailMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.uppercased(), systemImage: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(14)
        .appWeatherDetailInset(cornerRadius: 18)
    }

    private var sunAndMoonPanel: some View {
        WeatherDetailPanel(title: "SONNE UND MOND", icon: "sun.and.horizon.fill") {
            VStack(spacing: 11) {
                eventRow("Sonnenaufgang", selection.day.sunrise, icon: "sunrise.fill")
                eventRow("Sonnenuntergang", selection.day.sunset, icon: "sunset.fill")
                eventRow(selection.day.moonPhase, selection.day.moonrise, icon: selection.day.moonSymbolName)
                eventRow("Monduntergang", selection.day.moonset, icon: "moon.zzz.fill")
            }
        }
    }

    private var precipitationPanel: some View {
        WeatherDetailPanel(title: "NIEDERSCHLAG", icon: "drop.fill") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xA6EAFF))
                        .frame(width: 42, height: 42)
                        .background(Color.black.opacity(0.26), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wahrscheinlichkeit")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("\(selection.day.precipitationChance)%")
                            .font(.system(size: 25, weight: .bold))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Gesamt")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(millimeter(selection.day.precipitation.totalMM))
                            .font(.system(size: 18, weight: .bold))
                    }
                }

                ProgressView(value: Double(selection.day.precipitationChance), total: 100)
                    .tint(Color(hex: 0x62D7FF))

                Divider()
                valueRow("Art", selection.day.precipitationType)
                if selection.day.precipitation.rainMM > 0 { valueRow("Regen", millimeter(selection.day.precipitation.rainMM)) }
                if selection.day.precipitation.snowMM > 0 { valueRow("Schnee (Wasseräquivalent)", millimeter(selection.day.precipitation.snowMM)) }
                if selection.day.precipitation.sleetMM > 0 { valueRow("Schneeregen", millimeter(selection.day.precipitation.sleetMM)) }
                if selection.day.precipitation.hailMM > 0 { valueRow("Hagel", millimeter(selection.day.precipitation.hailMM)) }
                if selection.day.precipitation.mixedMM > 0 { valueRow("Gemischt", millimeter(selection.day.precipitation.mixedMM)) }
            }
        }
    }

    private func eventRow(_ title: String, _ date: Date?, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(date.map { AppDateFormatters.hourMinute.string(from: $0) } ?? "–")
                .font(.system(size: 14, weight: .bold))
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).opacity(0.72)
            Spacer()
            Text(value).fontWeight(.bold)
        }
        .font(.system(size: 13))
    }

    private func millimeter(_ value: Double) -> String {
        String(format: "%.1f mm", value)
    }

    private func detailError(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
            Button("Erneut versuchen") {
                Task { await loadHours(policy: .manualRetry) }
            }
            .font(.system(size: 14, weight: .bold))
        }
        .foregroundStyle(.primary)
        .padding(16)
        .frame(maxWidth: .infinity)
        .appWeatherDetailInset(cornerRadius: 18)
    }

    @MainActor
    private func loadHoursIfNeeded() async {
        await loadHours(policy: .revalidateExpired)
    }

    @MainActor
    private func loadHours(policy: WeatherReadPolicy) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            hours = try await maritimeWeatherService.hourlyWeather(
                for: selection.harbour,
                on: selection.day.date,
                policy: policy
            )
        } catch {
            errorText = error.localizedDescription
        }
    }
}
