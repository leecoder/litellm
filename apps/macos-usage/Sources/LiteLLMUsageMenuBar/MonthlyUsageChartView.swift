import Charts
import SwiftUI

struct MonthlyUsageChartView: View {
    let state: MonthlyUsageChartState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("월간 사용량 그래프를 불러오는 중...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case let .ready(data):
                chart(data)
            case let .unavailable(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func chart(_ data: MonthlyUsageChartData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("월간 누적 사용")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text("예상 \(currency(data.estimatedMonthEndSpend))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Chart {
                ForEach(data.actualPoints) { point in
                    AreaMark(
                        x: .value("날짜", point.date),
                        yStart: .value("시작", 0),
                        yEnd: .value("누적 사용", point.cumulativeSpend)
                    )
                    .foregroundStyle(Color.blue.opacity(0.12))

                    LineMark(
                        x: .value("날짜", point.date),
                        y: .value("누적 사용", point.cumulativeSpend),
                        series: .value("구분", "사용")
                    )
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }

                ForEach(Array(data.forecastPoints.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("날짜", point.date),
                        y: .value("예상 사용", point.cumulativeSpend),
                        series: .value("구분", "예측")
                    )
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }

                RuleMark(y: .value("월 한도", data.limit))
                    .foregroundStyle(Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXScale(domain: data.monthStart...data.monthEnd)
            .chartYScale(domain: 0...data.upperBound)
            .chartXAxis {
                AxisMarks(values: data.axisDates) { value in
                    AxisValueLabel(format: .dateTime.day())
                    AxisTick()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.currency(code: "USD").precision(.fractionLength(0...2))))
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 112)
            .accessibilityLabel("누적 사용액, 월말 예상액, 월 한도 그래프")

            HStack(spacing: 12) {
                legend("사용", color: .blue)
                legend("예측", color: .orange)
                legend("한도", color: .red)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }
}
