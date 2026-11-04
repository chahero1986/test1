import SwiftUI

/// 筛选条件胶囊按钮
struct FilterChip: View {
    let title: String
    var icon: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.caption)
                }
                Text(title).font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isOn ? Color.accentColor.opacity(0.18) : Color(.secondarySystemFill))
            .foregroundColor(isOn ? .accentColor : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 筛选面板：5 个分组，组间「与」、组内「或」；默认「所有项目」；支持重置；会话内保持。
struct FilterPanelView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    scopeSection
                    sortSection
                    layoutSection
                    markerSection
                    sourceSection
                    typeSection
                    albumSection
                    resetButton
                }
                .padding()
            }
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 分组1 项目范围（单选，默认选中；点击即重置全部）

    private var scopeSection: some View {
        section("项目范围") {
            FilterChip(
                title: "所有项目",
                isOn: Binding(
                    get: { appState.filter.isDefault },
                    set: { if $0 { appState.filter = PhotoFilter() } }
                )
            )
            if appState.filter.hasActiveConditions {
                Text("已启用其他条件，与「所有项目」取交集")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 排序（正序 / 倒序，自设置迁入）

    private var sortSection: some View {
        section("排序") {
            ForEach(SortOrder.allCases) { order in
                FilterChip(
                    title: order.title,
                    icon: order.icon,
                    isOn: Binding(
                        get: { appState.settings.sortOrder == order },
                        set: { if $0 { appState.settings.sortOrder = order } }
                    )
                )
            }
        }
    }

    // MARK: - 首页显示方式（按日期分组 / 平铺）

    private var layoutSection: some View {
        section("首页显示方式") {
            ForEach(HomeLayout.allCases) { layout in
                FilterChip(
                    title: layout.title,
                    icon: layout.icon,
                    isOn: Binding(
                        get: { appState.settings.homeLayout == layout },
                        set: { if $0 { appState.settings.homeLayout = layout } }
                    )
                )
            }
            if appState.settings.homeLayout == .byDate {
                Text("按拍摄日期分组显示，每组顶部显示日期标题")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if appState.settings.homeLayout == .unified {
                Text("与系统相册一致的统一方块网格（固定三列），不显示日期标题")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 分组2 标记（收藏 OR 星级）

    private var markerSection: some View {
        section("标记") {
            FilterChip(
                title: "收藏",
                icon: "heart.fill",
                isOn: Binding(
                    get: { appState.filter.favorite },
                    set: { appState.filter.favorite = $0 }
                )
            )
            ForEach(1...5, id: \.self) { stars in
                FilterChip(
                    title: "\(stars) 星",
                    icon: "star.fill",
                    isOn: Binding(
                        get: { appState.filter.ratings.contains(stars) },
                        set: { on in
                            if on { appState.filter.ratings.insert(stars) }
                            else { appState.filter.ratings.remove(stars) }
                        }
                    )
                )
            }
        }
    }

    // MARK: - 分组3 来源

    private var sourceSection: some View {
        section("来源") {
            ForEach(FilterSource.allCases) { source in
                FilterChip(
                    title: source.title,
                    isOn: Binding(
                        get: { appState.filter.sources.contains(source) },
                        set: { on in
                            if on { appState.filter.sources.insert(source) }
                            else { appState.filter.sources.remove(source) }
                        }
                    )
                )
            }
        }
    }

    // MARK: - 分组4 类型

    private var typeSection: some View {
        section("类型") {
            ForEach(FilterType.allCases) { type in
                FilterChip(
                    title: type.title,
                    icon: type.icon,
                    isOn: Binding(
                        get: { appState.filter.types.contains(type) },
                        set: { on in
                            if on { appState.filter.types.insert(type) }
                            else { appState.filter.types.remove(type) }
                        }
                    )
                )
            }
        }
    }

    // MARK: - 分组5 相簿归属

    private var albumSection: some View {
        section("相簿归属") {
            ForEach(FilterAlbumMembership.allCases) { membership in
                FilterChip(
                    title: membership.title,
                    isOn: Binding(
                        get: { appState.filter.albumMembership.contains(membership) },
                        set: { on in
                            if on { appState.filter.albumMembership.insert(membership) }
                            else { appState.filter.albumMembership.remove(membership) }
                        }
                    )
                )
            }
        }
    }

    // MARK: - 重置

    private var resetButton: some View {
        Button {
            appState.filter = PhotoFilter()
        } label: {
            Label("重置筛选", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .disabled(appState.filter.isDefault)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            FlowLayout(spacing: 8) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 流式布局（iOS 16 Layout 协议）：胶囊按行排列、放不下自动换行

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : max(0, x - spacing)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: .unspecified
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
