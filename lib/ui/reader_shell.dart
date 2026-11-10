import 'package:flutter/material.dart';

import '../entity/Book.dart';
import '../entity/BookInfo.dart';
import '../reader/reader_screen.dart';
import '../service/book_sources.dart';
import '../storage/app_store.dart';
import 'book_cover.dart';
import 'search_screen.dart';
import 'book_details.dart';
import 'cache_management.dart';

class ReaderShell extends StatefulWidget {
  final AppStore store;
  const ReaderShell({super.key, required this.store});
  @override
  State<ReaderShell> createState() => _ReaderShellState();
}

class _ReaderShellState extends State<ReaderShell> {
  int selected = 0;
  static const destinations = [
    NavigationDestination(
      icon: Icon(Icons.auto_stories_outlined),
      selectedIcon: Icon(Icons.auto_stories),
      label: '书架',
    ),
    NavigationDestination(
      icon: Icon(Icons.explore_outlined),
      selectedIcon: Icon(Icons.explore),
      label: '书源',
    ),
    NavigationDestination(icon: Icon(Icons.tune_rounded), label: '设置'),
  ];
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final screens = [
        _Library(store: widget.store),
        _Sources(store: widget.store),
        _Settings(store: widget.store),
      ];
      return LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 650) {
            return Scaffold(
              body: Row(
                children: [
                  NavigationRail(
                    selectedIndex: selected,
                    onDestinationSelected: (i) => setState(() {
                      selected = i;
                    }),
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.auto_stories_outlined),
                        label: Text('书架'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.explore_outlined),
                        label: Text('书源'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.tune_rounded),
                        label: Text('设置'),
                      ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: screens[selected]),
                ],
              ),
            );
          }
          return Scaffold(
            body: screens[selected],
            bottomNavigationBar: NavigationBar(
              selectedIndex: selected,
              destinations: destinations,
              onDestinationSelected: (i) => setState(() {
                selected = i;
              }),
            ),
          );
        },
      );
    },
  );
}

void openSearch(BuildContext context, AppStore store) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => SearchScreen(store: store)));

class _Library extends StatelessWidget {
  final AppStore store;
  const _Library({required this.store});

