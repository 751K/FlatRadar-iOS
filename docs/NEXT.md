# 下一版预期（2.1.0）

写于 2026-09-05。已上架的是 **2.0.0**；工程里的 `MARKETING_VERSION` 已经是 **2.1.0**（build 199），还没发出去——这份文档说的就是它。

同日已定并落地：**最低支持版本升到 iOS 18.0**。依据是 App Store Connect 的
Analytics——现有用户已经全部在 iOS 18 及以上。工程里六处 `IPHONEOS_DEPLOYMENT_TARGET`
统一成 18.0（app target 继续继承 project 级，不写自己的值），`tests/test_deployment_target.py`
把它和 README 的声明钉在一起。

这三条都属于**新功能**，与 [iOS_README.md](iOS_README.md) 和根 README 里写的「维护模式、不做大功能扩展」是冲突的。要么这份文档是那条方针的显式例外，要么方针该改——先想清楚是哪种，别让两份文档各说各话。

顺序不是随便排的：**第 1 条是第 2 条的前提**，第 3 条独立，随时可做。

---

## 事后追记：2.1.0 实际变成了什么

上面那三条是这份文档最初的全部内容。真正发生的事和它出入很大——2.1.0 已经是一个
**「iPad 适配 + Xcode 27 迁移」**的版本，而这两件事一条都不在原计划里。

已落地（按提交顺序）：

- **Xcode 27 迁移**。两轮：`Shape` 的 conformance 隔离从警告升成错误；`Encodable`
  DTO / 隐式合成的嵌套类型 / extension 成员共 50 处补 `nonisolated`——`833fb52`
  那轮只做了 `Decodable` 那一半。测试 target 此前在 Xcode 27 下根本编不过。
- **iOS 18 的 `Tab {}` builder**，iPad 换成 `sidebarAdaptable`。连带修了一个转屏
  必崩的 bug（selection 指向隐藏 tab），修法是把 selection 改成派生值，配了
  `FlatRadarTests/TabSelectionTests.swift` 守那条不变式。
- **iPad 布局**：Dashboard 大数字卡排成一行 + Explore 三列、详情页标签在上值在下 +
  三列、BrowseView 两套合一、地图控件按 HIG 档位分档、日历行留白。
- **地图**：默认视野改 Amsterdam，弹卡档位改成按实测高度算。
- **登录**：后端给的具体原因不再被通用标题吞掉（注册撞名只显示 "Conflict"）。

这轮学到最贵的一课，写在 `MapLayout.ControlMetrics` 的注释里：**大屏多出来的空间，
规范给的用法是放更多内容 / 分栏，不是把同样的东西印大。** 中途按设备把字号各放大
一档，查 HIG 之后全撤了——iOS 和 iPadOS 共用同一套字阶，而"想要更大的字"是用户在
系统设置里通过 Dynamic Type 表达的，按设备再加一档等于放大两次。分档只留给**尺寸
和留白**：按钮直径走 Apple 的标准档位（Regular 44 / Large 52），留白可以自由加。

---

## 1. 收集用户系统版本

**状态：客户端已实现（2026-09-05），等后端落库。**

### 现状：已经在收，但收的是错的那批人

`ios_version` 和 `device_model` 早就在上报了——只在崩溃诊断这一条路径里：

```swift
// FlatRadar/Networking/APIClient.swift:258
let device = UIDevice.current.model
let iosVersion = UIDevice.current.systemVersion
```

问题是这条路径的触发条件是「**崩过或卡过** + 用户**同意**上传诊断包」。用它去推任何一种「装机分布」，样本都偏到没法用：崩溃率本身就和系统版本相关，老系统更容易崩，于是老版本在这个样本里被系统性高估。

字段是现成的，缺的是一条**无偏采样**的上报路径。

### 为什么还要收：ASC 给的是两张分布，不是交叉表

**系统版本分布这件事，App Store Connect 的 Analytics 已经给了**——升 iOS 18.0 就是照着它做的决定，没用上 app 里的任何埋点。所以「用户在哪个系统上」不构成理由，那个问题已经有免费答案。

剩下的价值只有 **ASC 报不了的东西**：

| 想知道的 | ASC 能不能告诉你 |
|---|---|
| 用户在 iOS 几 | 能（聚合分布） |
| 用户的机型 | 能（聚合分布） |
| 「机型够格 **且** 系统够新」的那批人占多少 | **不能**——两张独立的分布拼不出交叉表 |
| `SystemLanguageModel` 到底可不可用 | **不能** |

