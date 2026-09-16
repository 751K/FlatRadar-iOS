# 设计规范：iOS 现状盘点 与 macOS 的换算

写于 2026-09-10，为动手画 Mac 界面做准备。

这份文档做两件事：

1. **把 iOS / iPadOS 端已经成型的设计规范从代码里抠出来写成文字。** 此前它只存在于
   `FlatRadar/Views/` 的 12506 行里，靠注释和记忆维持一致性——那对一个端够用，对两个端不够。
2. **说清哪些能原样带到 Mac、哪些带过去就是错的**，并回答「Mac 需要哪些页面」。

下面的数值除特别标注外都是**从代码里数出来的**，不是我想当然的取值。macOS 字阶那张表是
在这台机器上用 `NSFont.preferredFont(forTextStyle:)` 实测的（macOS 27.0 / 26A428）。
凡是转述代码注释里的结论（比如某个色对比度满足 AA），我都标了「注释称」——那不是我量的。

配套阅读：[MACOS.md](MACOS.md) 是任务书（做什么、分几步、判据），这份是**长什么样**。

---

## 一、颜色

### 1.1 语义 token（8 个，已在包里，两端唯一真相）

定义在 `FlatRadarCore/Sources/FlatRadarCore/Models/Color+Tokens.swift`，
资源在包的 `Resources/Colors.xcassets`，随 `Bundle.module` 走。
**Mac 已经能用，不需要再配一套。** 已实测 `FlatRadarMac.app` 里有这个 bundle。

| token | 语义 | 浅色 | 深色 |
|---|---|---|---|
| `statusBook` | Available to book —— 先到先得 | `#34C759` | `#30D158` |
| `statusLottery` | Available in lottery —— 抽签 | `#FF9500` | `#FF9F0A` |
| `statusReserved` | Reserved / In Process —— **暂时**订不了，可能回来 | `#3B82F6` | `#60A5FA` |
| `statusOccupied` | Occupied / Rented / Not available —— **终态** | `#8E8E93` | `#98989D` |
| `statusUnknown` | 认不出的状态 | `#8B5CF6` | `#A78BFA` |
| `energyTop` | A+++ / A++ | `#148C46` | `#2BAA63` |
| `energyAPlus` | A+ | `#34C759` | `#30D158` |
| `energyA` | A | `#8CC850` | `#A8DC68` |

三条**语义规则**，跟平台无关，Mac 上照抄：

- **Reserved 和 Occupied 必须是两个颜色。** 一个可能回来，一个永远不会。它们曾经共用一个灰，
  于是「有人占着，退订就放出来」和「已经租出去了」在界面上完全一样。
- **认不出的状态单独一档，不并进灰色。** 并进去的话，新平台冒出的新状态会跟着终态一起被
  筛选默认隐藏，**从界面上静默消失**。这是这个项目反复出现的那个形状：把「不知道」
  当成一个确定的答案。
- **能效色是一条光谱不是一组分类色。** 深绿 → 浅绿的明度递减本身在传达「越来越差」。

### 1.2 平台色（7 个）

`Platform.color(_:)`，用 SwiftUI 系统色，不进 Asset Catalog：

| holland2stay | ourdomain | ourcampus | xior | magis | studentexperience | plaza | 未知 |
|---|---|---|---|---|---|---|---|
| `.blue` | `.purple` | `.indigo` | `.teal` | `.pink` | `.orange` | `.brown` | `.gray` |

规则：**一个平台在任何页面、任何图表、任何排序下都是同一个颜色**，且刻意避开 status 那套
（那几个表示「能不能租」，用在平台上会误读）。OurCampus 取 indigo 是因为它和 OurDomain
同属一家，相邻色能看出亲缘。

### 1.3 强调色

`AccentColor.colorset` **是空的**——没配任何值，走系统默认蓝。这不是疏漏后的将就，
但也从没被当成决定记录过。Mac 上要不要给一个品牌强调色，是**待定项**（见第五节）。