  void read(BuildContext context, Book b) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ReaderScreen(store: store, book: store.infoFor(b)),
    ),
  );

  Future<void> menu(BuildContext context, Book b) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                b.Name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('书籍详情'),
              onTap: () => Navigator.pop(context, 'details'),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('移出书架'),
              subtitle: const Text('同时删除本书缓存和阅读进度'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('移出书架？'),
          content: Text('《${b.Name}》将移出书架，同时删除本书缓存和阅读进度。再次阅读需要重新缓存。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('移出并删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      try {
        await store.remove(b);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('移出未完成，请重试。$e')));
        }
      }
    }
    if (action == 'details') {
      try {
        final info = BookInfo.fromJson(
          await store.sources.detail(b.sourceId, b.Id),
        );
        if (context.mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => BookDetails(store: store, book: info),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 76,
        title: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text('书架', style: Theme.of(context).textTheme.headlineLarge),
        ),
        actions: [
          IconButton(
            tooltip: '搜索小说',
            onPressed: () => openSearch(context, store),
            icon: const Icon(Icons.search_rounded),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          final failed = await store.refreshShelf();
          if (failed > 0 && context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('$failed 本书暂时无法更新，原记录已保留。')));
          }
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (store.recoveryNotice != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(store.recoveryNotice!),
                ),
              ),
            if (store.shelf.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_stories_outlined,
                          size: 64,
                          color: scheme.primary,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          '下一本好书，等你翻开',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '搜索书名或作者，收藏后就能在这里继续阅读。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: () => openSearch(context, store),
                          icon: const Icon(Icons.search),
                          label: const Text('找一本书'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (store.shelf.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                sliver: SliverToBoxAdapter(
                  child: _continueReading(context, store.shelf.first),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Text(
                        '我的收藏',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      Text(
                        '${store.shelf.length} 本',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final count = (constraints.crossAxisExtent / 112)
                        .floor()
                        .clamp(3, 6);
                    return SliverGrid.builder(
                      itemCount: store.shelf.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: count,
                        crossAxisSpacing: 18,
                        mainAxisSpacing: 24,
                        mainAxisExtent:
                            (constraints.crossAxisExtent - (count - 1) * 18) /
                                count *
                                1.42 +
                            72,
                      ),
                      itemBuilder: (context, i) {
                        final b = store.shelf[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => read(context, b),
                          onLongPress: () => menu(context, b),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: SizedBox(
                                  width: double.infinity,
                                  child: BookCover(title: b.Name, url: b.Img),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                b.Name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                b.NewChapterCount == 1
                                    ? '有新章节'
                                    : store.sourceName(b.sourceId),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: b.NewChapterCount == 1
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _continueReading(BuildContext context, Book b) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BookCover(title: b.Name, url: b.Img, width: 74, height: 106),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  b.Name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 5),
                Text(
                  b.ChapterName.isEmpty ? b.Author : b.ChapterName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.tonal(
                  onPressed: () => read(context, b),
                  child: const Text('继续阅读'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sources extends StatelessWidget {
  final AppStore store;
  const _Sources({required this.store});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 76,
      title: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Text('书源', style: Theme.of(context).textTheme.headlineLarge),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Text('好故事，不止一个入口', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Text(
          '选择搜索使用的书源。遇到站点暂时不可用时，可以换一个再试。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 28),
        RadioGroup<String>(
          groupValue: store.sourceId,
          onChanged: (id) {
            if (id != null) store.selectSource(id);
          },
          child: Column(
            children: BookSources.sources
                .map(
                  (s) => Column(
                    children: [
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        value: s.id,
                        title: Text(s.name),
                        subtitle: Text(Uri.parse(s.url).host),
                      ),
                      const Divider(height: 16),
                    ],
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => openSearch(context, store),
          icon: const Icon(Icons.search),
          label: const Text('搜索小说'),
        ),
      ],
    ),
  );
}

class _Settings extends StatelessWidget {
  final AppStore store;
  const _Settings({required this.store});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 76,
      title: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Text('设置', style: Theme.of(context).textTheme.headlineLarge),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.dark_mode_outlined),
          title: const Text('夜间阅读'),
          subtitle: const Text('降低暗光环境下的屏幕亮度感'),
          value: store.dark,
          onChanged: store.setDark,
        ),
        ListTile(
          leading: const Icon(Icons.text_fields_rounded),
          title: const Text('字号与显示'),
          subtitle: Text(
            '${store.readingStyle.fontSize.round()} 号字 · ${store.readingStyle.lineHeight.toStringAsFixed(2)} 倍行距',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showReadingSettings(context, store),
        ),
        ListTile(
          leading: const Icon(Icons.format_line_spacing_rounded),
          title: const Text('间距设置'),
          subtitle: const Text('行段间距与页面边距'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showSpacingSettings(context, store),
        ),
        const Divider(height: 32),
        const ListTile(
          leading: Icon(Icons.offline_pin_outlined),
          title: Text('离线阅读'),
          subtitle: Text('在书籍详情或阅读页缓存章节，断网后也能继续读。'),
        ),
        ListTile(
          leading: const Icon(Icons.bookmark_border),
          title: const Text('本地保存'),
          subtitle: const Text('按书管理缓存，保留书架和阅读进度'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => CacheManagement(store: store),
            ),
          ),
        ),
        const Divider(height: 32),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('关于清阅'),
          trailing: const Text('2.0'),
          onTap: () => showAboutDialog(
            context: context,
            applicationName: '清阅',
            applicationVersion: '2.0.3',
            children: const [Text('把注意力留给故事。\n第三方书源的内容与可用性由各站点提供。')],
          ),
        ),
      ],
    ),
  );
}
