import SwiftUI

/// 恢复会话期间的占位屏。
///
/// 为什么不直接显示登录页
/// --------------------
/// 因为用户是登录着的——`restoreSession()` 只是还没跑完（它要等一次 `getMe()`
/// 网络往返）。在那之前把登录表单摆出来，等于每次冷启动都先告诉人"你没登录"，
/// 然后再自己否掉。Mac 上还额外惹出一个系统弹窗，见
/// ``AuthStore/isRestoringSession``。
///
/// 转圈**延后 0.6 秒**才出现：本机恢复通常两三百毫秒就完了，让它闪一下再消失
/// 比不转还晃眼。真等久了（网络慢）才需要告诉用户"在做事"。
struct SessionRestoreView: View {

    @State private var showsSpinner = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if showsSpinner {
                ProgressView()
                    .controlSize(.large)
                    .transition(.opacity)
            }
        }
        // 这一屏没有内容可读，但读屏软件要知道现在在等什么。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signing you in")
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeIn(duration: 0.2)) { showsSpinner = true }
        }
    }
}