登录页另有一套页面专属色，不是 token，也不该变成 token：见
`LoginView.swift` 里私有的 `SignInPalette`。原则是「跨文件复用才进 token，
屏幕专属的 chrome 留在原文件」。

2026-09-10 这套色**整体换过一次**（对齐设计稿 `FlatRadar iOS - Sign in.dc.html`）：
原来是自成一体的一套蓝（`brandBlue = #0A84FF` + 浅蓝 hero 渐变 + 手画的山脊），
和 App 图标没有任何关系，登录页看着像另一个 App。现在每个值都从图标里取——
暖底 `#F3F0E8` 就是图标里窗户的填充色，强调色 `#293B49` 是那栋深色房子，
深色模式反过来用点亮的窗黄 `#F5D99B`。插画也不再是手画的，直接由
`output/icon/make-signin-skyline.py` 从 `AppIcon.icon/Assets` 拼出来
（`tests/test_signin_skyline.py` 钉住两者不脱钩）。

二级文字是**实色不是透明度**，而且分冷暖两套：暖底上用暖灰 `#54504A`，白卡上
用冷灰 `#5A646F`。我头一版按设计稿早先的 `rgba(27,43,56,.62)` 写成
`ink.opacity(0.62)`，压在 `#F3F0E8` 上只有 4.0:1（低于 AA 的 4.5:1），自己上调到
0.66；设计稿随后直接换成实色，一步到位到 6.0–7.0:1。透明度做不到冷暖分套——
同一个墨色透下去，底是暖的它就偏暖，永远只有一套。

### 1.4 登录页的三套布局

`LoginMetrics` 一张表，三个预设，对应三份设计稿：

| | iPhone | iPad 竖屏 | iPad 横屏 |
|---|---|---|---|
| 结构 | 头部 → 插画 → 白卡 | 同左，内容收成 700 居中列 | **左右分栏**，房子留在左栏 |
| 主标题 | 27 | 38（限宽 580） | 40 |
| 插画高 | 140 | 230 | 230，只占左栏 |
| 角色卡 | 竖排，圆角 16 | **并排**，圆角 22 | 竖排，圆角 22 |
| 平台缩写 | 无 | 有 | 有 |
| 页脚 | 居中 | 居中 | 左对齐，域名推到右端 |

挑哪一套看**短边**，不看宽度：iPhone 16 Pro 横过来是 874×402，只看宽度会被判成
iPad 横屏，然后把左栏 560 + 插画 230 + 顶部留白 74 塞进 402pt 高里。这个工程的
iPhone 是允许横屏的。判据和用例见 `FlatRadarTests/LoginMetricsTests.swift`。

插画素材只有**一"幅"**（三栋房子），天际线由 `LoginView.Skyline` 横着摆 N 幅、
交替镜像拼出来。三份设计稿要的幅数和每幅尺寸都不同（iPhone 3 幅、iPad 竖屏 4 幅
且房子更大），烤死幅数就得出三份素材。素材那条运河线因此必须跨满整幅**且去掉
圆角**——图标里那条是胶囊形，接缝处两个圆头对在一起会把运河切成一节一节的。

---

⚠️ 这类 `Color(light:dark:)` 便利构造器**必须写 `nonisolated`**：工程开着
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，传给
`UIColor(dynamicProvider:)` / `NSColor(name:dynamicProvider:)` 的闭包会被隐式钉到
主 actor，而系统会在非主线程上调它解析颜色，隔离检查当场 trap。iOS 上实测崩过
（栈贴在 `LoginView.swift`），Mac 的 `Theme.swift` 同一天补上。

---

## 二、字阶

### 2.1 现状：一半固定、一半语义

数出来的调用次数：

| 写法 | 次数 |
|---|---|
| `.font(.system(size: …))` 固定磅值 | **107** |
| `.subheadline` | 50 |
| `.caption` / `.caption2` | 39 / 13 |
| `.headline` | 10 |
| `.footnote` / `.body` / `.callout` | 6 / 3 / 1 |
| `.title` / `.title2` / `.title3` | 1 / 2 / 1 |

