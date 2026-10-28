import SwiftUI

/// Log-frequency response plot. Drag a band's dot to change its frequency and gain.
struct EQGraphView: View {
    let bands: [Band]
    let preamp: Double
    let headroomDB: Double?
    @Binding var selected: Int
    let onChange: (Band) -> Void

    @State private var dragging: Int?

    private let dbLimit = 18.0
    private let fMin = 20.0
    private let fMax = 20_000.0
    private let gridFrequencies: [(Double, String)] = [
        (20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (20000, "20k"),
    ]

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: 38, y: 10, width: geo.size.width - 48, height: geo.size.height - 32)
            Canvas { context, _ in
                drawGrid(context, plot)
                drawHeadroom(context, plot)
                drawCurve(context, plot)
                drawHandles(context, plot)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragging == nil {
                            dragging = nearestBand(to: value.startLocation, in: plot)
                            if let index = dragging { selected = index }
                        }
                        guard let index = dragging, bands.indices.contains(index) else { return }
                        var band = bands[index]
                        band.frequency = clamp(frequency(atX: value.location.x, in: plot), Pearl.frequencyRange).rounded()
                        band.gain = clamp((dB(atY: value.location.y, in: plot) - preamp), Pearl.gainRange).rounded(toPlaces: 1)
                        band.enabled = true
                        onChange(band)
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
    }

    // MARK: Drawing

    private func drawGrid(_ context: GraphicsContext, _ plot: CGRect) {
        let gridColor = Color.secondary.opacity(0.18)
        for (hz, label) in gridFrequencies {
            let x = xFor(hz, plot)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(gridColor), lineWidth: 1)
            context.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x, y: plot.maxY + 11), anchor: .center)
        }
        for db in stride(from: -dbLimit, through: dbLimit, by: 6) {
            let y = yFor(db, plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(db == 0 ? Color.secondary.opacity(0.5) : gridColor), lineWidth: 1)
            context.draw(Text(String(format: "%+.0f", db)).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
        }
    }

    private func drawHeadroom(_ context: GraphicsContext, _ plot: CGRect) {
        guard let headroomDB, headroomDB < dbLimit else { return }
        let y = yFor(headroomDB, plot)
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: y))
        line.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(line, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        context.draw(Text("ceiling").font(.caption2).foregroundStyle(.orange),
                     at: CGPoint(x: plot.maxX - 4, y: y - 7), anchor: .trailing)
    }

    private func drawCurve(_ context: GraphicsContext, _ plot: CGRect) {
        let coefficients = bands.filter { $0.effectiveGain != 0 }.map(Biquad.coefficients(for:))
        let steps = 240
        var path = Path()
        for i in 0...steps {
            let hz = fMin * pow(fMax / fMin, Double(i) / Double(steps))
            let db = preamp + Biquad.responseDB(coefficients, at: hz)
            let point = CGPoint(x: xFor(hz, plot), y: yFor(clamp(db, -dbLimit...dbLimit), plot))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        var fill = path
        fill.addLine(to: CGPoint(x: plot.maxX, y: yFor(0, plot)))
        fill.addLine(to: CGPoint(x: plot.minX, y: yFor(0, plot)))
        fill.closeSubpath()
        context.fill(fill, with: .color(Color.accentColor.opacity(0.12)))
        context.stroke(path, with: .color(Color.accentColor), lineWidth: 2)
    }

    private func drawHandles(_ context: GraphicsContext, _ plot: CGRect) {
        let points = handlePoints(plot)
        for band in bands {
            guard let point = points[band.index] else { continue }
            let isSelected = band.index == selected
            let radius: CGFloat = isSelected ? 7 : 5
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            let color = band.enabled ? Color.accentColor : Color.secondary
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(isSelected ? 1 : 0.85)))
            context.stroke(Path(ellipseIn: rect), with: .color(Color(nsColor: .controlBackgroundColor)), lineWidth: 1.5)
            if isSelected {
                let ring = rect.insetBy(dx: -4, dy: -4)
                context.stroke(Path(ellipseIn: ring), with: .color(color.opacity(0.5)), lineWidth: 1.5)
            }
            context.draw(Text("\(band.index + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white),
                         at: point, anchor: .center)
        }
    }

    // MARK: Coordinate mapping

    private func handlePoint(for band: Band, _ plot: CGRect) -> CGPoint {
        CGPoint(x: xFor(clamp(band.frequency, fMin...fMax), plot),
                y: yFor(clamp(preamp + band.effectiveGain, -dbLimit...dbLimit), plot))
    }

    /// Handle positions, nudged apart when several bands sit on the same spot
    /// (the DAC parks unused bands together at 20 kHz) so each stays grabbable.
    private func handlePoints(_ plot: CGRect) -> [Int: CGPoint] {
        var placed: [CGPoint] = []
        var result: [Int: CGPoint] = [:]
        for band in bands {
            var point = handlePoint(for: band, plot)
            while placed.contains(where: { hypot($0.x - point.x, $0.y - point.y) < 12 }) {
                point.x -= 13
            }
            placed.append(point)
            result[band.index] = point
        }
        return result
    }

    private func nearestBand(to location: CGPoint, in plot: CGRect) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, p) in handlePoints(plot) {
            let d = hypot(p.x - location.x, p.y - location.y)
            if d <= 16, d < (best?.distance ?? .infinity) { best = (index, d) }
        }
        return best?.index
    }

    private func xFor(_ hz: Double, _ plot: CGRect) -> CGFloat {
        plot.minX + plot.width * CGFloat(log(hz / fMin) / log(fMax / fMin))
    }

    private func yFor(_ db: Double, _ plot: CGRect) -> CGFloat {
        plot.midY - plot.height / 2 * CGFloat(db / dbLimit)
    }

    private func frequency(atX x: CGFloat, in plot: CGRect) -> Double {
        let t = Double((x - plot.minX) / plot.width)
        return fMin * pow(fMax / fMin, min(max(t, 0), 1))
    }

    private func dB(atY y: CGFloat, in plot: CGRect) -> Double {
        Double((plot.midY - y) / (plot.height / 2)) * dbLimit
    }

    private func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
