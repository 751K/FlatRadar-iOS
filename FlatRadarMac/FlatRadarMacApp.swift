import SwiftUI
import FlatRadarCore

/// macOS 探针入口。
///
/// 这一版**只用来编译**：把 `FlatRadarCore/` 直接编进 Mac target，让编译器
/// 把跨平台边界报出来，作为 Phase 0 公开接口和适配点的依据。真正的登录窗口
/// 是 Phase 1 的事，见 `docs/MACOS.md`。
@main
struct FlatRadarMacApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
                .task { PlatformEnvironment.configure(.macOS) }
        }
        .defaultSize(width: 520, height: 360)
    }
}

private struct ProbeView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("FlatRadar for Mac").font(.largeTitle.weight(.semibold))
            Text("Phase 1 探针 · 只验证 Core 能不能编过")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
