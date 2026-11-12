import 'package:flutter/material.dart';

import '../entity/BookInfo.dart';
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
    final data = await store.sources.detail(book.sourceId, book.Id);
    if (!context.mounted || !visible()) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            BookDetails(store: store, book: BookInfo.fromJson(data)),
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
  final Future<List<BookInfo>> Function()? loadCatalog;

  const RecommendationListScreen({
    super.key,
    required this.store,
    required this.title,
    required this.preview,
    this.loadCatalog,
  });

  @override
  State<RecommendationListScreen> createState() =>
      _RecommendationListScreenState();
}

class _RecommendationListScreenState extends State<RecommendationListScreen> {
  late Future<List<BookInfo>>? catalog = widget.loadCatalog?.call();
  bool opening = false;

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
  Widget build(BuildContext context) => FutureBuilder<List<BookInfo>>(
    future: catalog,
    builder: (context, snapshot) {
      final books = snapshot.data ?? widget.preview;
      final failed = snapshot.hasError;
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
              itemCount: books.length + (failed ? 1 : 0),
              itemBuilder: (context, index) {
                if (failed && index == 0) {
                  return Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('更多书单暂时无法加载'),
                      TextButton(
                        onPressed: () => setState(
                          () => catalog = widget.loadCatalog?.call(),
                        ),
                        child: const Text('重试'),
                      ),
                    ],
                  );
                }
                final book = books[index - (failed ? 1 : 0)];
                return RecommendationBookTile(
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
