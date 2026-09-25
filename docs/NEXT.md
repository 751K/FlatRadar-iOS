# 开发方向

每个版本要做什么、做完没有。理由、取舍和实现细节写在代码注释和提交信息里，不写这儿。
（这份文档 2026-09-06 之前是一份带完整分析的长文，需要的话去 git 历史里翻。）

## 2.3.0（进行中；Mac 1.1.0 进行中）

| 目标 | 状态 |
|---|---|
| AI 筛选：自然语言 → `ListingFilter`。入口只在 `SystemLanguageModel` 可用时出现 | 未开始 |
| iPad `NavigationSplitView`：横屏点房源不再把列表整个顶掉 | 已实现 Listings 两栏、选中高亮及与窄窗口共用详情路径；iPad 分栏与统一底色已确认，顶部模糊效果已关闭，待完整回归 |
| 日历改用 SwiftUI：自适应宽度、横向滑动翻月 | 已实现，待完整回归 |
| iPhone Duo 适配 | 进行中：登录页宽度与横屏布局已调整；外屏侧栏及内屏竖屏已将 Browse 展开为 Listings / Map / Calendar 一级标签；其余页面及真机待验 |

## 2.2.0（已发布；Mac 1.0.1 已上架）

| 目标 | 状态 |
|---|---|
| Core 迁成本地 SwiftPM 包（macOS 版的前置条件，见 [MACOS.md](MACOS.md) Phase 0） | 完成 |
| macOS 客户端：见 [MACOS.md](MACOS.md)。原生 Mac 客户端及上架流程已完成 | Mac 1.0.1 已上架 |
| 桌面 / 主屏 / 锁屏小组件：照 `FlatRadar Widgets.dc.html` 做。~~不做房源列表~~——设计稿的中 / 大号有 NEWEST 三行，推翻了这一条 | 完成（Mac 三格 / iOS 两格 + 锁屏三种；锁屏排版待真机验） |
| App 图标：浅色和 tinted 两张重导，去掉烤进 PNG 的白圆角，tinted 改灰度 | 完成 |
| AI 筛选：自然语言 → `ListingFilter`。入口只在 `SystemLanguageModel` 可用时出现 | 未完成，顺延至 2.3.0 |
| iPad `NavigationSplitView`：横屏点房源不再把列表整个顶掉 | 未完成，顺延至 2.3.0 |

## 2.1.1（已发布，build 313）

| 目标 | 状态 |
|---|---|
| 修 2.1.0 启动无限崩溃：MetricKit 回调撞 MainActor 隔离断言（`3f5cd4a`） | 完成 |

## 2.1.0（已发布，build 312 —— 启动即崩，已被 2.1.1 取代）

| 目标 | 状态 |
|---|---|
| 最低支持版本升到 iOS 18.0 | 完成 |
| Xcode 27 迁移：`Shape` conformance 隔离、50 处 `nonisolated` | 完成 |
| iPad 适配：`Tab {}` builder、Dashboard / Explore / 详情页分栏、地图控件按 HIG 分档 | 完成 |
| 地图 POI（超市 / 学校 / 公共交通）+ 10 分钟步行 / 骑行可达圈 | 完成 |
| 系统版本上报：`os_version` 随 `/devices/register` 发，后端落库 | 完成 |
| 登录失败显示后端给的具体原因 | 完成 |