固定磅值占 46%，而且分布不是随机的：**信息密度高的地方全是固定磅值**
（ListingRow、Dashboard 的卡、徽章），表单和说明文字才用语义字号。

这是有代价的取舍——固定磅值不跟随 Dynamic Type。代码里对此有过一次明确的撤销记录：
`CalendarView` 曾经按设备把字号加一档（subheadline → title3 那一类），后来撤了，
理由是 iOS 和 iPadOS 共用同一套字阶，按设备加档会和 Dynamic Type 打架——
**想要更大的字是用户在系统设置里表达的**。留白可以按设备放大，字号不行。

### 2.2 实际用到的磅值（按角色）

| 角色 | iOS 取值 | 出处 |
|---|---|---|
| 页面大标题 | 28 heavy，`tracking(-0.8)` | Dashboard / Notifications |
| 登录页主标题 | 27 bold，`tracking(-0.8)` | LoginView |
| 卡片标题 | 13 heavy | Explore mini cards |
| 房源名 | 15.5 semibold | ListingRow.titleLine |
| **价格** | **17 bold monospaced + `monospacedDigit()`** | ListingRow ×3 形态 |
| 一行 meta（城市 · 面积 · 起租） | 12 / 12.5 secondary | ListingRow |
| 二行 sub-meta | 11.5 tertiary | ListingRow.mediumBody |
| 表格列标题 | 10 bold monospaced，**大写**，`tracking(0.5)`，tertiary | ListingRow.detailColumn |
| 状态胶囊文字 | 11 bold | ListingRow.statusBadge |
| NEW 徽章 | 9 heavy monospaced，`tracking(0.5)` | ListingRow |
| 平台徽章 | 9 / 10 / 12 heavy monospaced | PlatformBadge.Size |
| chevron | 11 semibold tertiary | exploreCard |

**等宽只用在数字要对齐的地方**：价格、计数、徽章缩写。正文从不用等宽。

---

## 三、形状、表面、密度

### 3.1 圆角尺度

数出来的分布（次数）：`12`×10、`2`×8、`16`×7、`18`×5、`22`×4、`8`/`3`/`26`/`20`/`14`×2、
`4`/`28`/`11`/`10`×1，外加大量 `Capsule()`。

按角色收敛成四档：

| 档 | 值 | 用在 |
|---|---|---|
| Hero | 22 | Dashboard 顶部大数字卡 |
| 卡片 | 16 | Explore mini card、DetailSection、DetailMetricCard（`.continuous`） |
| 控件 | 12–14 | 内联搜索框、小块底 |
| 微件 | 2–4 | NEW 徽章、堆叠条的分段 |
| 徽章 / chip | `Capsule()` | 状态胶囊、平台徽章、筛选 chip |

### 3.2 表面层次

- 页面底：`Color(.systemGroupedBackground)`
- 卡片底：`Color(.secondarySystemGroupedBackground)`
- 浮层：`.thinMaterial`（DetailMetricCard）／ Liquid Glass（iOS 26）→ `.regularMaterial` 降级
- 卡片描边：`.strokeBorder(.secondary.opacity(0.10–0.12), lineWidth: 1)`
- 卡片阴影：**只有 hero 卡有** —— `black.opacity(0.04), radius: 10, y: 4`

⚠️ **这一层是移植成本最集中的地方**：`FlatRadar/Views` 里有 **28 处** `Color(.systemXxx)`
UIKit 语义色，macOS 上一个都不存在。**包里是 0 处**——唯一一处 grep 命中是注释里的举例，
不是代码，所以这层脏东西全部集中在 iOS app target，Mac 端不会被它拖住。

### 3.3 徽章的着色配方

同一个配方复用了三次，值略有不同：

