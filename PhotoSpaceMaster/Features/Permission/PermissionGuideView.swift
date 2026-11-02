import SwiftUI
import UIKit

/// 相册权限被拒时的引导页
struct PermissionGuideView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("需要相册访问权限")
                .font(.title3.weight(.semibold))

            Text("相册空间大师需要在本地读取您的照片，才能进行浏览、筛选和清理。\n\n所有处理均在设备内完成，我们不会上传任何照片。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("去设置开启权限", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
