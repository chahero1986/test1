import SwiftUI

/// 设置：主题 / 排序 / 定位上次位置 / 跳过免删除 / 恢复默认
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section("主题") {
                Picker(selection: $appState.settings.theme) {
                    ForEach(ThemeMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                } label: {
                    Label("外观", systemImage: "paintpalette")
                }
            }

            Section("排序") {
                Picker(selection: $appState.settings.sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Label(order.title, systemImage: order.icon).tag(order)
                    }
                } label: {
                    Label("时间线排序", systemImage: "arrow.up.arrow.down")
                }
            }

            Section {
                Toggle(isOn: $appState.settings.resumeToLastPosition) {
                    Label("定位到上次操作位置", systemImage: "location.magnifyingglass")
                }
                Toggle(isOn: $appState.settings.skipProtectedItems) {
                    Label("跳过免删除项目", systemImage: "hand.raised")
                }
            } footer: {
                Text("开启「跳过免删除项目」后，首页 / 相册 / 清理列表的批量删除会自动排除被标记为免删除的项目；垃圾箱内的删除不受此开关影响。")
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("恢复默认设置", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                        .foregroundColor(.secondary)
                }
                Text("所有数据处理均在本地完成，不会上传任何照片。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "确定恢复默认设置吗？主题、排序、定位、开关等全部项目将被重置。",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                appState.settings.resetToDefaults()
            }
            Button("取消", role: .cancel) {}
        }
    }
}
