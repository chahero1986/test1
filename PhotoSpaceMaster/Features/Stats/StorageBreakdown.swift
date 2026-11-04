import SwiftUI

/// 时间粒度（用于按日期统计空间占用）
enum DateGranularity: String, CaseIterable, Identifiable {
    case year, month, day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .year: return "年"
        case .month: return "月"
        case .day: return "日"
        }
    }

    var unitTitle: String {
        switch self {
        case .year: return "年度"
        case .month: return "月度"
        case .day: return "每日"
        }
    }
}

/// 一个时间周期的空间占用
struct PeriodUsage: Identifiable {
    let start: Date
    let end: Date
    /// 完整标题：2026年6月3日 / 2026年6月 / 2026年
    let title: String
    /// 柱状图下方短标签：6/3、6月、2026
    let shortTitle: String
    let bytes: Int64
    let count: Int

    var id: Date { start }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

/// 把资产按年 / 月 / 日聚合为空间占用周期列表（统一按日期倒序）
enum StorageBreakdown {
    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    static func periods(
        _ assets: [AssetInfo],
        granularity: DateGranularity,
        calendar: Calendar = .current
    ) -> [PeriodUsage] {
        var bucket: [Date: (bytes: Int64, count: Int)] = [:]
        for asset in assets {
            guard let date = asset.creationDate else { continue }
            let start = periodStart(date, granularity: granularity, calendar: calendar)
            var entry = bucket[start] ?? (0, 0)
            entry.bytes += asset.byteSize
            entry.count += 1
            bucket[start] = entry
        }

        return bucket.map { start, entry in
            PeriodUsage(
                start: start,
                end: periodEnd(start, granularity: granularity, calendar: calendar),
                title: title(for: start, granularity: granularity),
                shortTitle: shortTitle(for: start, granularity: granularity),
                bytes: entry.bytes,
                count: entry.count
            )
        }
        .sorted { $0.start > $1.start }   // 日期从新到旧
    }

    static func periodStart(_ date: Date, granularity: DateGranularity, calendar: Calendar = .current) -> Date {
        switch granularity {
        case .day:
            return calendar.startOfDay(for: date)
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? calendar.startOfDay(for: date)
        case .year:
            let year = calendar.component(.year, from: date)
            return calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? calendar.startOfDay(for: date)
        }
    }

    static func periodEnd(_ start: Date, granularity: DateGranularity, calendar: Calendar = .current) -> Date {
        let comps: DateComponents
        switch granularity {
        case .day: comps = DateComponents(day: 1)
        case .month: comps = DateComponents(month: 1)
        case .year: comps = DateComponents(year: 1)
        }
        return calendar.date(byAdding: comps, to: start) ?? start
    }

    static func title(for start: Date, granularity: DateGranularity) -> String {
        fullFormatter.dateFormat = pattern(granularity: granularity, short: false)
        return fullFormatter.string(from: start)
    }

    static func shortTitle(for start: Date, granularity: DateGranularity) -> String {
        fullFormatter.dateFormat = pattern(granularity: granularity, short: true)
        return fullFormatter.string(from: start)
    }

    private static func pattern(granularity: DateGranularity, short: Bool) -> String {
        switch granularity {
        case .year: return short ? "yyyy" : "yyyy年"
        case .month: return short ? "M月" : "yyyy年M月"
        case .day: return short ? "M/d" : "yyyy年M月d日"
        }
    }
}

/// 空间占用柱状图：横向可滚动，柱子按日期倒序排列，点击回调选中周期
struct StorageBarChart: View {
    /// 已按日期倒序排列的周期
    let periods: [PeriodUsage]
    var chartHeight: CGFloat = 130
    /// 最多渲染的柱数（超出部分不显示柱，列表中仍可查看全部）
    var maxBars: Int = 90
    var onTap: ((PeriodUsage) -> Void)? = nil

    @State private var selectedId: Date?

    private var shown: [PeriodUsage] { Array(periods.prefix(maxBars)) }
    private var maxBytes: Int64 { max(1, shown.map(\.bytes).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(shown) { period in
                        bar(for: period)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 16)
            }
            .frame(height: chartHeight + 44)

            if periods.count > maxBars {
                Text("共 \(periods.count) 个\(periods.count > 0 ? "时间段" : "")，柱状图显示最近 \(maxBars) 个，完整数据见下方列表")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func bar(for period: PeriodUsage) -> some View {
        let ratio = CGFloat(period.bytes) / CGFloat(maxBytes)
        let isSelected = selectedId == period.id
        return VStack(spacing: 5) {
            Text(isSelected ? period.sizeText : "")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.5))
                .frame(width: 22, height: max(3, chartHeight * ratio))

            Text(period.shortTitle)
                .font(.system(size: 9))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedId = period.id
            onTap?(period)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(period.title)，占用 \(period.sizeText)，\(period.count) 项")
    }
}
