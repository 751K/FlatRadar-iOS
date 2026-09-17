# 开发方向

每个版本要做什么、做完没有。理由、取舍和实现细节写在代码注释和提交信息里，不写这儿。
（这份文档 2026-09-06 之前是一份带完整分析的长文，需要的话去 git 历史里翻。）

## 2.2.0（进行中）

| 目标 | 状态 |
|---|---|
| Core 迁成本地 SwiftPM 包（macOS 版的前置条件，见 [MACOS.md](MACOS.md) Phase 0） | 完成 |
| macOS 客户端：见 [MACOS.md](MACOS.md)。Phase 1 起没有截止日期，也不阻塞本版发布 | Phase 1 进行中 |
| 桌面 / 主屏小组件：今日新增 + 未读为锚点，另一格日历。不做房源列表 | Mac 端完成（两格 × 三档），iOS 未开始 |
| AI 筛选：自然语言 → `ListingFilter`。入口只在 `SystemLanguageModel` 可用时出现 | 未开始 |
| App 图标：浅色和 tinted 两张重导，去掉烤进 PNG 的白圆角，tinted 改灰度 | 未开始 |
| iPad `NavigationSplitView`：横屏点房源不再把列表整个顶掉 | 未开始 |

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