后两行是关键，而它们正是第 2 条那三道门。逐设备上报能拿到交叉表，这是聚合报表做不到的。

第三道门「用户有没有开 Apple Intelligence」现在还报不了——那要读 `SystemLanguageModel.default.availability`，需要 iOS 26 SDK。报的时候要连 `.unavailable` 的**原因**一起报：机型不够格会随换机自然改善，用户主动关掉不会，两者对「第 2 条值不值得做」的含义完全相反。

### 落点：`/devices/register`

已实现的是这个：

- `DeviceRegisterRequest` 加 `os_version`（[APIResponse.swift](../FlatRadar/Models/APIResponse.swift)）
- `PushStore.currentOSVersion` 读 `UIDevice.current.systemVersion`（[PushStore.swift](../FlatRadar/Stores/PushStore.swift)）
- 随 `/devices/register` 一起发，只有那一个调用点

查后端 spec（`docs/openapi.json` 的 `DeviceRegisterRequest`）确认了两件事：

- **`additionalProperties: true`** —— 多发一个 `os_version` **不会** 400，客户端可以安全地先于后端上线。这点是查过的不是赌的：如果它是 `false`，一个未知字段会让设备注册整个失败，等于推送报废。
- **`model` 已经是硬件标识符**——`PushStore.currentModel` 读的是 `utsname.machine`（`iPhone16,2` 这种），不是 `UIDevice.current.model` 的 `"iPhone"`。所以「机型够不够格」这道门后端**用现有数据就能算**，本来以为要新加，其实不用。

选它而不是别的落点，是因为它已经在传设备信息，加一个字段边际成本接近零。代价是**样本不全**：触发条件是「已登录 + 非 guest + 授予推送权限」，guest 和拒绝推送的用户永远不出现在这份数据里，而这两类人可能恰好与「设备旧」相关。

接受这个偏差，理由是精度要求本来就不高——要回答的是「能用上端上模型的人占几成」，差几个百分点不影响做不做的决定。真要全量得挂到人人都打的端点上（`/listings` 之类），那等于给每个请求加字段，隐私口径也要重想，不值得。

### 还卡着的地方

- **后端得真的存下来。** `additionalProperties: true` 只保证不报错，不保证入库。字段现在发出去了，但在后端加处理之前它是掉在地上的。
- **spec 已经落后于客户端。** iOS 一直在发的 `language` 字段，spec 里**根本没有**。它多半是后端真在用的（`PushStore` 的注释说是给 APNs 双语推送用的），只是没写进去。根 README 说后端会把路由集和 spec 双向 diff——那挡的是**路由**，字段级漂移没人查，这是个活例子。后端加 `os_version` 时把 `language` 一并补上。
- **隐私文件要跟。** 加采集字段意味着 `PrivacyInfo.xcprivacy` 和 App Store 隐私问卷都要重新对一遍。系统版本通常归到「诊断」而非「标识符」，但要确认它不会和别的字段拼成设备指纹。
- **数据要等。** 发出去还得等用户升级 app，至少一个版本周期。所以第 2 条的判断依据不会在 2.1.0 之内到手；读 `SystemLanguageModel` 那部分本身也要先发一版，第 2 条最快是 2.2.0。

---

## 2. 筛选条件引入 AI（Apple 端上模型）

### 想做的形状

自然语言 → `ListingFilter`。用户敲「埃因霍温 1200 以内、能带家具、别是抽签的」，直接落成筛选条件，而不是手点 13 个维度。

### 为什么这个 fit 其实很好

`ListingFilter`（[Models/ListingFilter.swift](../FlatRadar/Models/ListingFilter.swift)）已经是一个定义清楚的结构体，13 个维度里绝大多数是**枚举型**：

```
maxRent / minArea / minFloor          数值
allowedOccupancy / Types / Cities /   枚举集合
  Neighborhoods / Sources / Contract /
  Tenant / Offer / Finishing
allowedEnergy                         单选
```

Foundation Models 的 guided generation（`@Generable` / `@Guide`）要的正是这种「字段固定、取值可枚举」的目标结构。不需要自由文本解析，模型只需在给定的取值里做选择，输出可以被类型系统直接接住。这比大多数「给 App 加 AI」的场景干净得多。

### 三道门，缺一不可

Apple 的端上模型不是「iOS 26 就有」：

1. **系统版本** ≥ iOS 26 —— 要 `if #available(iOS 26, *)`
2. **硬件够格** —— 需要支持 Apple Intelligence 的机型，不是所有能升 iOS 26 的设备都行
3. **用户开了 Apple Intelligence** —— 用户可以关掉

