import 'package:flutter/material.dart';

import '../entity/BookInfo.dart';
import '../service/book_sources.dart';
import '../storage/app_store.dart';
import 'book_cover.dart';
import 'book_details.dart';

Future<void> openRecommendedBook(
  BuildContext context,
  AppStore store,
  BookInfo book, {
  bool Function()? active,
}) async {
  bool visible() =>
      (active?.call() ?? true) && ModalRoute.isCurrentOf(context) == true;
  try {
    final detail = await store.sources.recommendationDetail(book);
    if (!context.mounted || !visible()) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BookDetails(store: store, book: detail),
      ),
    );
  } catch (_) {
    if (context.mounted && visible()) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('书籍详情暂时打不开，请稍后重试。')));
    }
  }
}

class RecommendationListScreen extends StatefulWidget {
  final AppStore store;
  final String title;
  final List<BookInfo> preview;
  final Future<RecommendationPage> Function(int page)? loadCatalog;
  final bool allowUpdateSort;

  const RecommendationListScreen({
    super.key,
    required this.store,
    required this.title,
    required this.preview,
    this.loadCatalog,
    this.allowUpdateSort = false,
  });

  @override
  State<RecommendationListScreen> createState() =>
      _RecommendationListScreenState();
}

class _RecommendationListScreenState extends State<RecommendationListScreen> {
  late Future<RecommendationPage>? catalog = widget.loadCatalog?.call(1);
  final extraBooks = <BookInfo>[];
  bool loadingNext = false, nextFailed = false;
  bool? hasMoreAfterLoad;
  int nextPage = 2;
  bool opening = false;
  bool newest = false, checking = false;
  int sortRun = 0, checked = 0;
  final updates = <int, BookInfo>{};
  final attempted = <int>{};

  Future<void> loadNext(RecommendationPage firstPage) async {
    if (loadingNext) return;
    setState(() {
      loadingNext = true;
      nextFailed = false;
    });
    try {
      final next = await widget.loadCatalog!(nextPage);
      if (!mounted) return;
      final seen = {
        ...firstPage.books,
        ...extraBooks,
      }.map((book) => book.Id).toSet();
      setState(() {
        extraBooks.addAll(next.books.where((book) => seen.add(book.Id)));
        hasMoreAfterLoad = next.hasMore;
        nextPage++;
      });
      if (newest) checkUpdates([...firstPage.books, ...extraBooks]);
    } catch (_) {
      if (mounted) setState(() => nextFailed = true);
    } finally {
      if (mounted) setState(() => loadingNext = false);
    }
  }

  Future<void> checkUpdates(List<BookInfo> books) async {
    final run = ++sortRun;
    final missing = books.where(
      (book) => book.LastTime.isEmpty && !updates.containsKey(book.Id),
    );
    final pending = [
      ...missing.where((book) => !attempted.contains(book.Id)),
      ...missing.where((book) => attempted.contains(book.Id)),
    ];
    setState(() {
      newest = true;
      checking = pending.isNotEmpty;
      checked = books.length - pending.length;
    });
    var failedBatches = 0;
    for (var i = 0; i < pending.length; i += 4) {
      final requests = pending.skip(i).take(4);
      final batch = await Future.wait(
        requests.map((book) async {
          try {
            return await widget.store.sources.recommendationDetail(book);
          } catch (_) {
            return null;
          }
        }),
      );
      if (!mounted || run != sortRun) return;
      setState(() {
        attempted.addAll(requests.map((book) => book.Id));
        for (final book in batch.nonNulls) {
          updates[book.Id] = book;
        }
        checked += batch.length;
      });
      failedBatches = batch.every((book) => book == null)
          ? failedBatches + 1
          : 0;
      if (failedBatches == 2) break;
    }
    if (mounted && run == sortRun) setState(() => checking = false);
  }

  Widget sortOptions(List<BookInfo> books, int unknownDates) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('书源顺序'),
              selected: !newest,
              onSelected: (selected) {
                if (!selected) return;
                setState(() {
                  sortRun++;
                  newest = false;
                  checking = false;
                });
              },
            ),
            ChoiceChip(
              label: const Text('最近更新'),
              selected: newest,
              onSelected: (selected) {
                if (selected) checkUpdates(books);
              },
            ),
          ],
        ),
        if (newest && checking) Text('正在查询更新时间 $checked / ${books.length}'),
        if (newest && !checking && unknownDates > 0)
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('$unknownDates 本书暂无更新时间，已放在列表末尾'),
              if (books.any(
                (book) =>
                    book.LastTime.isEmpty && !updates.containsKey(book.Id),
              ))
                TextButton(
                  onPressed: () => checkUpdates(books),
                  child: const Text('补查'),
                ),
            ],
          ),
      ],
    ),
  );

  Future<void> open(BookInfo book) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      await openRecommendedBook(context, widget.store, book);
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<RecommendationPage>(
    future: catalog,
    builder: (context, snapshot) {
      final firstPage = snapshot.data;
      final original = [...(firstPage?.books ?? widget.preview), ...extraBooks];
      final hasMore = hasMoreAfterLoad ?? firstPage?.hasMore ?? false;
      final dated = original.map((book) => updates[book.Id] ?? book);
      final books = newest ? BookSources.recentFirst(dated) : dated.toList();
      final failed = snapshot.hasError;
      final canSort = widget.allowUpdateSort && snapshot.hasData;
      final header = failed || canSort ? 1 : 0;
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          bottom: opening || snapshot.connectionState == ConnectionState.waiting
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(3),
                  child: LinearProgressIndicator(minHeight: 3),
                )
              : null,
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
              itemCount: books.length + header + (hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (canSort && index == 0) {
                  return sortOptions(
                    original,
                    books.where((book) => book.LastTime.isEmpty).length,
                  );
                }
                if (failed && index == 0) {
                  return Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('更多书单暂时无法加载'),
                      TextButton(
                        onPressed: () => setState(
                          () => catalog = widget.loadCatalog?.call(1),
                        ),
                        child: const Text('重试'),
                      ),
                    ],
                  );
                }
                if (index == books.length + header) {
                  return Center(
                    child: TextButton(
                      onPressed: loadingNext
                          ? null
                          : () => loadNext(firstPage!),
                      child: Text(
                        loadingNext
                            ? '正在加载'
                            : nextFailed
                            ? '加载失败，重试'
                            : '加载更多',
                      ),
                    ),
                  );
                }
                final book = books[index - header];
                return RecommendationBookTile(
                  key: ValueKey((book.sourceId, book.Id)),
                  book: book,
                  onTap: opening ? null : () => open(book),
                );
              },
            ),
          ),
        ),
      );
    },
  );
}

class RecommendationBookTile extends StatelessWidget {
  final BookInfo book;
  final VoidCallback? onTap;

  const RecommendationBookTile({super.key, required this.book, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final metadata = [
      if (book.LastTime.isNotEmpty) '${book.LastTime} 更新',
      if (book.Author.isNotEmpty) book.Author,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            BookCover(title: book.Name, url: book.Img, width: 48, height: 68),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.Name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  if (metadata.isNotEmpty)
                    Text(
                      metadata,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                  if (book.LastChapter.isNotEmpty)
                    Text(
                      book.LastChapter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
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
}
