import Foundation
import MetricKit

/// 用 MetricKit 收集本机崩溃 / 卡顿 / CPU 异常 / 写满磁盘 等系统级诊断。
///
/// 工作原理
/// --------
/// 用户开了 iOS 系统的"与开发者共享分析数据"开关时，操作系统会在你 App
/// **下一次启动**时（通常 24h 窗口内）调用 ``MXMetricManagerSubscriber``
/// 的 ``didReceive(_ payloads: [MXDiagnosticPayload])`` 回调。
///
/// 我们在这个回调里：
/// 1. 把每一份诊断 payload 用 ``MXDiagnosticPayload.jsonRepresentation()``
///    序列化为 JSON Data
/// 2. 写入沙盒 ``Application Support/Diagnostics/`` 目录，文件名带时间戳 + UUID
/// 3. 等用户在下次启动时点 alert "Send"（``CrashDiagnosticsPrompt``）→ 上传
///    → 上传成功后删除本地副本；用户拒绝 → 把文件 rename 为 ``.declined``
///    保留 7 天供调试，之后清理（避免狂攒磁盘）
///
/// 隐私
/// ----
/// MetricKit 的 payload 只含堆栈帧、信号、设备型号、iOS 版本，**不含**用户
/// 内容、URL、网络。Apple 保证。我们在 UI 上向用户明示后再上传。
///
/// 并发
/// ----
/// **必须显式写 `nonisolated`。** 本 target 开了
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不写的话整个类被推断成
/// `@MainActor`；而 `MXMetricManagerSubscriber` 是从 ObjC 头文件导入的
/// `@preconcurrency` 协议，编译器会给 didReceive 生成一个 @objc witness
/// thunk，在真正调用前插 `_checkExpectedExecutor(MainActor)`。
/// MetricKit 是在自己选的后台 dispatch 队列上回调的，这个检查必然不过：
///
///     _dispatch_assert_queue_fail  →  __builtin_trap
///     EXC_BREAKPOINT / SIGTRAP（signal 5）
///
/// 于是「收集崩溃的模块自己崩溃」，而且崩在 didReceive 里 ——
/// 报告写不进盘，这次崩溃连同它想上报的那次一起丢掉。
/// 2026-09-06 线上实测崩过（build 199，iPhone17,1 / iOS 27.0）。
///
/// 标了 `nonisolated` 之后，didReceive 里做的全是文件 IO（`FileManager`
/// 这几个调用线程安全）+ 一次 notification post，post 见
/// ``postPendingChanged()`` —— 它负责回主线程，因为 UI 层是用
/// `.onReceive` 接的，而 NotificationCenter 的 publisher 在**谁 post 就在谁
/// 那个线程**同步派发，直接在后台 post 会变成后台写 SwiftUI `@State`。
nonisolated final class CrashDiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = CrashDiagnosticsCollector()

    /// 用 @Observable 模式让 SwiftUI 视图能 reactively 知道"有几份诊断待审批"。
    /// 这里不用 @Observable 因为类要继承 NSObject + MXMetricManagerSubscriber，
    /// 改用 NotificationCenter post，让 UI 层用 .onReceive 接听变化。
    static let pendingChangedNotification = Notification.Name("CrashDiagnosticsPendingChanged")

    private let directory: URL
    private let fileManager = FileManager.default
    /// 只用来格式化时间戳。`.iso8601` 的默认参数等价于
    /// `.withInternetDateTime`（见 ``ServerTime`` 里的说明）。
    private let isoStyle = Date.ISO8601FormatStyle()

    override init() {
        // ~/Library/Application Support/FlatRadar/Diagnostics/
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let base = appSupport ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("FlatRadar/Diagnostics", isDirectory: true)
        self.directory = dir
        super.init()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 在 App 启动尽早调用一次（FlatRadarApp.init 即可）。
    /// 注册到 MXMetricManager 后，操作系统会在 next launch 把待交付的
    /// payloads 通过 didReceive 回调推过来——可能在任何时机（启动后几秒内
    /// 或 24h 内某次回到前台），UI 层不该假设特定时机。
    func start() {
        MXMetricManager.shared.add(self)
    }

    // MARK: - MXMetricManagerSubscriber

    /// 性能 metrics（CPU/内存/电量）—— 暂不持久化，仅 DEBUG 日志一下。
    /// 如果将来要做 perf dashboard 再 hook 这里。
    func didReceive(_ payloads: [MXMetricPayload]) {
        #if DEBUG
        print("[Diagnostics] 收到 metrics payload x\(payloads.count)")
        #endif
    }

    /// 诊断 payloads —— 这是真正的崩溃 / hang / CPU exception / 磁盘写满信号。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            // jsonRepresentation 返回的是 Apple 标准化的 JSON Data，
            // 含 timeStampBegin/End、crashDiagnostics[]、hangDiagnostics[] 等
            let data = payload.jsonRepresentation()

            // 分类：取 payload 中第一个 crash/hang 决定 kind；
            // iOS 26+ 中 crash 可能封装在 appLaunchDiagnostics 里
            let kind: String
            if let _ = payload.crashDiagnostics?.first {
                kind = "crash"
            } else if let _ = payload.hangDiagnostics?.first {
                kind = "hang"
            } else if let _ = payload.cpuExceptionDiagnostics?.first {
                kind = "cpuexception"
            } else if let _ = payload.diskWriteExceptionDiagnostics?.first {
                kind = "diskwrite"
            } else if let _ = payload.appLaunchDiagnostics?.first {
                kind = "launch"  // iOS 26+ 崩溃/挂起经启动诊断上报
            } else {
                kind = "other"
            }

            let stamp = isoStyle.format(Date())
                .replacingOccurrences(of: ":", with: "")  // 文件名安全
            let filename = "\(stamp)-\(kind)-\(UUID().uuidString.prefix(8)).json"
            let url = directory.appendingPathComponent(filename)

            do {
                // 原子写入：先写 .tmp 再 rename，宕机不留半文件
                let tmp = url.appendingPathExtension("tmp")
                try data.write(to: tmp, options: .atomic)
                try fileManager.moveItem(at: tmp, to: url)
                #if DEBUG
                print("[Diagnostics] 写入 \(kind) 报告: \(filename)")
                #endif
            } catch {
                #if DEBUG
                print("[Diagnostics] 写入失败: \(error)")
                #endif
            }
        }
        if !payloads.isEmpty {
            postPendingChanged()
        }
    }

    /// 发「待审批数量变了」通知，保证在主线程发。
    ///
    /// NotificationCenter 的 Combine publisher 是同步派发的：post 在哪个线程，
    /// `.onReceive` 的闭包就在哪个线程跑。UI 层那个闭包会改 `@State`，
    /// 所以 didReceive（后台队列）这条路必须先跳回主线程。
    /// 已经在主线程时同步发，保持原来的时序（UI 操作后立刻生效）。
    private func postPendingChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(
                name: Self.pendingChangedNotification, object: nil
            )
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.pendingChangedNotification, object: nil
                )
            }
        }
    }

    // MARK: - Pending diagnostics inventory

    struct PendingDiagnostic: Identifiable, Hashable {
        let id: String          // filename
        let url: URL
        let kind: String        // crash / hang / cpuexception / diskwrite / other
        let receivedAt: Date    // 文件创建时间
    }

    /// 列出所有"未决"诊断（不含 .declined / .uploaded 后缀）。
    func pendingDiagnostics() -> [PendingDiagnostic] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".declined") }
            .compactMap { url in
                let comps = url.deletingPathExtension().lastPathComponent.split(separator: "-")
                // 文件名格式：<isoStamp>-<kind>-<uuid8>
                // isoStamp 如 2026-05-31T185748Z 含 `-`，从右往左取 kind
                let kind = comps.count >= 2 ? String(comps[comps.count - 2]) : "other"
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                return PendingDiagnostic(
                    id: url.lastPathComponent,
                    url: url,
                    kind: kind,
                    receivedAt: date
                )
            }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    var hasPending: Bool { !pendingDiagnostics().isEmpty }

    /// 读出 payload 原始 JSON（用于上传 body）。
    func readPayload(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// 上传成功 → 物理删除文件（不留垃圾）。
    func markUploaded(_ diagnostic: PendingDiagnostic) {
        try? fileManager.removeItem(at: diagnostic.url)
        postPendingChanged()
    }

    /// 用户拒绝 → 重命名为 .declined.json，保留作本地引用；
    /// 7 天后由 pruneOldDeclined() 物理清理。
    func markDeclined(_ diagnostic: PendingDiagnostic) {
        let declined = diagnostic.url
            .deletingPathExtension()
            .appendingPathExtension("declined.json")
        try? fileManager.moveItem(at: diagnostic.url, to: declined)
        postPendingChanged()
    }

    /// 批量"全部拒绝"。
    func markAllDeclined() {
        for d in pendingDiagnostics() {
            markDeclined(d)
        }
    }

    /// 删除超过 ``days`` 的 .declined 文件 + 上传失败后残留的旧文件。
    /// 应用启动时调一次即可。
    func pruneOldDeclined(days: Int = 7) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for url in files {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if created < cutoff && url.lastPathComponent.contains(".declined") {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