| | 文字 | 底 | 描边 |
|---|---|---|---|
| 状态胶囊 | 状态色 | 状态色 `.opacity(0.13)` | 无 |
| 状态胶囊（增加对比度开启） | 状态色 | 状态色 `.opacity(0.20)` | 1pt 同色 |
| 平台徽章 | 平台色 | 平台色 `.opacity(0.16)` | 无 |
| NEW | `statusBook` | `statusBook.opacity(0.14)` | 无 |

注释称绿/橙在白底上约 4.5–5.5:1 满足 AA，而 `statusReserved` 那个灰接近 3:1——
所以才有「开了增加对比度就加描边」这条：**让形状轮廓参与传达，不再纯靠颜色差**。
（这些对比度数值是注释里的，我没有复量。）

### 3.4 密度

| | 值 |
|---|---|
| 页面左右边距 | 20 |
| Hero 卡内边距 | 20 |
| mini card 内边距 | 14 |
| DetailSection / MetricCard 内边距 | 12 |
| 房源行竖向内边距 | 4（compact）/ 6（medium）/ 8（regular） |
| 卡片间距 | 12–14 |
| 徽章内边距 | h 5–9 / v 1–5 |

一屏 8+ 行是明确的设计目标（`ListingRow` 顶部注释：「无缩略图，纯文字布局把密度推到一屏 8+ 行」）。
Holland2Stay 不暴露房源照，所以**这个 App 从来没有图片**——这一点对 Mac 极其重要，见第四节。

---

## 四、响应式：按实测宽度分档，不看 size class

这是全 App 最一致、也最值得带到 Mac 的一条结构规则。**没有一处按 `horizontalSizeClass` 决定布局**
（size class 只用来决定单个控件的形态，比如 `DetailRow` 横排还是竖排）。

| 门槛 | 决定什么 | 为什么是这个数 |
|---|---|---|
| 920 | tab bar 收成 Browse / 摊成六个 | iPad Stage Manager、Split View 会在窗口已经窄到放不下六个 tab 时仍然报 regular |
| ~854 / ~460 | ListingRow 走 regular / medium / compact | `ViewThatFits` 由内容自己算，不是硬编码 |
| 700 | 大数字卡排成一行 | 一行版排得下的最小宽 |
| ~1167 | Dashboard 左右分栏 | 由左栏倒推：700 ÷ (1 − 2/5) |
| 620 / 1200 | DetailSection 排 2 / 3 列 | iPad 竖屏 ~790 和横屏 ~1465 都是 regular，只看 size class 会一边太空一边太挤 |
| ~773 | 日历左右分栏 | 月网格固定宽 + 右栏至少 350pt 放得下一行房源 |

**Mac 上这条规则直接生效**，而且比 iOS 更需要：窗口宽度是连续可变的，没有「设备」这个概念可依赖。

---

## 五、无障碍与动效（已成型的约定）

- **密集行合并成一个 a11y 元素。** `accessibilityElement(children: .ignore)` + 自己拼一句完整朗读
  （`"New listing, 38m, Holland2Stay, Apartment 305, €1,067, Available to Book, Eindhoven, 28 m², from 5 Jan"`）。
  默认逐个念会把节奏念碎、上下文丢掉。
- **`colorSchemeContrast == .increased` 时**：tertiary 抬到 secondary，徽章加 1pt 同色描边、底色 0.13→0.20。
- **`reduceMotion` 时停掉循环动画**（Live 心跳点的呼吸光晕）。同时 Offline 时也停——
  **动 = 数据新鲜，静 = 数据过期**，动效在这里承载语义，不只是装饰。
- **视觉 22pt 的 chip 用 `minHeight: 44` + `contentShape` 把命中区补到 44pt**，不让 chip 变高。
- **装饰性 glyph 用 `accessibilityHidden(true)` 摘掉**（chip 上的 ✕ 否则会念成 "Eindhoven xmark"）。
- **占位一律 `—`，不留空。** 留空看不出是「没有」还是「没加载」。

---

## 六、哪些能带到 Mac，哪些带过去就是错的

