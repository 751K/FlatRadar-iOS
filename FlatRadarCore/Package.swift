// swift-tools-version: 6.2
import PackageDescription

// 两端共享的模型 / 网络 / 业务状态。视图、窗口导航、系统 delegate 桥接留在各 app。
//
// 隔离设置必须写在这里，不会从 app target 继承：SE-0466 的默认隔离是**每个模块**
// 的编译设置，`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 只作用于 Xcode target。
// 迁移期保持与 app target 一致，避免 Core 的 @MainActor / nonisolated 语义漂移。
let package = Package(
    name: "FlatRadarCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v26)],
    products: [
        .library(name: "FlatRadarCore", targets: ["FlatRadarCore"])
    ],
    targets: [
        .target(
            name: "FlatRadarCore",
            resources: [.process("Resources")],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        // 测试 target **不开** 默认 MainActor 隔离。
        //
        // 这是照搬 Xcode 里的既有配置：`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
        // 只设在 app target 上，两个测试 target 都没有。开了会让 XCTestCase 子类
        // 变成 @MainActor，跟它 nonisolated 的 `init()` / `init(invocation:)` /
        // `init(selector:)` 冲突，8 个文件一共报 57 个 override 隔离错误。
        // 需要主线程的用例自己标 @MainActor。
        .testTarget(
            name: "FlatRadarCoreTests",
            dependencies: ["FlatRadarCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
