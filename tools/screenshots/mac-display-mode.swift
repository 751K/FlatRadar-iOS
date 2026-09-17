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
// 屏幕要是能调大，窗口就能拿到首选的 1440×900 点，合成时画布正好等于图。
//
// **但在 Xcode Cloud 上调不成**，见下面选择逻辑那段：那台机器 2x 模式里点尺寸
// 最大的就是默认的 1280×800，更大的点尺寸全是 1x，换过去等于拿分辨率换面积。
// 所以这个工具在那儿的实际作用是**把模式表打进日志并保持现状**——结论有据，
// 不是没试过。
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

// 挑一个：点尺寸要放得下 1440×900 的窗口（加菜单栏和 Dock 的余量），
// 而且**不能是降级**。
//
// 后面这一条是 build 373 实测出来的。Xcode Cloud 那台 `VirtualMac2,1` 给了 26 个
// 模式，但 2x 的里面点尺寸最大的就是它默认那个 1280×800（= 2560×1600 像素）；
// 点尺寸更大的 1344 / 1600 / 1920 / 2048 / 2560 **全是 1x**。
//
// 也就是说这块虚拟显示器的**像素**上限就是 2560×1600，点尺寸再大只能拿缩放去换：
//
//     现在             窗口 1280×692 点 @2x → 2560×1384 像素（+108 像素白边）
//     切 1600×1200@1x  窗口 1440×900 点 @1x → 1440×900 像素（无白边）
//
// 两个都是合法尺寸，但后者清晰度差一截——**带白边的 2560×1600 更好**。所以这里
// 要求新模式的像素数和缩放都不低于当前，宁可保持现状。
//
// （第一版没有这条判据，373 的第一趟真的切到了 1600×1200@1x。之所以没造成后果，
// 是因为两趟不共享 /tmp、第二趟没能执行——纯属侥幸。）
let needWidth = 1440
let needHeight = 900 + 120

let current = CGDisplayCopyDisplayMode(display)
let currentPixels = (current?.pixelWidth ?? 0) * (current?.pixelHeight ?? 0)
let currentScale = (current?.pixelWidth ?? 1) / max(current?.width ?? 1, 1)

let candidates = modes
    .filter { $0.width >= needWidth && $0.height >= needHeight }
    .filter { $0.pixelWidth * $0.pixelHeight >= currentPixels }
    .filter { $0.pixelWidth / max($0.width, 1) >= currentScale }
    .sorted { a, b in
        // 先挑点尺寸最小的够用模式；点尺寸相同时优先像素多的那个（2x）。
        if a.width != b.width { return a.width < b.width }
        if a.height != b.height { return a.height < b.height }
        return a.pixelWidth > b.pixelWidth
    }

guard let best = candidates.first else {
    print("› [display] 没有既 ≥\(needWidth)×\(needHeight) 点、又不降低像素数和缩放的模式，保持现状")
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
