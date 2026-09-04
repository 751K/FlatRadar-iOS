# FlatRadar for iOS

荷兰多平台租房监控 [FlatRadar](https://flatradar.app) 的 iOS 客户端。SwiftUI，
连接后端的 `/api/v1/*`。

[App Store](https://apps.apple.com/us/app/flarradar/id6769857080)

后端、Web 前台与抓取管线在另一个仓库：
[751K/holland2stay-monitor](https://github.com/751K/holland2stay-monitor)。

## 跨仓库的那条线

这个仓库和后端之间只有一份契约：后端仓库里的 `docs/openapi.json`。

拆仓之前，改后端和改 iOS 是同一个 commit，接口对不对由编译和人眼一起兜着。
现在不是了——后端加一个字段、改一个枚举，这边不会有任何反应，直到运行时。
所以后端那侧有一条测试从 Flask 的 `app.url_map` 反推路由集合，双向比对
`openapi.json`：后端多一条会红，spec 多一条也会红。**改动接口时以那份 spec
为准**，它落后于后端时那条测试会先叫。

## 目录

```text
FlatRadar.xcodeproj/         # 项目文件在仓库根
FlatRadar/                   # App 源码
├── FlatRadarApp.swift       #   入口、environment 注入
├── Models/                  #   Codable 模型与展示辅助
├── Networking/              #   APIClient / APIError / SSE / Keychain
├── Stores/                  #   @Observable 状态与业务逻辑
├── Navigation/              #   tab / path / deep link
├── Push/                    #   APNs delegate 桥接
├── Views/                   #   SwiftUI 界面
├── FlatRadar.xctestplan     #   默认计划：单元测试 + UI 测试
└── Screenshots.xctestplan   #   截图计划：5 种语言各一个 configuration
FlatRadarTests/              # 单元测试
FlatRadarUITests/            # UI 测试（含 App Store 截图自动化）
ci_scripts/                  # Xcode Cloud 钩子——必须紧挨 .xcodeproj
scripts/                     # 模拟器挑选、xcresult 解析、截图提取与校验（Python）
tests/                       # scripts/ 与 CI 配置的 pytest
tools/asc/                   # App Store Connect API 工具 + 官方 OpenAPI 规格
tools/screenshots/           # 本地跑截图的封装
tools/upload/                # 本地 archive + 上传
```

## 开发

```bash
open FlatRadar.xcodeproj
```

跑 `FlatRadar` scheme。默认 test plan 同时包含单元测试和 UI 测试。

Python 侧：

```bash
python3 -m pytest
```

这些测试守的是 CI 配置本身——比如「scheme 指向的 test plan 里到底有没有单元
测试 target」。少了它们，`xcodebuild test` 可以一边报 Test Succeeded 一边一条
都没跑。

## CI

| 工作流 | 触发 | 做什么 |
|---|---|---|
| `ios.yml` | 每次 push / PR | 单元测试 |
| `screenshots.yml` | 手动 | 5 种语言 × 2 种设备的 App Store 截图 |
| `release.yml` | 手动 | archive + 上传 TestFlight |

另有 **Xcode Cloud** 跑同一套截图，比 GitHub 的 runner 快一个量级（同一套七条
用例：1 分 28 秒 vs 数十分钟）。它的凭据经 `ci_scripts/ci_post_clone.sh` 注入
到 test plan——因为 Xcode Cloud 禁止用 `TEST_RUNNER_` 前缀命名环境变量，而
`xcodebuild` 只转发带这个前缀的变量。那个脚本里写了完整缘由。

## 仓库是公开的

任何凭据都不进仓库。CI 用 GitHub Secrets / Xcode Cloud 的 Secret 环境变量；
本地用 `~/.config/asc/`。截图测试拿不到凭据时自动退回访客模式，只是
Notifications 那一屏拍不到。

## 维护范围

这个 App 在当前产品范围内功能完整，处于维护状态。新的跨平台行为先在后端的
`docs/API.md` 定下来，再各端实现。

- 兼容新版 iOS / Xcode
- 崩溃、导航、通知、接口契约的修复
- App Store 元数据、隐私与法律文本
- 与共享产品保持一致的小幅界面调整
- 安全与依赖卫生

法律文本以后端接口为准，App 内的本地文案只作兜底。列表与图表模型要能容忍未知
字段——后端新增字段不应该逼出一个 iOS 版本，除非界面要展示它。
