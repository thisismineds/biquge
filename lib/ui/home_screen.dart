import 'package:flutter/material.dart';

import '../entity/BookInfo.dart';
import '../service/book_sources.dart';
import '../storage/app_store.dart';
import 'book_cover.dart';
import 'book_details.dart';

class HomeScreen extends StatefulWidget {
  final AppStore store;
  final VoidCallback onSearch;
  final bool active;

  const HomeScreen({
    super.key,
    required this.store,
    required this.onSearch,
    required this.active,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, List<BookInfo>>? sections;
  String? category;
  bool loading = false, opening = false;
  bool get visible => widget.active && ModalRoute.isCurrentOf(context) == true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      final next = await widget.store.sources.recommendations();
      if (!mounted) return;
      setState(() {
        sections = next;
        if (!next.containsKey(category)) category = null;
      });
    } catch (_) {
      if (mounted && visible && sections != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('推荐暂时无法更新，已保留上次加载的书单。')));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> open(BookInfo book) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      final data = await widget.store.sources.detail(book.sourceId, book.Id);
      if (!mounted || !visible) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              BookDetails(store: widget.store, book: BookInfo.fromJson(data)),
        ),
      );
    } catch (_) {
      if (mounted && visible) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('书籍详情暂时打不开，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = sections;
    final featured = data?['hotlist']?.take(4).toList() ?? const <BookInfo>[];
    final featuredIds = featured.map((book) => book.Id).toSet();
    final popular = (data?['toplist'] ?? const <BookInfo>[])
        .where((book) => !featuredIds.contains(book.Id))
        .toList();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 76,
        title: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text('首页', style: Theme.of(context).textTheme.headlineLarge),
        ),
        actions: [
          IconButton(
            tooltip: '搜索小说',
            onPressed: widget.onSearch,
            icon: const Icon(Icons.search_rounded),
          ),
          const SizedBox(width: 12),
        ],
        bottom: opening
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator(minHeight: 3),
              )
            : null,
      ),
      body: data == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: loading
                    ? const CircularProgressIndicator(semanticsLabel: '正在加载推荐')
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('暂时无法加载推荐', textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton.tonal(
                            onPressed: load,
                            child: const Text('重新加载'),
                          ),
                        ],
                      ),
              ),
            )
          : RefreshIndicator(
              onRefresh: load,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(24, 6, 24, 28),
                    children: [
                      Text(
                        '分类推荐',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 2,
                        children: [
                          choice('综合', null),
                          for (final entry
                              in BookSources.recommendationCategories.entries)
                            if (data.containsKey(entry.key))
                              choice(entry.value, entry.key),
                        ],
                      ),
                      const SizedBox(height: 22),
                      Text(
                        category == null
                            ? '综合推荐'
                            : BookSources.recommendationCategories[category]!,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '来自笔趣阁 631',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (category != null)
                        for (final book in data[category]!) bookRow(book)
                      else ...[
                        if (featured.isNotEmpty) featureCovers(featured),
                        if (popular.isNotEmpty) ...[
                          if (featured.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            Text(
                              '强力推荐',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                          ],
                          for (final book in popular) bookRow(book),
                        ],
                      ],
                      if (category == null &&
                          featured.isEmpty &&
                          popular.isEmpty)
                        const Text('综合书单暂未更新，可以选择上方分类。'),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget choice(String label, String? value) => ChoiceChip(
    label: Text(label),
    selected: category == value,
    showCheckmark: false,
    onSelected: (_) => setState(() => category = value),
  );

  Widget featureCovers(List<BookInfo> books) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 12.0;
      final columns =
          constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(14) > 21
          ? 2
          : 4;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      final height = (width * 1.43).clamp(100.0, 205.0);
      return Wrap(
        spacing: gap,
        runSpacing: 16,
        children: [
          for (final book in books)
            SizedBox(
              width: width,
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: opening ? null : () => open(book),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BookCover(
                      title: book.Name,
                      url: book.Img,
                      width: width,
                      height: height,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      book.Name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget bookRow(BookInfo book) => InkWell(
    onTap: opening ? null : () => open(book),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          BookCover(title: book.Name, url: book.Img, width: 54, height: 76),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.Name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (book.Author.isNotEmpty)
                  Text(
                    book.Author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    ),
  );
}
