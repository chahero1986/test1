import SwiftUI

/// 设置：主题 / 排序 / 定位上次位置 / 跳过免删除 / 恢复默认
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showResetConfirm = false
    @State private var showUpdateAlert = false

    static let appVersion = "V2026.1103"

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

            Section {
                Toggle(isOn: $appState.settings.resumeToLastPosition) {
                    Label("定位到上次操作位置", systemImage: "location.magnifyingglass")
                }
                Toggle(isOn: $appState.settings.skipProtectedItems) {
                    Label("跳过免删除项目", systemImage: "hand.raised")
                }
            } footer: {
                Text("排序与首页显示方式已移至「筛选」面板中设置。开启「跳过免删除项目」后，批量删除会自动排除被标记为免删除的项目。")
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("所有数据处理均在本地完成，不会上传任何照片")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.red)

                    HStack {
                        Text(Self.appVersion)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("检查更新") {
                            showUpdateAlert = true
                        }
                        .font(.footnote)
                    }

                    HStack {
                        Text("邮箱")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("386047639@qq.com")
                            .textSelection(.enabled)
                    }
                    HStack {
                        Text("微信")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("graphite1")
                            .textSelection(.enabled)
                    }
                    Text("京ICP备XXXXXXX号")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("检查更新", isPresented: $showUpdateAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("当前已是最新版本 \(Self.appVersion)")
        }
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
