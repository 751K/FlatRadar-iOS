# App Store 截图海报

把模拟器素屏排成六张海报，前两张组成连续跨页封面。保留真实 UI、设备遮罩和输出尺寸；使用大标题与统一边距。封面用暖白底与钴蓝强调色，左侧为品牌、两行主标题和一个平台数字，右侧为跨过接缝的仪表盘设备，低对比雷达圆环连接两页；后四张保留单页版式。

## 运行

需要 Python 3.10+、Pillow，以及 macOS 的 SFNS / Hiragino Sans GB 字体。

```bash
python3 tools/screenshots/poster/poster.py \
  --src /path/to/raw/zh-Hans \
  --lang zh-Hans \
  --device iphone67 \
  --out screenshots/poster/zh-Hans/iphone67 \
  --preview screenshots/poster/preview-zh-Hans.png
```

`--preview` 可选，生成六张联系表，以及同目录的 `*-spread.png` 前两张跨页预览，必须放在上传目录外。预览的深色间距不会写进正式截图。缺素材或缺文案会在出图前报错；输出目录不能与素屏目录相同。

| device | 输出像素 |
| --- | --- |
| iphone67 | 1320 × 2868 |
| iphone61 | 1206 × 2622 |
| ipad13 | 2064 × 2752 |
| ipad13l | 2752 × 2064 |

素屏应与选择的设备及横竖方向一致。程序不会翻译 UI，也不会修改截图中的时间、数据和状态栏。

## 内容与调整

输出顺序：跨页封面左页、跨页封面右页、地图、仪表盘、四视图、日历。前两张从同一张双宽画布按精确像素切开，上传时保持文件名顺序。需要 `01-Dashboard.png`、`02-Listings.png`、`03-Map.png`、`04-Calendar.png`、`05-Notifications.png`。

- `copy.json`：五种语言的两行标题；`_hero` 定义跨页标题、简介、数字说明和页脚；`_badges` 第一条提供平台数量。`01-Inbox` 文案保留用于单页构图，跨页右页不叠加标题。
- `poster.py` 的 `THEMES`：底色、正文色、强调色、设备衬底色。
- `build_hero_pair`：跨页设备、文字安全区域及切图。
- `_headline` / `build`：标题比例、边距、设备及四视图排版。
- `masks/`：现有设备屏幕遮罩；`appicon.png`：品牌图标。

截图成品保存在仓库根目录的 `screenshots/`，已被 Git 忽略。工具源码不应被忽略。

## 设计参考

2026-09-06 查看了实际 App Store 页面：

- [Structured](https://apps.apple.com/us/app/structured-daily-planner-todo/id1499198946)：统一底色、设备穿过接缝、清晰的两层标题。
- [Flighty](https://apps.apple.com/us/app/flighty-live-flight-tracker/id1358823008)：减少同级信息，建立主视觉与辅助信息的层级。

本项目采用暖白与钴蓝、大字左对齐、单一平台数字和低对比雷达圆环。手机按旋转后的边界留右侧间距，文字宽度按设备的实际轮廓计算。素材保持真实，不使用参考应用的奖项或评价。
