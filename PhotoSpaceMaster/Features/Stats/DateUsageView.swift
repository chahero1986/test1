import SwiftUI

/// 按日期空间占用：年 / 月 / 日粒度，支持全部日期 / 最近半年 / 指定年度区间，
/// 列表与柱状图均按日期从新到旧排列，点击周期跳转到首页该日期的位置。
struct DateUsageView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore

    enum RangeMode: String, CaseIterable, Identifiable {
        case all, last6Months, year

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部日期"
            case .last6Months: return "最近半年"
            case .year: return "按年度"
            }
        }
    }

    @State private var granularity: DateGranularity = .day
    @State private var range: RangeMode = .all
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    /// 列表分页：默认展示前 200 个周期，避免「全部日期 + 按日」时一次性渲染上千行
    @State private var listLimit = 200

    /// 相册内出现过的年份（倒序），用于年度选择
    private var availableYears: [Int] {
        let calendar = Calendar.current
        var years = Set<Int>()
        for asset in library.assets {
            if let date = asset.creationDate {
                years.insert(calendar.component(.year, from: date))
            }
        }
        return years.sorted(by: >)
    }

    private var filteredAssets: [AssetInfo] {
        let calendar = Calendar.current
        let now = Date()
        switch range {
        case .all:
            return library.assets
        case .last6Months:
            guard let start = calendar.date(byAdding: .month, value: -6, to: now) else { return library.assets }
            return library.assets.filter { ($0.creationDate ?? .distantPast) >= start }
        case .year:
            guard let start = calendar.date(from: DateComponents(year: selectedYear, month: 1, day: 1)),
                  let end = calendar.date(from: DateComponents(year: selectedYear + 1, month: 1, day: 1))
            else { return library.assets }
            return library.assets.filter {
                let date = $0.creationDate ?? .distantPast
                return date >= start && date < end
            }
        }
    }

    private var periods: [PeriodUsage] {
        StorageBreakdown.periods(filteredAssets, granularity: granularity)
    }

    var body: some View {
        content(periods)
    }

    /// 周期数据只计算一次，传给各卡片复用（避免 body 内多次全量分组）
    private func content(_ items: [PeriodUsage]) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                rangeCard(items)
                granularityCard
                chartCard(items)
                listCard(items)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("按日期占用")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !availableYears.contains(selectedYear), let first = availableYears.first {
                selectedYear = first
            }
        }
        .onChange(of: granularity) { _ in listLimit = 200 }
        .onChange(of: range) { _ in listLimit = 200 }
        .onChange(of: selectedYear) { _ in listLimit = 200 }
    }

    // MARK: - 区间

    private func rangeCard(_ items: [PeriodUsage]) -> some View {
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        let count = items.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 10) {
            Text("时间范围")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(RangeMode.allCases) { mode in
                    FilterChip(
                        title: mode.title,
                        isOn: Binding(
                            get: { range == mode },
                            set: { if $0 { range = mode } }
                        )
                    )
                }
                if range == .year {
                    Menu {
                        ForEach(availableYears, id: \.self) { year in
                            Button {
                                selectedYear = year
                            } label: {
                                if selectedYear == year {
                                    Label("\(year) 年", systemImage: "checkmark")
                                } else {
                                    Text("\(year) 年")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(selectedYear) 年")
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundColor(.accentColor)
                    }
                }
            }

            HStack {
                Text("共 \(count) 项")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file))
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 粒度

    private var granularityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("统计粒度")
                .font(.headline)
            Picker("统计粒度", selection: $granularity) {
                ForEach(DateGranularity.allCases) { item in
                    Text(item.unitTitle).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 柱状图

    private func chartCard(_ items: [PeriodUsage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("占用趋势")
                    .font(.headline)
                Spacer()
                if let newest = items.first {
                    Text("最新：\(newest.sizeText)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if items.isEmpty {
                Text("该时间范围内没有照片")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                StorageBarChart(periods: items) { period in
                    jump(to: period)
                }
                Text("点击柱子或下方列表 → 跳转到首页对应日期")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 列表（按占用空间从大到小）

    private func listCard(_ items: [PeriodUsage]) -> some View {
        // 年 / 月 / 日粒度统一：列表按占用空间从大到小排列（柱状图仍按日期倒序展示趋势）
        let sorted = items.sorted { $0.bytes > $1.bytes }
        let shown = Array(sorted.prefix(listLimit))
        return VStack(spacing: 0) {
            HStack {
                Text("按占用空间排序")
                    .font(.headline)
                Spacer()
                Text("从大到小 · \(granularity.unitTitle)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            if items.isEmpty {
                Text("暂无数据")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            } else {
                ForEach(shown) { period in
                    Button {
                        jump(to: period)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(period.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.primary)
                                Text("\(period.count) 项")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(period.sizeText)
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if period.id != shown.last?.id {
                        Divider().padding(.leading)
                    }
                }

                if items.count > listLimit {
                    Button {
                        listLimit += 200
                    } label: {
                        Text("显示更多（剩余 \(items.count - listLimit) 个）")
                            .font(.footnote)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 跳转首页

    private func jump(to period: PeriodUsage) {
        // 带上周期结束时间：年/月/日粒度都能精确定位到该周期内的照片
        appState.jumpToHome(start: period.start, end: period.end)
    }
}
