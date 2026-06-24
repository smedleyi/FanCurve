import SwiftUI

struct CurveChart: View {
    @Binding var points: [CurvePoint]
    var fanMin: Double
    var fanMax: Double
    var currentTemp: Double = 0
    var currentRPM: Double  = 0
    var maxFanSpeed: Double? = nil

    private let tempRange: ClosedRange<Double> = 0...105

    private let xAxisH:  CGFloat = 16
    private let padV:    CGFloat = 14   // keeps top/bottom points inset from edge
    private let padH:    CGFloat = 8    // keeps left/right points inset from edge

    @State private var dragging: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                plotArea(w: geo.size.width, h: geo.size.height)
            }
            .coordinateSpace(name: "chart")
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(4)

            Canvas { ctx, size in
                drawXAxis(ctx: ctx, size: size)
            }
            .frame(height: xAxisH)
        }
    }

    // MARK: - Plot

    private func plotArea(w: CGFloat, h: CGFloat) -> some View {
        let s = sorted
        let linePath = curvePath(sorted: s, w: w, h: h)
        return ZStack {
            Canvas { ctx, _ in drawGrid(ctx: ctx, w: w, h: h) }
            curveFill(basePath: linePath, sorted: s, w: w, h: h).fill(Color.accentColor.opacity(0.12))
            linePath.stroke(Color.accentColor, lineWidth: 2)
            Canvas { ctx, _ in
                guard currentTemp > 0 || currentRPM > 0 else { return }
                let cx = xPos(currentTemp, w: w)
                let cy = yPos(currentRPM, h: h)
                var v = Path()
                v.move(to: CGPoint(x: cx, y: 0))
                v.addLine(to: CGPoint(x: cx, y: h))
                var hz = Path()
                hz.move(to: CGPoint(x: 0, y: cy))
                hz.addLine(to: CGPoint(x: w, y: cy))
                ctx.stroke(v,  with: .color(.red.opacity(0.7)), lineWidth: 0.5)
                ctx.stroke(hz, with: .color(.red.opacity(0.7)), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
            if let cap = maxFanSpeed, cap < fanMax {
                Canvas { ctx, _ in
                    let cy = yPos(cap, h: h)
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: cy))
                    p.addLine(to: CGPoint(x: w, y: cy))
                    ctx.stroke(p, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    let label = ctx.resolve(
                        Text("cap")
                            .font(.system(size: 8))
                            .foregroundColor(Color.orange.opacity(0.9))
                    )
                    ctx.draw(label, at: CGPoint(x: w - padH - 2, y: cy - 6), anchor: .trailing)
                }
                .allowsHitTesting(false)
            }
            ForEach($points) { $pt in
                DragPoint(
                    x: xPos(pt.tempC, w: w), y: yPos(pt.rpm, h: h),
                    isDragging: dragging == pt.id
                ) { drag in handleDrag(id: pt.id, drag: drag, w: w, h: h) }
                  onEnd: { dragging = nil }
                  onStart: { dragging = pt.id }
            }
        }
    }

    private var sorted: [CurvePoint] { points.sorted { $0.tempC < $1.tempC } }

    // MARK: - Axis drawing

    private func drawXAxis(ctx: GraphicsContext, size: CGSize) {
        for t in [0.0, 25, 50, 75, 100] {
            let x = xPos(t, w: size.width)
            let anchor: UnitPoint = t == 0 ? .leading : t == 100 ? .trailing : .center
            let label = ctx.resolve(
                Text("\(Int(t))°")
                    .font(.system(size: 9))
                    .foregroundColor(Color.secondary)
            )
            ctx.draw(label, at: CGPoint(x: x, y: size.height / 2), anchor: anchor)
        }
    }

    private func drawGrid(ctx: GraphicsContext, w: CGFloat, h: CGFloat) {
        for t in [25.0, 50, 75, 100] {
            var p = Path(); let x = xPos(t, w: w)
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
            ctx.stroke(p, with: .color(.secondary.opacity(0.15)))
        }
        for r in [2000.0, 4000, 6000] where r <= fanMax {
            var p = Path(); let y = yPos(r, h: h)
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(p, with: .color(.secondary.opacity(0.1)))
        }
        var lastLabelY: CGFloat = h + 99
        for r in [0.0, 2000, 4000, 6000, fanMax] where r <= fanMax {
            let y = yPos(r, h: h)
            guard abs(y - lastLabelY) >= 22 else { continue }
            lastLabelY = y
            let anchor: UnitPoint = r == 0 ? .bottomLeading : r == fanMax ? .topLeading : .leading
            let label = ctx.resolve(
                Text(rpmLabel(r))
                    .font(.system(size: 9))
                    .foregroundColor(Color.secondary)
            )
            ctx.draw(label, at: CGPoint(x: padH + 2, y: y), anchor: anchor)
        }
    }

    // MARK: - Geometry

    private func xPos(_ temp: Double, w: CGFloat) -> CGFloat {
        let usable = w - 2 * padH
        return padH + CGFloat((temp - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)) * usable
    }

    private func yPos(_ rpm: Double, h: CGFloat) -> CGFloat {
        let usable = h - 2 * padV
        guard fanMax > 0 else { return h - padV }
        return h - padV - CGFloat(rpm / fanMax) * usable
    }

    private func tempFromX(_ x: CGFloat, w: CGFloat) -> Double {
        let usable = w - 2 * padH
        return (tempRange.lowerBound + Double((x - padH) / usable) * (tempRange.upperBound - tempRange.lowerBound))
            .clamped(to: tempRange)
    }

    private func rpmFromY(_ y: CGFloat, h: CGFloat) -> Double {
        let usable = h - 2 * padV
        let t = Double((h - padV - y) / usable)
        return (t * fanMax).clamped(to: 0...fanMax)
    }

    private func curvePath(sorted: [CurvePoint], w: CGFloat, h: CGFloat) -> Path {
        var path = Path()
        guard !sorted.isEmpty else { return path }
        path.move(to: CGPoint(x: xPos(sorted[0].tempC, w: w), y: yPos(sorted[0].rpm, h: h)))
        for pt in sorted.dropFirst() {
            path.addLine(to: CGPoint(x: xPos(pt.tempC, w: w), y: yPos(pt.rpm, h: h)))
        }
        return path
    }

    private func curveFill(basePath: Path, sorted: [CurvePoint], w: CGFloat, h: CGFloat) -> Path {
        var path = basePath
        guard !sorted.isEmpty else { return path }
        path.addLine(to: CGPoint(x: xPos(sorted.last!.tempC, w: w), y: h))
        path.addLine(to: CGPoint(x: xPos(sorted.first!.tempC, w: w), y: h))
        path.closeSubpath()
        return path
    }

    private func rpmLabel(_ rpm: Double) -> String {
        rpm >= 1000 ? String(format: "%.0fk", rpm / 1000) : "0"
    }

    private func handleDrag(id: UUID, drag: DragGesture.Value, w: CGFloat, h: CGFloat) {
        guard let idx = points.firstIndex(where: { $0.id == id }) else { return }
        if !points[idx].isLocked { points[idx].tempC = tempFromX(drag.location.x, w: w).rounded() }
        points[idx].rpm = (rpmFromY(drag.location.y, h: h) / 50).rounded() * 50
    }
}

// MARK: - Drag handle

private struct DragPoint: View {
    let x: CGFloat
    let y: CGFloat
    let isDragging: Bool
    let onDrag:  (DragGesture.Value) -> Void
    let onEnd:   () -> Void
    let onStart: () -> Void

    var body: some View {
        Circle()
            .fill(isDragging ? Color.white : Color.accentColor)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: isDragging ? 2 : 0))
            .frame(width: isDragging ? 14 : 10, height: isDragging ? 14 : 10)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .position(x: x, y: y)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("chart"))
                    .onChanged { v in onStart(); onDrag(v) }
                    .onEnded   { _ in onEnd() }
            )
            .animation(.easeInOut(duration: 0.1), value: isDragging)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
