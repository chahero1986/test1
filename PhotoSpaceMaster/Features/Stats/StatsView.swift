import SwiftUI

/// Tab 3：清理和统计
struct StatsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore

    @State private var totals = CleanupTotals()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCards
                storageCard
                entriesCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("清理和统计")
        .onAppear { totals = StatsRecorder.totals() }
        .onDisappear { totals = StatsRecorder.totals() }
    }

    // MARK: - 统计卡片

    private var summaryCards: some View {
        HStack(spacing: 12) {
            statCard(title: "累计释放空间", value: totals.totalBytesText, icon: "arrow.down.circle.fill", color: .green)
            statCard(title: "累计删除项目", value: "\(totals.totalCount) 项", icon: "trash.circle.fill", color: .orange)
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 存储分析（横向占比条）

    private var storageCard: some View {
        let bytesByKind = StatsRecorder.currentLibraryBytesByKind(library.assets)
        let total = bytesByKind.values.reduce(Int64(0), +)
        let kinds = MediaKind.allCases.filter { (bytesByKind[$0] ?? 0) > 0 }

        return VStack(alignment: .leading, spacing: 12) {
            Text("存储分析")
                .font(.headline)

            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(kinds, id: \.self) { kind in
                        let ratio = total > 0 ? CGFloat(bytesByKind[kind] ?? 0) / CGFloat(total) : 0
                        Rectangle()
                            .fill(Color(hex: kind.barColorHex))
                            .frame(width: max(2, proxy.size.width * ratio))
                    }
                    if total == 0 {
                        Rectangle().fill(Color(.systemGray5))
                    }
                }
            }
            .frame(height: 14)
            .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 6) {
                ForEach(kinds, id: \.self) { kind in
                    HStack {
                        Circle().fill(Color(hex: kind.barColorHex)).frame(width: 8, height: 8)
                        Text(kind.title).font(.subheadline)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: bytesByKind[kind] ?? 0, countStyle: .file))
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 列表入口

    private var entriesCard: some View {
        VStack(spacing: 0) {
            entryRow(mode: .largeVideo, title: "大视频", subtitle: "按文件大小降序", icon: "video.fill", color: .purple)
            Divider().padding(.leading)
            entryRow(mode: .screenRecording, title: "大录屏", subtitle: "识别录屏类型", icon: "display", color: .red)
            Divider().padding(.leading)
            entryRow(mode: .largePhoto, title: "大图片", subtitle: "按文件大小降序", icon: "photo.fill", color: .blue)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func entryRow(mode: LargeItemsMode, title: String, subtitle: String, icon: String, color: Color) -> some View {
        NavigationLink {
            LargeItemsView(mode: mode)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(.primary)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .padding()
        }
    }
}

// MARK: - Color hex 扩展

extension Color {
    init(hex: String) {
        let value = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