| iOS 的做法 | Mac | 理由 |
|---|---|---|
| 8 个语义色 token | ✅ **原样** | 已在包里，已验证进了 Mac app，两端一份 |
| 7 个平台色 + 徽章缩写 | ✅ **原样** | 同上；颜色一致性本身就是它存在的理由 |
| 状态胶囊的解剖（圆点 + 文字 + 13% 同色底 + Capsule） | ✅ **形状照抄，尺寸缩** | 在 Mac 的小字号下依然读得出 |
| 价格等宽 + `monospacedDigit()` | ✅ **更重要** | Mac 是真表格，整列对齐 |
| 「未知状态单独一档」「占位用 —」「失败必须有重试入口」 | ✅ **语义规则，与平台无关** | 已经在 `BrowseWindow` / `DetailPane` 里落实了 |
| 按实测宽度分档 | ✅ **更重要** | 窗口宽度连续可变 |
| 无缩略图的纯文字密度 | ✅ **天然适配** | Mac 表格本来就要密；这个 App 恰好没有图片要排 |
| 44pt 命中区 | ❌ **必须改** | AppKit 控件 20–28pt；44pt 的 chip 在 Mac 上像放大镜下的玩具 |
| 17pt 基准字号 | ❌ **必须换算** | macOS `.body` = **13pt**（实测），比值 0.765 |
| `Color(.systemGroupedBackground)` 那 28 处 | ❌ **不存在** | 换 `.windowBackgroundColor` / `.controlBackgroundColor` / `.textBackgroundColor` |
| 分组底 + 卡片浮起的层次 | ⚠️ **是 iOS 的成语** | Mac 的成语是窗口底 + `Form`/`GroupBox`/`List` 内嵌；整套卡片搬过去 = 「装在窗口里的 iPad app」 |
| Liquid Glass 浮在内容上的胶囊 | ⚠️ **位置不同** | macOS 26 有 `glassEffect`，但 Mac 上它属于侧栏和工具栏，不是飘在列表上的药丸 |
| Hero 大数字卡 + 横滑 chip 排 | ❌ **手机成语** | Mac 上横向滚动条是失败信号；大数字卡在 1400pt 宽里是浪费 |
| 底部 tab bar | ❌ | 换侧栏 + 菜单 + 窗口 |
| 下拉刷新 | ❌ | 换 ⌘R + 工具栏按钮（已做） |

### 字阶换算表

macOS 一列是**实测值**（`NSFont.preferredFont(forTextStyle:)`，macOS 27.0）：

| 语义 | iOS | macOS 实测 |
|---|---|---|
| largeTitle | 34 | **26** |
| title | 28 | **22** |
| title2 | 22 | **17** |
| title3 | 20 | **15** |
| headline | 17 semibold | **13 bold** |
| body | 17 | **13** |
| callout | 16 | **12** |
| subheadline | 15 | **11** |
| footnote | 13 | **10** |
| caption / caption2 | 12 / 11 | **10 / 10 medium** |

**HIG 另外钉死两个数**（2026-09-10 从 developer.apple.com 的 HIG 拉的原文）：
macOS **默认 13pt、最小 10pt**。控件字号 regular 13 / small 11 / mini 9。
行高依次是 32 / 26 / 22 / 20 / 16 / 16 / 15 / 14 / 13 / 13。

⚠️ **别照着设计稿的 px 值往 pt 上抄。** 设计稿是 HTML，里面的 13 / 11.5 / 10.5 / 9
是浏览器里的相对层级，不是 macOS 的字阶。第一版就是这么抄的，结果一半数值落在
**阶与阶之间**（10.5、11.5），另一半把本该是正文的数据压到了 subheadline，
整体小一号；9pt 的平台徽章直接掉到 HIG 最小值以下。设计稿定的是**层级**，
磅值要回到下面这张表上取。

据此换算 §2.2 那些固定磅值：

