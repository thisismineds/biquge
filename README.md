# 笔趣阁
基于 Flutter 的安卓小说阅读 App，当前维护仓库为 [thisismineds/biquge](https://github.com/thisismineds/biquge)。原项目来自 leetomlee123/biquge。

## 2026-11-10 书源更新

- 新增笔趣阁 631（https://www.bqg631.xyz/）、酷我小说、新笔趣阁三个可切换来源。
- 在“书源”页选择来源，或在搜索结果上方切换；搜索、详情、目录、正文与离线缓存共用同一数据服务。
- 书架无需登录，书籍、阅读进度和缓存保存在本机。不同书源、不同书籍的相同章节编号不会共用缓存。
- 保留旧版书架记录和缓存；旧来源失效后，请重新搜索添加，旧编号不会自动套用到新站。
- 原失效榜单入口已替换为书源选择。旧账号登录与云同步不再作为阅读前提。

## 开发与验证

本次使用 **Flutter 1.22.6 / Dart 2.10.5** 验证，项目仍使用旧版 Flutter API，尚未迁移到 Dart 3。不要直接用最新版 SDK 判断此版本能否构建。

```sh
flutter pub get
flutter test
flutter analyze
```

`flutter analyze` 仍会报告原有命名风格提示，以及两个旧组件中未覆盖桌面平台的 switch 警告；本次静态检查没有错误。安卓真机安装和完整 APK 构建尚未验证。

需要联网抽查三个来源时，手动运行：

```sh
dart tool/check_sources.dart
```

该脚本只输出书籍信息、章节数和正文长度，不输出小说正文；网络检测不放入离线单元测试。书源的可用性随站点变化，本次仅抽查了每个来源的一本书和首章，不代表全部书籍或章节可用。

Android 调试构建需另外安装 JDK 8、Android SDK 及原项目使用的 Gradle 5.4.1 / Android Gradle Plugin 3.5.2 对应工具。`android/key.properties` 仅用于自己的发布签名，缺少该文件不再阻止调试配置；请勿提交签名文件或密码。

## 代码位置

- `lib/service/book_sources.dart`：站点适配、来源列表和缓存命名规则。笔趣阁 631 的备用接口域名及正文请求编码由其公开网页脚本核实。
- `lib/view/TopBook.dart`：书源选择；`Search.dart`：搜索与详情入口。
- `lib/view/BookShelf.dart`、`BookDetail.dart`、`ReadBook.dart`：本地书架、缓存及阅读。
- `test/`：解析、错误响应、来源隔离、旧记录兼容及阅读流程测试。

以下为原项目界面截图，仅供参考，当前页面已有调整。




![image](https://github.com/leetomlee123/biquge/blob/master/imgs/chapters.jpg)
![image](https://github.com/leetomlee123/biquge/blob/master/imgs/detail.jpg)
![image](https://github.com/leetomlee123/biquge/blob/master/imgs/person.jpg)
![image](https://github.com/leetomlee123/biquge/blob/master/imgs/read.jpg)
![image](https://github.com/leetomlee123/biquge/blob/master/imgs/search.jpg)
![image](https://github.com/leetomlee123/biquge/blob/master/imgs/shelf.jpg)
![image](https://github.com/leetomlee123/biquge/blob/master/imgs/top.jpg)
