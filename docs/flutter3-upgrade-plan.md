# Flutter 3 / Dart 3 与阅读排版升级

基线：25dcc41aa1107eda4598ceeaf79e10285ba3ba51。
目标：使用经官方发布清单确认的 Flutter 3.47.9 / Dart 3.13.7，升级安卓工程并改进米白/墨绿界面，提交至用户仓库，APK 放到桌面。

## 不变的约定
- Android 包名 com.example.qingyue；version 2.0.0+2；沿用上一版测试签名以支持覆盖安装。
- 来源 ID bqg631、kuwo、biquges123 和 legacy 不变；JSON 字段名及 cache key 不变。
- 保留现有来源逻辑，不执行远程脚本，不加入通用书源引擎。
- 主体只保留 Flutter SDK、dio、html、encrypt、shared_preferences；不增加复杂状态管理。

## Task 1：数据迁移（worker ownership）
拥有 lib/service/book_sources.dart、lib/entity/ 全部、test/book_sources_test.dart、tool/check_sources.dart。将数据服务升级 Dio 5 和 Dart 3；外部 Map 接口保持不变。手工维护四个必要 DTO Book、BookInfo、Chapter、BookTag；保留原构造函数、公开字段和持久化 JSON，不使用代码生成。旧模型及 .g.dart 仅在不再引用时移除。BookInfo 的缺省文本为 ''，ID 为 int；BookTag 保存 cur、index、chapters、name、pageOffsets、content。sourceId 默认 legacy。新测试必须覆盖长 ID、旧记录、来源隔离和原来源解析。

## Task 2：安卓工程（worker ownership）
拥有 android/（不提交本机配置或缓存）及构建工具脚本。通过新 SDK 模板核实 AGP/Gradle/Kotlin/JDK/SDK 版本，迁移 Android embedding v2。保留包名、图标、应用名、网络权限和本地数据目录；使用新的 Gradle 插件配置。通过本机已存在的调试签名交付可更新的 APK。不要修改 pubspec 或 lib。工具下载放在工作区 work/，不改系统 Java 注册表和全局环境。

## Task 3：现代 Flutter 界面及排版（root ownership）
拥有 pubspec、lib/main.dart、lib/app、lib/ui、lib/reader、lib/storage 及旧 lib/view/common/store/model/action/event 的清理。使用内置 ChangeNotifier/ValueListenable 和 SharedPreferences 封装存储。保留本地键名及旧阅读记录。界面为书架/书源/设置三个目的地，紧凑手机用 Material 3 导航，宽屏用 NavigationRail。阅读页使用统一的 TextStyle、TextScaler、StrutStyle 进行测量和绘制；正文保留段落、统一首行缩进，默认 21sp、1.75 行高、12dp 段间距、24dp 左右留白。字号、行高、段间距、边距可调并持久化。使用标准 PageView 跨章翻页、目录跳转、缓存与进度保存，保持 UTF-16 内容连续，避免漏字或重复。

## Direction contract
THESIS：中文小说阅读优先，正文段落成为视觉主角。
OWN-WORLD：米白纸面、深墨绿操作色、低对比暖色分隔；系统中文字体，清楚的字重层次，Material 3 控件。
STORY：书架一眼找到正在读的书，搜索选择来源，阅读页提供安静的正文及可找到的设置。
FIRST VIEWPORT：书架大标题和搜索动作，下方一块继续阅读区域与封面网格；阅读页轻量章节栏、宽松正文与底部页码，设置集中到一个底部面板。
FORM：用户明确选择的纸感/墨绿，按真实应用代码先实现，再提供实际界面截图；不生成概念效果图冒充成品。
FINISH：单元与界面测试、真实书源抽查、界面截图检查、独立审查、文档、GitHub 提交、签名校验和桌面 APK 一并交付。

## Task 4：验证与交付
- 保留并迁移原 13 项测试；添加分段排版、分页连续性、设置重排与进度兼容测试。
- 截图应包含阅读页与书架；采用明确标注的预览样例，不将小说演示数据写入用户书架。
- 联网验证三个来源；完整静态检查；Android 构建、apksigner 及桌面复制哈希一致性验证。
- 仅提交用户仓库 master；上传前检查远端 parent，禁止强制覆盖。

## 执行中的用户补充
根据用户提供的间距设置截图，增加独立的行段间距五档（含自定义）与页面边距五档（含智能匹配），两处入口共用，保存选项和自定义数值。新增回归测试及原生重启持久化验证；阅读背景不改变。
