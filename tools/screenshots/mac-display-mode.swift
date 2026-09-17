// 查看 / 设置主显示器的分辨率。
//
// 为什么需要它
// ------------
// Xcode Cloud 的 macOS 构建机是一台 `VirtualMac2,1`，屏幕实测
//
//     frame=(0,0,1280,800)  visible=(0,78,1280,692)  scale=2.0
//                                    ↑Dock 78      ↑菜单栏 30
//
// 1280×800 点是 ASC 最小合法尺寸（2x 下 = 2560×1600 像素）**正好**那么大，
// 也就是说窗口永远拿不满——菜单栏和 Dock 占掉的 108 点只能补白边。
//
// 屏幕要是能调大，窗口就能拿到首选的 1440×900 点，合成时画布正好等于图，
// 零留白、零重采样。
//
// 用法
// ----
//     swiftc -O mac-display-mode.swift -o mac-display-mode
//     ./mac-display-mode            # 只列出可用模式，什么都不改
//     ./mac-display-mode --apply    # 挑一个够大的切过去
//
// **默认不改**：在开发机上跑一下看看模式表是常见需求，而误改开发者自己的
// 分辨率是很讨厌的事。CI 那边显式传 --apply。

import CoreGraphics
import Foundation

let display = CGMainDisplayID()
let apply = CommandLine.arguments.contains("--apply")

// 要显示 HiDPI（2x）那些模式必须给这个选项，默认的列表里没有它们。
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
    print("› [display] 拿不到模式列表")
    exit(0)   // 不让 CI 因为这个挂掉
}

func describe(_ m: CGDisplayMode) -> String {
    let scale = m.pixelWidth / max(m.width, 1)
    return "\(m.width)×\(m.height) 点 / \(m.pixelWidth)×\(m.pixelHeight) 像素 (\(scale)x)"
}

if let current = CGDisplayCopyDisplayMode(display) {
    print("› [display] 当前：\(describe(current))")
}

print("› [display] 可用模式 \(modes.count) 个：")
for m in modes.sorted(by: { ($0.width, $0.pixelWidth) > ($1.width, $1.pixelWidth) }) {
    print("› [display]   \(describe(m))")
}

// 挑一个：点尺寸要放得下 1440×900 的窗口，再加上菜单栏和 Dock 的余量。
//
// 余量取 120 点（实测菜单栏 30 + Dock 78 = 108，留一点富余）。宽度不设上限但
// 优先挑**最小的够用的**——屏幕开太大反而让窗口在画面里显得小，而且截图只取
// 窗口那块，屏幕多出来的部分纯属浪费。
let needWidth = 1440
let needHeight = 900 + 120

let candidates = modes
    .filter { $0.width >= needWidth && $0.height >= needHeight }
    .sorted { a, b in
        // 先挑点尺寸最小的够用模式；点尺寸相同时优先像素多的那个（2x）——
        // 同样是 1440×900 点的窗口，2x 给出 2880×1800，1x 只给 1440×900，
        // 两个都合法但前者清晰得多。
        if a.width != b.width { return a.width < b.width }
        if a.height != b.height { return a.height < b.height }
        return a.pixelWidth > b.pixelWidth
    }

guard let best = candidates.first else {
    print("› [display] 没有 ≥\(needWidth)×\(needHeight) 点的模式，保持现状")
    exit(0)
}

print("› [display] 选中：\(describe(best))")
guard apply else {
    print("› [display] （只是查看，没有 --apply，不做改动）")
    exit(0)
}

var config: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&config) == .success else {
    print("› [display] CGBeginDisplayConfiguration 失败，保持现状")
    exit(0)
}
if CGConfigureDisplayWithDisplayMode(config, display, best, nil) != .success {
    print("› [display] CGConfigureDisplayWithDisplayMode 失败，撤销")
    CGCancelDisplayConfiguration(config)
    exit(0)
}
// `.forSession`：这台机器是一次性的，不用写进系统偏好。
if CGCompleteDisplayConfiguration(config, .forSession) != .success {
    print("› [display] 应用失败，保持现状")
    exit(0)
}

// 切换需要一点时间稳定下来。
Thread.sleep(forTimeInterval: 1.5)
if let now = CGDisplayCopyDisplayMode(display) {
    print("› [display] 切换后：\(describe(now))")
}