落到 SwiftUI 上就是**一律写语义字号**（`.body` / `.callout` / `.subheadline` /
`.caption`），不写 `.system(size:)`——写死磅值就是上面那次跑偏的起点。
剩下允许写死的只有：44pt 的展示数字、胶囊里的短标签（10–11pt），
以及 SF Symbol 的装饰字形（箭头、✕，7–11pt）。

| 角色 | iOS | → Mac | 备注 |
|---|---|---|---|
| 页面大标题 | 28 heavy | **22 bold**（`.title`） | Mac 上标题多半在标题栏里，页内大标题要少用 |
| 卡片标题 | 13 heavy | **11 semibold**（`.subheadline`） | |
| 房源名 / 表格主文本 | 15.5 semibold | **13**（`.body`） | Table 行文本别加粗，加粗留给选中态 |
| 价格 | 17 bold mono | **13 `.body.monospacedDigit()`** | |
| **次级数据**（城市 / 面积 / 房型 / 可入住） | — | **12**（`.callout`） | 表格里和主文本同行、但不是你扫的那一列 |
| **控件文字**（按钮 / 勾选框 / Toggle / 搜索框 / 分段选择 / token） | 17 | **13**（`.body`） | HIG 钉死的控件 regular 号；**不跟数据密度那几档走** |
| meta | 12 / 12.5 | **11**（`.subheadline`） | |
| sub-meta | 11.5 | **10**（`.caption`） | |
| 状态胶囊文字 | 11 bold | **10 bold**（`.caption`） | |
| 表格列标题 | 10 mono caps 自绘 | **交给 `Table` 的列头** | 别自绘，系统列头自带排序箭头和拖拽 |
| NEW / 平台徽章 | 9 heavy mono | **9 heavy mono，不再缩** | 9pt 已经是可读下限 |

**换算不是等比缩放，是重新分配。** 比如列标题那一档在 Mac 上直接消失了——因为 `Table` 自带列头，
自绘只会和系统的排序箭头打架。

⚠️ 「次级数据」和「控件文字」这两行是 2026-09-16 补的。原先表里没有它们，
而上面那句 prose 又把 `.callout` 列进了白名单——**列进白名单却不给角色**，
结果就是 `.callout` 成了事实上的默认字号（61 处，`.body` 只有 7 处），
把本该 13pt 的控件和主数据一起拖到了 12pt。
角色的权威定义在 ``Theme`` 顶部的注释里，这张表跟着它走，别让两边再分叉。

---

## 七、Mac 需要哪些页面

先说结论的形状：**不是把 iOS 的九个页面各做一个 Mac 版**，而是
**一个主窗口 + 一个共享 inspector + 一个设置场景 + 若干次级窗口**。

iOS 端的九处界面里，有三处在 Mac 上不该以「页面」的形式存在。

### 7.1 主窗口：侧栏 + 内容 + inspector

```
┌──────────┬───────────────────────────────┬─────────────┐
│ Listings │                               │  比较（钉住）│
│ Map      │        当前模式的内容          │  ───────────│
│ Calendar │   （表格 / 地图 / 日历）        │  焦点详情    │
│ Alerts ⑦ │                               │             │
│ ──────── │                               │             │
│ 钉住的房源│                               │             │
│ ⚙ Settings│                              │             │
└──────────┴───────────────────────────────┴─────────────┘
```

**关键决定：右侧 inspector 三种模式共享。** 这是 Mac 版最大的一次结构性收益——
在地图上点一个 pin、在日历上点一天里的一条，右边出来的是同一个详情面板，
不像 iOS 那样每个模式各自 push 一个详情页。iOS 做不到是因为手机屏放不下第三栏，
不是因为它不好。

侧栏取代 tab bar。`MainTabView` 那套「920pt 门槛 + `visibleTab` 归一化」的复杂度在 Mac 上
**整个消失**——侧栏可以折叠，但条目不会因为窗口变窄而消失。

### 7.2 页面清单

