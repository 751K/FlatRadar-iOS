import SwiftUI
import AppKit

/// 正常登录窗口的尺寸切换；截图模式继续由 ScreenshotMode 管理。
struct WindowSizer: NSViewRepresentable {
    enum Phase { case restoring, signIn, browser }
    let phase: Phase

    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        view.phase = phase
        if ScreenshotMode.isOn {
            for delay in [0.0, 0.1, 0.3, 0.6, 1.0, 1.5, 2.5, 4.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                    guard let window = view?.window else { return }
                    ScreenshotMode.pin(window)
                }
            }
        } else {
            view.scheduleResize()
        }
    }

    final class SizingView: NSView {
        var phase: Phase = .restoring
        private let transition = WindowSizeTransition()
        private var resizeScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 首次 updateNSView 时可能尚未挂到窗口，挂载完成后补做。
            if !ScreenshotMode.isOn { scheduleResize() }
        }

        func scheduleResize() {
            guard !resizeScheduled else { return }
            resizeScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resizeScheduled = false
                guard let window = self.window else { return }
                // 读最新状态，不能让登录前排队的回调在登录后又把窗口缩小。
                self.transition.apply(self.phase, to: window)
            }
        }
    }
}

@MainActor
final class WindowSizeTransition {
    static let signInSize = NSSize(width: 900, height: 620)
    static let browserSize = NSSize(width: 1440, height: 900)
    private weak var window: NSWindow?
    private var lastPhase: WindowSizer.Phase?
    private var restoreTo: NSSize?

    func apply(_ phase: WindowSizer.Phase, to window: NSWindow) {
        if self.window !== window {
            self.window = window
            lastPhase = nil
            restoreTo = nil
        }
        guard phase != .restoring, phase != lastPhase else { return }

        // setContentSize 接受 contentRect 的尺寸；contentLayoutRect 还扣除了
        // 标题栏/工具栏。混用会导致每次更新都认为尺寸不对，并覆盖已保存的尺寸。
        let current = window.contentRect(forFrameRect: window.frame).size
        let target: NSSize?
        switch phase {
        case .signIn:
            if lastPhase == nil, current == Self.signInSize {
                // 上次退出时停在登录页，没有可恢复的主窗口大小。
                let available = window.screen.map {
                    window.contentRect(forFrameRect: $0.visibleFrame).size
                } ?? Self.browserSize
                restoreTo = NSSize(width: min(Self.browserSize.width, available.width),
                                   height: min(Self.browserSize.height, available.height))
            } else {
                restoreTo = current
            }
            target = Self.signInSize
        case .browser:
            target = restoreTo
            restoreTo = nil
        case .restoring:
            return
        }
        lastPhase = phase
        guard let target, current != target else { return }
        window.setContentSize(target)
        window.center()
    }
}
