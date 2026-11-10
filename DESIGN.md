---
name: 清阅
description: 米白纸面与墨绿操作色，让长篇中文段落成为主角。
colors:
  forest: "#254F43"
  paper: "#F7F5EF"
  primary-container: "#E5EAE0"
  secondary-container: "#DCE5D9"
  dark-surface: "#191D19"
  dark-primary: "#A7CDB5"
  dark-container: "#354B3E"
  dark-on-container: "#CDE0CA"
  reading-0: "#F6F2EA"
  reading-1: "#F2E9D1"
  reading-2: "#E7F1E7"
  reading-3: "#E4EFF2"
  reading-4: "#F2E4E4"
  reading-night: "#262626"
  reading-ink: "#30372E"
  reading-night-ink: "#DCDDD3"
  cover-forest: "#334F43"
  cover-earth: "#8B6D4E"
  cover-title: "#FFF9ED"
  cover-rule: "#DDD3BB"
  cover-label: "#E6E0D0"
typography:
  headline-large:
    fontSize: "30sp"
    fontWeight: 600
  headline-small:
    fontSize: "24sp"
    fontWeight: 600
  app-bar:
    fontSize: "19sp"
    fontWeight: 600
  body-large:
    fontSize: "16sp"
    lineHeight: 1.6
  body-medium:
    fontSize: "14sp"
    lineHeight: 1.5
  reading-body:
    fontSize: "21sp"
    fontWeight: 400
    lineHeight: 1.75
    letterSpacing: "0.15dp"
  reading-chapter:
    fontSize: "17sp"
    fontWeight: 600
    lineHeight: 1.5
  reading-book-title:
    fontSize: "15sp"
  reading-status:
    fontSize: "12sp"
  shelf-title:
    fontSize: "14sp"
    fontWeight: 600
    lineHeight: 1.4
  cover-title:
    fontSize: "17sp"
    fontWeight: 500
    lineHeight: 1.5
rounded:
  cover: "6dp"
  shelf-item: "8dp"
  input: "14dp"
  continue-reading: "16dp"
spacing:
  compact: "8dp"
  paragraph: "12dp"
  grid-column: "18dp"
  card-inset: "20dp"
  page-inset: "24dp"
  touch-target: "48dp"
components:
  continue-reading:
    rounded: "{rounded.continue-reading}"
    padding: "{spacing.card-inset}"
  search-input:
    rounded: "{rounded.input}"
  navigation-bar:
    backgroundColor: "{colors.paper}"
  reader-page:
    backgroundColor: "{colors.reading-0}"
    textColor: "{colors.reading-ink}"
    typography: "{typography.reading-body}"
    padding: "0 24dp"
  reader-page-night:
    backgroundColor: "{colors.reading-night}"
    textColor: "{colors.reading-night-ink}"
    typography: "{typography.reading-body}"
    padding: "0 24dp"
  book-cover:
    textColor: "{colors.cover-title}"
    rounded: "{rounded.cover}"
  cache-progress:
    diameter: "36dp"
    strokeWidth: "2.5dp"
    touchTarget: "48dp"
    labelSize: "11sp"
    trackOpacity: 0.16
---

# Design System: 清阅

## Overview

**Creative North Star: "把注意力留给故事"**

清阅是原生 Android 阅读应用。用户已选择米白纸感与墨绿色，并明确把中文正文排版列为优先事项。视觉表现克制、安静、清楚；段落、章节和阅读进度比装饰更重要。

Material 3 提供导航、交互和状态，品牌通过颜色、留白和字重表达。本文记录当前 Flutter 实现，不引入新的视觉方向。数值以 Flutter 逻辑像素（dp）及随系统缩放的字号（sp）表达；未覆盖的角色继承 Flutter Material 3 默认值。

**Key Characteristics:**
- 米白应用表面与墨绿操作色。
- 系统中文字体、明确的段落节奏和可调排版。
- 原生 Material 3 控件与按宽度适配的导航。
- 保留旧版五种阅读底色和独立夜间阅读底色。

## Colors

### Primary

`forest` 用于亮色主操作，`dark-primary` 用于暗色主操作。主题由 `ColorScheme.fromSeed` 生成，再按 `lib/app/reader_theme.dart` 覆盖表面及容器角色。未显式列出的文字、边框、错误和低层容器颜色继续取当前 ColorScheme；不要从截图采样值替代它们。

### Neutral

`paper` 与 `dark-surface` 是应用外壳表面。`primary-container`、`secondary-container` 及其暗色对应值承载选中状态与柔和分区；继续阅读容器使用主容器色的 55% 不透明度。分隔线使用主题 `outlineVariant` 的 65% 不透明度。

阅读页独立使用 `reading-0` 至 `reading-4`，索引与持久化键 `bg_i` 一一对应；夜间使用 `reading-night`。正文使用对应的 `reading-ink` / `reading-night-ink`，书名和页码使用正文色的 72% 不透明度。

**The Reading Background Rule.** 五个阅读底色的数值、顺序和 `bg_i` 映射必须保留，外壳换色不得改变用户已有阅读背景。

封面缺图时，在 `cover-forest` 与 `cover-earth` 之间按书名稳定插值；`cover-title`、`cover-rule` 和 `cover-label` 分别用于标题、短横线和应用名。这是文字封面，不是生成插画。

## Typography

使用 Flutter / Android 系统字体及中文回退，不捆绑装饰字体。前置信息只列应用实际覆盖的字级，Material 的其余 title、label 等角色保持默认。

正文默认使用 `reading-body`，章节名使用 `reading-chapter`，轻量书名栏使用 `reading-book-title`，页码与章节进度使用 `reading-status`。段落首行统一两个全角空格；不把整章压成一个无段落的文本块。

