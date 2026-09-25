import SwiftUI
import Charts

/// Pointer and keyboard inspection shared by the dashboard's x-axis charts.
/// On compact platforms the content is returned untouched; Mac gains hover,
/// click/drag, arrow-key, Home/End, and Escape behavior without changing the
/// phone layout or gesture surface.
struct StatsChartXInspectionModifier<Value: Equatable>: ViewModifier {
    let values: [Value]
    @Binding var selection: Value?
    let valueAtX: (ChartProxy, CGFloat) -> Value?
    let xPosition: (Value) -> Double
    let accessibilityText: (Value) -> String

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    select(value.location.x, proxy: proxy, geometry: geometry)
                                }
                        )
                        .simultaneousGesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    let candidate = nearestValue(
                                        at: value.location.x,
                                        proxy: proxy,
                                        geometry: geometry
                                    )
                                    selection = selection == candidate ? nil : candidate
                                }
                        )
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                select(point.x, proxy: proxy, geometry: geometry)
                            case .ended:
                                selection = nil
                            }
                        }
                }
            }
            .focusable()
            .onKeyPress { press in
                handle(press)
            }
            .accessibilityValue(selection.map(accessibilityText) ?? "")
            .accessibilityHint("Use the arrow keys to inspect values. Press Home or End to jump; Escape to clear.")
        #else
        content
        #endif
    }

    private func select(
        _ locationX: CGFloat,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        selection = nearestValue(at: locationX, proxy: proxy, geometry: geometry)
    }

    private func nearestValue(
        at locationX: CGFloat,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> Value? {
        guard !values.isEmpty,
              let plotFrameAnchor = proxy.plotFrame
        else { return nil }

        let plotFrame = geometry[plotFrameAnchor]
        let plotX = locationX - plotFrame.origin.x
        guard plotX >= 0,
              plotX <= proxy.plotSize.width,
              let candidate = valueAtX(proxy, plotX)
        else { return nil }

        return values.min { lhs, rhs in
            let lhsDistance = abs(xPosition(lhs) - xPosition(candidate))
            let rhsDistance = abs(xPosition(rhs) - xPosition(candidate))
            if lhsDistance == rhsDistance { return xPosition(lhs) < xPosition(rhs) }
            return lhsDistance < rhsDistance
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard !values.isEmpty else { return .ignored }
        let currentIndex = selection.flatMap { selected in
            values.firstIndex(of: selected)
        }

        let nextIndex: Int?
        switch press.key {
        case .leftArrow:
            guard let currentIndex else { return .ignored }
            nextIndex = max(0, currentIndex - 1)
        case .rightArrow:
            nextIndex = min(values.count - 1, (currentIndex ?? -1) + 1)
        case .home:
            nextIndex = 0
        case .end:
            nextIndex = values.count - 1
        case .escape:
            selection = nil
            return .handled
        default:
            return .ignored
        }

        guard let nextIndex else { return .ignored }
        selection = values[nextIndex]
        return .handled
    }
}

extension View {
    func statsChartXInspection<Value: Equatable>(
        values: [Value],
        selection: Binding<Value?>,
        valueAtX: @escaping (ChartProxy, CGFloat) -> Value?,
        xPosition: @escaping (Value) -> Double,
        accessibilityText: @escaping (Value) -> String
    ) -> some View {
        modifier(
            StatsChartXInspectionModifier(
                values: values,
                selection: selection,
                valueAtX: valueAtX,
                xPosition: xPosition,
                accessibilityText: accessibilityText
            )
        )
    }
}

func statsChartDayTitle(_ dayOffset: Int) -> String {
    guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else {
        return "Day \(dayOffset)"
    }
    return date.formatted(
        .dateTime
            .weekday(.abbreviated)
            .month(.abbreviated)
            .day()
    )
}