| # | 页面 | 形态 | 状态 | 复用什么 | 新写什么 |
|---|---|---|---|---|---|
| 1 | **Listings** | `Table` + 服务端排序 | ✅ 已做（Phase 2） | `ListingsStore`、`ListingSort` | 游客入口、服务端筛选 |
| 2 | **Inspector（详情）** | 右栏常驻，不是页面 | ✅ 已做 | `Listing` 全部字段 | 八行事实 + 同类比价 + 小地图 + 动作行。**价格历史没做**：后端没这个接口，iOS 也没有 |
| 3 | **比较** | **多窗口并排**（不再是 Inspector 里的卡） | ✅ 已做（Phase 4） | — | 双击 / 拖出去 / ⌘⇧O 开独立窗口；钉住仍在侧栏 |
| 4 | **Alerts（通知）** | 列表 + SSE | ✅ 已做 | `NotificationsStore`、`SSEClient` | 系统通知中心**已接**（`MacPushDelegate`）；SSE 在应用级，一会话一条 |
| 5 | **Map** | 内容区，共享 inspector | ✅ 已做 | `MapStore`、`MapPOI`、`Reachability` | 悬停卡、右键菜单、选中自动画可达圈。**不要定位权限**——这一屏答的是「房源分布在哪儿」，不是「我附近有什么」 |
| 6 | **Calendar** | 内容区，共享 inspector | ✅ 已做 | `CalendarStore` | 全部自绘（`CalendarMonth`），`UICalendarView` 在 macOS 不存在 |
| 7 | **设置** | `Settings {}` 独立场景，两个入口：⌘, 和侧栏底部 | ✅ 已做 | `MeFilterStore`、`AuthStore`、`PushStore` | 分 tab：General / Account / Notifications / Filters |
| 8 | **登录** | 独立窗口 | ✅ 已做 | `AuthStore` | 登录 / 注册 / 游客三个入口。**Touch ID 没接**——Mac 有硬件，`BiometricAuthService` 也在包里 |
| 9 | **菜单栏常驻** | `MenuBarExtra` | ✅ 已做（Phase 4） | `AppFeed`（统计 + 匹配数） | 匹配数 + 上次扫描 + 未读数；**默认关**，开关在设置页 |
| 10 | **Stats** | 内容区，共享 inspector | ✅ 已做 | `/stats/public/charts`、`ChartPresentation` | 十二张图一屏铺开、不做钻取；选中一张右栏出明细。语义是「过去 N 天**新上架**的那批」，不是库存 |

**状态列 2026-09-16 对过一遍。** 之前 4/5/6 标的是 ⬜ Phase 3、9 标的是 ⬜ Phase 4，
但那四屏在 Phase 4 之前就做完了——表格没跟上代码，读的人会以为还有一大摊活。
这次只改状态和「新写什么」那一列，**没有改任何设计决定**。

### 7.3 三处不做 Mac 版，以及为什么

- **Dashboard** —— iOS 上它是「一屏看完」的入口，因为手机上没有别的地方放总览。
  Mac 上总览的位置是**状态栏 + 菜单栏常驻**，不是一整页大数字卡。
  如果后面真想要图表，做成侧栏里的一个 "Insights" 条目、内容区放 Swift Charts 网格，
  而不是把 1747 行的 `DashboardView` 翻译一遍。**优先级最低。**
- **Onboarding** —— Mac 上没有首次启动引导页的传统。
- **Admin（Monitor / Users）** —— 后端网页端已经有全套，不重复。

### 7.4 日历：形态已定 —— 仍然是月网格（2026-09-10 结论）

原先这里写着「月网格在 1400pt 里只占中间一条，更贴 Mac 的形态可能是按周分列的时间轴」。
**这个顾虑不成立，最后仍然做的月网格**，理由记在这里以免又被翻出来重想：

- 决定性的差别是**格子里装什么**。iOS 的格子只装一个计数数字，所以宽屏下浪费；
  Mac 的格子装的是条目卡片（状态圆点 + 价格 + 楼盘名，最多 3 条 + 「+N more」）。
  装得下内容，宽度就不浪费。