**The Measurement Parity Rule.** 分页的 TextPainter 与绘制的 RichText 必须共用显式 TextStyle、系统 TextScaler、StrutStyle、`zh_CN` locale 和均匀 leading 的 TextHeightBehavior。正文样式为 `inherit: false`，字重 400，strut 不强制固定行盒高度；系统大字必须触发重排。

字号可调 16–30，默认排版保持 21sp / 1.75 倍行高 / 12dp 段间距 / 24dp 左右边距。独立“间距设置”面板提供以下原生 ChoiceChip 选项：

| 行段间距 | 行高倍数 | 段间距 |
| --- | --- | --- |
| 小 | 1.35 | 4dp |
| 较小 | 1.5 | 8dp |
| 适中 | 1.75 | 12dp |
| 大 | 2.0 | 20dp |
| 自定义 | 1.3–2.2 | 4–24dp |

“自定义”显示独立行距、段间距滑块，切换预设后再返回会恢复自定义值。预设选择及自定义值持久化；无预设 ID 的旧设置按既有数值匹配，不重置原排版。排版变化后按文字位置维持阅读锚点。

## Layout

紧凑宽度使用三个目的地的 NavigationBar：书架、书源、设置。可用宽度达到 650dp 时切为带标签的 NavigationRail。遵循系统返回、系统栏和键盘插入区域；阅读正文处于 SafeArea 内。

书架主要内容左右留白 24dp；封面网格列间距 18dp、行间距 24dp。继续阅读容器内边距 20dp，封面与信息分隔 18dp。章节标题下留出 22dp，底部进度垂直内边距 17dp。阅读设置与间距设置均为可滚动底部面板，内容左右及下方留白 24dp，背景选项和预设选项通过 Wrap 换行。

“页面边距”提供小（16dp）、适中（24dp）、较大（32dp）、大（40dp）、智能匹配。智能边距取 `max(16, (屏幕宽度 - min(屏幕宽度 × 0.88, 560)) / 2)`：360dp 屏宽为 21.6dp，800dp 屏宽为 120dp。章节栏、正文、页脚和分页测量共用这一有效边距；智能模式不受手动最大值 40dp 限制。原有非预设手动值在用户选择新选项前继续保留。

## Elevation & Depth

外壳平面优先。AppBar 与 NavigationBar 的显式 elevation 均为 0，AppBar 不加 surface tint。依靠 Material 表面、容器色和暖色细分隔建立层级；底部面板、菜单和对话框保留 Material 原生深度。没有自定义投影词汇。

## Shapes

封面是轻圆角矩形，书架点击区域稍柔和，搜索框与继续阅读容器逐级更圆；确切值见 frontmatter。按钮、导航指示器、滑块和开关继承 Material 3 形状，不另造平行控件系统。

## Components

- **Buttons:** 使用 FilledButton、FilledButton.tonal、TextButton 和 IconButton；继承主题的原生按压、聚焦、禁用与反馈。搜索是明确主操作，继续阅读使用 tonal 按钮。
- **Inputs:** 填充 `surfaceContainerLow` 的无描边圆角搜索框；使用 Material 输入、提交和键盘行为。
- **Navigation:** 紧凑 NavigationBar 的背景跟随表面，选中指示器取主容器色；宽屏用原生 NavigationRail。图标全部来自 Material Icons。
- **Continue reading:** 主容器色的柔和底块，文字与实际封面或文字回退封面并列。书名与章节摘要按行数截断。
- **Reader:** 标准 PageView 横向翻页；左、右区域翻页，中部显隐工具栏。章节目录和排版设置在原生底部面板中呈现；临时反馈用 floating SnackBar。
- **Settings:** 主设置页分别提供“字号与显示”和“间距设置”；阅读设置中的快捷入口关闭当前面板后打开同一个 `showSpacingSettings` 面板。使用原生 Slider、SwitchListTile、RadioListTile 和 ChoiceChip；预设 Chip 有选中状态、标准密度和 padded 点击目标，组内水平间隔 8dp、换行间隔 4dp。背景选项有选中语义、提示及勾号。自定义背景选择和缓存操作的点击目标至少 48dp；新增控件保持 Android 的 48dp 目标。
- **Motion:** 按钮触发翻页为 180ms easeOutCubic；系统关闭动画时使用零时长。其他组件使用 Flutter Material 默认动效。

`.impeccable/design.json` 的 HTML/CSS 仅为面板中的静态角色示意，不是 Flutter 控件实现或像素级原生截图。实现以 Dart 主题和组件为准。

视觉证据来自 Android 16 Pixel 5 模拟器；预览标题及原创样例段落位于 `tool/preview_app.dart`，不是用户书架。没有生成 AI 图片或购买图库素材；启动图标继承原仓库。模拟器截图不能证明华为真机的字体回退、手势或性能表现。

## Do's and Don'ts

### Do:
- Do 把中文段落可读性放在装饰之前，并保留用户可调字号、行高、段间距和边距。
- Do 保持分页测量与正文绘制的字体、缩放、strut 和中文 locale 一致。
- Do 使用原生 Material 3 控件、系统中文字体和随宽度切换的导航。
- Do 保留五种旧阅读背景的值、顺序、存储映射及夜间阅读底色。

### Don'ts:
- Don't 用新的外壳纸色覆盖用户已选阅读背景。
- Don't 把系统大字固定为不缩放的像素，或用裁剪隐藏正文溢出。
- Don't 把预览书籍、样例正文或模拟器截图描述为用户数据或真机验证。
- Don't 添加未在现有实现中使用的装饰字体、插画或自定义控件风格。