所以必须查 `SystemLanguageModel.default.availability`，拿到的是 `.available` 或带原因的 `.unavailable`。**这三道门都过不了的用户是多数还是少数，现在没人知道，而且 ASC 也不会告诉你**——机型和系统版本它有，「用户有没有开 Apple Intelligence」它没有。这就是第 1 条排在前面的唯一理由。如果数据回来说能用的人只有个位数百分比，这条的性价比就得重算。

> API 名称按 WWDC25 的 Foundation Models framework 记，动手前对一遍当前文档，可能有出入。

### 真正的坑：可选值是后端给的，不是写死的

`allowedCities` / `allowedNeighborhoods` / `allowedSources` 的合法取值**来自后端**，不在 app 里硬编码。如果 schema 里把取值写死或者干脆放开让模型自由生成，它会造出后端根本不认的城市名和小区名，落成一个**筛出零结果但看起来完全正常**的筛选器——用户只会觉得「没房了」，不会觉得「AI 错了」。

所以 `@Generable` 的取值约束必须在运行时用后端当前返回的可选值构造，不能是编译期常量。这一条比接模型本身更容易写错。

### 还要想的

- **降级路径。** 三道门任何一道没过，UI 该是什么样。倾向于整个入口不出现（而不是出现然后报错），但那意味着两类用户看到的筛选页不一样。
- **纯本地。** 用端上模型的最大好处就是用户输入不出设备。别为了效果好就悄悄加个云端兜底，那等于把这个好处扔了，隐私问卷也要重填。
- **五种语言。** 现在支持 en / zh-Hans / zh-Hant / nl / es。用户会用哪种语言敲筛选条件？荷兰语的房源描述词汇（`gestoffeerd` / `gemeubileerd` 之类）能不能被正确映射到 `allowedFinishing` 的取值上，要实测。
- **入口放哪。** `FilterEditView` 是现在的编辑页；是在它顶上加一个输入框，还是在列表页加一个独立入口，影响不小。

---

## 3. 地图上显示超市 / 学校等地点

### 现状：现在是主动全关的

```swift
// FlatRadar/Views/Map/MapView.swift:155
.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
```

`.excludingAll` 是显式写上去的，不是默认值。所以这条不是「加一个功能」，是**把一个刻意做过的决定改成有选择的**——动之前先搞清楚当初为什么关。

大概率是为了视觉：这张图上已经有按状态染色的房源 pin、有同址房源摊开成一圈的散布逻辑、还有 [MapClustering](../FlatRadar/Views/Map/MapClustering.swift) 的聚合气泡。底图再叠一层 POI 图标，低缩放级别下会糊成一片，而房源 pin 是这张图存在的理由。

### 要做什么

把 `.excludingAll` 换成 `.including([...])`，挑几类：

```swift
MKPointOfInterestCategory: .foodMarket, .school, .university,
                           .publicTransport, .pharmacy, .park …
```

真正要定的不是 API 怎么写（很简单），是**选哪几类、什么时候显示**。

### 建议先定这几件事

- **哪几类。** 租房场景下真正影响决策的是超市、公共交通、学校。餐厅酒吧加进去只会变噪音。宁可少。
- **要不要跟缩放级别联动。** 只在放大到街区级别之后才显示 POI，远景保持干净。这样房源 pin 在概览视角下不被抢。实现上要读当前 camera 的 span——`MapClustering.quantizeSpan` 已经在算这个量了，可以复用。
- **要不要给用户开关。** [MapFilterBar](../FlatRadar/Views/Map/MapFilterBar.swift) 是现成的位置。但多一个开关就多一个状态要持久化、要在五种语言里有文案。
- **别碰导航。** [AppleMaps.swift](../FlatRadar/Views/AppleMaps.swift) 里那段注释说得很清楚：导航必须用真实坐标而不是散开后的显示坐标。POI 是底图的事，跟这个逻辑不相干，但改 MapView 的时候别顺手动到它。

### 好消息

`pointsOfInterest` 的过滤在 iOS 17 就有，**不依赖任何版本决定**。三条里只有这条现在就能做，不用等第 1 条的数据，也不受最低版本怎么定的影响。

---

## 小结