- 一次只看一个月，所以「数据稀疏」不是问题。我一度用「135/3714 天有货 = 96% 的格子是空的」
  反对网格，**那个算法是错的**：96% 是拿整个 10 年跨度算的，网格一次只画一个月。
  实测 2026-09 有 237 条（未登录全量），格子是满的。

实现见 `FlatRadarMac/CalendarPane.swift` 和 `CalendarMonth.swift`。

**设计稿里有三样东西没做，都是后端没有数据**（不是漏了，见 `CalendarPane` 的类型注释）：
`Lottery deadlines`（openapi 里 `deadline`/`closes`/`draw_at` 各 0 次，且日期**只到日不到时刻**）、
`Viewings`（属于用户数据，后端没有这个概念）、`Subscribe (.ics) / Add to Calendar.app`
（要 EventKit + 权限 + entitlement，是单独一件事）。顶部那张琥珀色 "Next deadline" 英雄卡、
侧栏的 "Next up" 区都建立在前两者上，一并没做。

设计稿右栏那张 **"Why the 1st is crowded"** 解释卡也没做，理由不同：**它说的话在这份数据里是错的**。
实测 691 条里 7 号 130 条（18.8%）、1 号 90 条（13.0%），最扎堆的是 7 号不是 1 号。
要做的话得改成**算出来**的版本，不能照抄那句断言。

### 7.5 建议的顺序

Phase 2 的两个尾巴 → 侧栏骨架 → Alerts → Settings → Map → Calendar → 菜单栏。

先做侧栏骨架的理由：**它决定 inspector 是不是共享的**，而那是后面每个页面的前置条件。
现在 `BrowseWindow` 自己持有 `NavigationSplitView` 和 `BrowseModel`，
加第二个模式之前得先把这层拆出来，否则 Map 会长出自己的第二个详情面板。

---

## 八、动手前要定的三件事

1. **Mac 走密集原生，还是搬 iOS 的卡片语言？**
   建议：**密集原生**。表格、列表、`GroupBox`、分隔线；卡片只留给**真正是比较单元**的那种
   （已有的钉住比较卡就是），不给每一块内容都套一个圆角 16 的盒子。
   理由是任务书自己写的：做原生 Mac 版的全部动机就是视图层要重写，
   把 iOS 的视觉成语整套搬过来，等于花了重写的成本、拿到了 Catalyst 的结果。

2. **要不要一个品牌强调色？**
   iOS 的 `AccentColor` 是空的（系统蓝）。Mac 上系统蓝会和 `Platform.color` 里
   Holland2Stay 的 `.blue`、以及 `statusReserved` 的蓝撞在一起——iOS 上撞得不明显是因为
   它们很少同框，Mac 的表格里**一定同框**——现在 `BrowseWindow` 的 Platform 列是纯文字
   （不是设计决定，是我还没画徽章），一旦按 iOS 的一致性补上彩色徽章，
   一行里就同时有强调蓝、H2S 蓝和 Reserved 蓝。三个蓝挨在一起是真问题。
   要么给强调色换个色相，要么把 H2S 的平台色换掉（但注释明确说过平台色是用户认熟的东西，
   不该为配色换）。**这个要先定。**

3. **Inspector 是不是所有模式共享？**（见 7.5）建议是。

---

## 附：这份文档没覆盖什么

- **图标**。`BrandLogo` 和 App 图标同源（Icon Composer 文档），Mac 变体已经在用。
- **本地化**。五种语言，Core 35 个 key / app 430 个 key，Mac 端的新文案要进哪个 catalog
  按归属决定（视图文案进 app，模型/状态文案进包）。
- **对比度实测**。§3.3 引的是代码注释里的数值，我没有复量。真要发布 Mac 版，
  这套色在 Mac 的浅色窗口底（`#ECECEC` 一档，比 iOS 的分组灰亮）上要重新量一遍。