| | 状态 | 还差什么 |
|---|---|---|
| 1a. 系统版本上报 | **客户端已实现并提交** | 全是后端的活：落库 + spec 补 `os_version` 和 `language` |
| 1b. 端上模型可用性上报 | 未做 | 已不缺工具（Xcode 27 / iOS 27 SDK 在手），缺的是决定做不做 |
| 2. AI 筛选 | 未做 | 等 1b 的数据——不知道多少人能用就没法判断值不值 |
| 3. 地图 POI | **未做** | 无依赖，随时可做。**这是原计划里 iOS 这边唯一还欠的一条** |
| — iPad 适配 | **大量已落地**（见上面追记） | 结构性的那半还没动，见下 |
| — Xcode 27 迁移 | **已落地** | 无 |
| — App 图标 | **诊断完成，未修** | 见下 |

按原计划，2.1.0 在 iOS 这边只剩**第 3 条（地图 POI）**。1a 已经交出去等后端，
第 2 条留给 2.2.0。但实际范围早就超出原计划了。

## 两件悬着的事

**一、App 图标：浅色和 tinted 烤了白圆角**

三张变体里只有 `AppIcon-Dark.png` 是对的（满幅铺到边，四角 (17,28,46)→(28,78,126)
跟渐变一致）。另外两张四角是**纯白 (255,255,255)**——圆角被烤进了 PNG，角外留白。
系统本来会自己切圆角，等于切了两次，不做遮罩的场合（StoreKit 弹窗、App Store 页）
直接看到白方角。

浅色图标**不能带透明通道**（Apple 硬性要求），所以修法不是抠成透明，而是把背景
渐变铺满整个 1024×1024、别烤圆角——`AppIcon-Dark.png` 现在就是这么做的。tinted
那张还多一层问题：它该是**灰度**图（系统按用户选的颜色上色），现在是淡紫色且几乎
没有对比度。

为什么没被挡住：`tests/test_ios_dark_icon.py` 的 docstring 把这个失败模式写得很
清楚（「四角会不会在系统切圆角后露出亮边」），但它**只测深色那一张**。同一个概念、
同一份 PNG 解码器，浅色和 tinted 从来没进过测试范围。要么把测试扩到三张（写完会是
红的，因为图确实坏了），要么先从设计源重新导出。

**二、iPad 的结构性问题还没动**

全 app **零个 `NavigationSplitView`**（29 处全是 `NavigationStack`）。横屏点一条
房源，整块屏幕被详情页顶掉，左边的列表连同滚动位置一起消失；日历页月历占上面
40%、下面空着大半屏。这一轮做的都是**同一列之内**的排版改进，没有动导航结构。

真要做，代价是 `NavigationCoordinator` 的 `listingsPath: [ListingRoute]` 要从
**路径模型**改成**选中模型**，而 deep link（`h2smonitor://listing/<id>`、推送点开）
走的正是它——那是有真实用户在走的路径。这一步比这一轮做的任何一件都大。

## 在这台机器上构建

`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`，`/Applications` 下也
没有 Xcode.app，所以 `xcodebuild` 直接跑会报 "requires Xcode"。**别据此断定这台
机器编不了**——Xcode 装在外置盘的一个 UUID 目录里：

```bash
export DEVELOPER_DIR=/Volumes/MacoutDsik/Applications/FE00CCDA-B55C-49E0-A6A9-D7E8A2E0A829/Xcode-beta.app/Contents/Developer
xcodebuild build -project FlatRadar.xcodeproj -scheme FlatRadar \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

`DEVELOPER_DIR` 是单条命令的临时覆盖，不用 sudo、不改系统设置。找它用
`mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"`。

两条约束：

- **别传 `-derivedDataPath`。** 内置盘只剩约 5.6Gi，而工程已经把
  `IDECustomDerivedDataLocation` 和 `SYMROOT` 都配在外置盘
  （`/Volumes/MacoutDsik/Xcode/`）。指到别处会在内置盘上堆几百 MB。
- **没装任何模拟器 runtime**，所以能编译（编译只要 SDK）但跑不了模拟器测试。
  ⌘U 要跑的话，目标选 **My Mac (Designed for iPad)** 或真机——选模拟器一定失败。

这个 Xcode 是 **beta（27.0）**。根 README 那条仍然成立：Apple 拒收 beta Xcode 打的
包，出包走 Xcode Cloud 自己的工具链。beta 只用于本地验证和真机调试。

`tests/` 下的 pytest 挡的是编译器看不见的那一类——字段被 Encodable 安静丢掉、
tab identifier 两边写岔、README 和工程的最低版本漂移。它们和编译器互补，不互相
替代。
