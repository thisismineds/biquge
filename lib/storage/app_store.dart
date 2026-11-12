import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../entity/Book.dart';
import '../entity/BookInfo.dart';
import '../entity/BookTag.dart';
import '../entity/Chapter.dart';
import '../reader/reading_layout.dart';
import '../service/book_sources.dart';

class AppStore extends ChangeNotifier {
  static const spacingPresets = {
    'small': (1.35, 4.0),
    'compact': (1.5, 8.0),
    'comfortable': (1.75, 12.0),
    'large': (2.0, 20.0),
  };
  static const marginPresets = {
    'small': 16.0,
    'normal': 24.0,
    'wide': 32.0,
    'large': 40.0,
  };
  final SharedPreferences preferences;
  final BookSources sources;
  static const _bqgHostKey = 'bqg631.apiHost';
  final Map<String, int> _cacheRevisions = {};
  final Map<(String, int), Future<String>> _pendingContent = {};
  List<Book> shelf = [];
  String? recoveryNotice;
  String sourceId = 'bqg631';
  ReadingStyle readingStyle = const ReadingStyle();
  bool dark = false;
  int backgroundIndex = 0;
  String spacingPresetId = 'comfortable', marginPresetId = 'normal';
  double? _customLineHeight, _customParagraphGap;

  AppStore(this.preferences, {BookSources? sources})
    : sources = sources ?? BookSources.instance {
    final savedHost = preferences.getString(_bqgHostKey);
    this.sources.bqgHost = BookSources.bqgHosts.contains(savedHost)
        ? savedHost
        : null;
    final savedSource = preferences.getString('activeSourceId');
    if (BookSources.sources.any((s) => s.id == savedSource)) {
      sourceId = savedSource!;
    }
    BookSources.activeId = sourceId;
    dark = preferences.getBool('readerDark') ?? false;
    backgroundIndex = (preferences.getInt('bg_i') ?? 0).clamp(0, 4);
    readingStyle = ReadingStyle(
      fontSize: preferences.getDouble('reader.fontSize') ?? 21,
      lineHeight: preferences.getDouble('reader.lineHeight') ?? 1.75,
      paragraphGap: preferences.getDouble('reader.paragraphGap') ?? 12,
      horizontalPadding: preferences.getDouble('reader.padding') ?? 24,
    );
    final spacing = preferences.getString('reader.spacingPreset');
    spacingPresetId = spacing == 'custom' || spacingPresets.containsKey(spacing)
        ? spacing!
        : _spacingPresetFor(readingStyle);
    final margin = preferences.getString('reader.marginPreset');
    marginPresetId =
        margin == 'smart' ||
            margin == 'custom' ||
            marginPresets.containsKey(margin)
        ? margin!
        : _marginPresetFor(readingStyle.horizontalPadding);
    _customLineHeight =
        preferences.getDouble('reader.customLineHeight') ??
        (spacingPresetId == 'custom' ? readingStyle.lineHeight : null);
    _customParagraphGap =
        preferences.getDouble('reader.customParagraphGap') ??
        (spacingPresetId == 'custom' ? readingStyle.paragraphGap : null);
    final raw = preferences.getString('booklist');
    if (raw != null && raw.isNotEmpty) {
      try {
        shelf = (jsonDecode(raw) as List)
            .map((b) => Book.fromJson(Map<String, dynamic>.from(b as Map)))
            .toList();
      } catch (_) {
        recoveryNotice = '原书架记录暂时无法读取，原始数据已保留。';
      }
    }
  }

  static Future<AppStore> load() async =>
      AppStore(await SharedPreferences.getInstance());
  String key(BookInfo b) => BookSources.recordKey(b.sourceId, b.Id);
  String chaptersKey(BookInfo b) =>
      b.sourceId == 'legacy' ? '${b.Id}chapters' : '${key(b)}:chapters';
  String contentKey(BookInfo b, int chapter) =>
      BookSources.contentKey(b.sourceId, b.Id, chapter);
  bool contains(BookInfo b) =>
      shelf.any((s) => s.Id == b.Id && s.sourceId == b.sourceId);

  String sourceName(String id) => id == 'legacy'
      ? '旧版书源'
      : BookSources.sources.where((s) => s.id == id).firstOrNull?.name ??
            '未知书源';

  Future<void> selectSource(String id) async {
    BookSources.source(id);
    sourceId = id;
    BookSources.activeId = id;
    await preferences.setString('activeSourceId', id);
    notifyListeners();
  }

  Future<void> setDark(bool value) async {
    dark = value;
    await preferences.setBool('readerDark', value);
    notifyListeners();
  }

  Future<void> setBackgroundIndex(int value) async {
    backgroundIndex = value.clamp(0, 4);
    await preferences.setInt('bg_i', backgroundIndex);
    notifyListeners();
  }

  Future<void> setReadingStyle(ReadingStyle value) async {
    if (value.lineHeight != readingStyle.lineHeight ||
        value.paragraphGap != readingStyle.paragraphGap) {
      spacingPresetId = _spacingPresetFor(value);
      if (spacingPresetId == 'custom') {
        _customLineHeight = value.lineHeight;
        _customParagraphGap = value.paragraphGap;
      }
    }
    if (value.horizontalPadding != readingStyle.horizontalPadding) {
      marginPresetId = _marginPresetFor(value.horizontalPadding);
    }
    readingStyle = value;
    await _saveReadingStyle();
  }

  static String _spacingPresetFor(ReadingStyle style) =>
      spacingPresets.entries
          .where(
            (entry) =>
                entry.value.$1 == style.lineHeight &&
                entry.value.$2 == style.paragraphGap,
          )
          .firstOrNull
          ?.key ??
      'custom';

  static String _marginPresetFor(double padding) =>
      marginPresets.entries
          .where((entry) => entry.value == padding)
          .firstOrNull
          ?.key ??
      'custom';

  Future<void> setSpacingPreset(String id) async {
    if (id != 'custom' && !spacingPresets.containsKey(id)) {
      throw ArgumentError.value(id, 'id', 'Unknown spacing preset');
    }
    spacingPresetId = id;
    if (id == 'custom') {
      _customLineHeight ??= readingStyle.lineHeight;
      _customParagraphGap ??= readingStyle.paragraphGap;
      readingStyle = readingStyle.copyWith(
        lineHeight: _customLineHeight,
        paragraphGap: _customParagraphGap,
      );
    } else {
      final preset = spacingPresets[id]!;
      readingStyle = readingStyle.copyWith(
        lineHeight: preset.$1,
        paragraphGap: preset.$2,
      );
    }
    await _saveReadingStyle();
  }

  Future<void> setCustomSpacing({
    double? lineHeight,
    double? paragraphGap,
  }) async {
    spacingPresetId = 'custom';
    readingStyle = readingStyle.copyWith(
      lineHeight: lineHeight,
      paragraphGap: paragraphGap,
    );
    _customLineHeight = readingStyle.lineHeight;
    _customParagraphGap = readingStyle.paragraphGap;
    await _saveReadingStyle();
  }

  Future<void> setMarginPreset(String id) async {
    if (id != 'smart' && !marginPresets.containsKey(id)) {
      throw ArgumentError.value(id, 'id', 'Unknown margin preset');
    }
    marginPresetId = id;
    if (id != 'smart') {
      readingStyle = readingStyle.copyWith(
        horizontalPadding: marginPresets[id],
      );
    }
    await _saveReadingStyle();
  }

  ReadingStyle effectiveReadingStyle(double screenWidth) =>
      marginPresetId == 'smart'
      ? readingStyle.copyWith(
          horizontalPadding: math.max(
            16,
            (screenWidth - math.min(screenWidth * .88, 560)) / 2,
          ),
        )
      : readingStyle;

  Future<void> _saveReadingStyle() async {
    final value = readingStyle;
    await Future.wait([
      preferences.setDouble('reader.fontSize', value.fontSize),
      preferences.setDouble('reader.lineHeight', value.lineHeight),
      preferences.setDouble('reader.paragraphGap', value.paragraphGap),
      preferences.setDouble('reader.padding', value.horizontalPadding),
      preferences.setString('reader.spacingPreset', spacingPresetId),
      preferences.setString('reader.marginPreset', marginPresetId),
      if (_customLineHeight != null)
        preferences.setDouble('reader.customLineHeight', _customLineHeight!),
      if (_customParagraphGap != null)
        preferences.setDouble(
          'reader.customParagraphGap',
          _customParagraphGap!,
        ),
    ]);
    notifyListeners();
  }

  Future<void> _saveShelf() async {
    if (recoveryNotice != null &&
        !preferences.containsKey('booklist.recovery')) {
      await preferences.setString(
        'booklist.recovery',
        preferences.getString('booklist') ?? '',
      );
    }
    await preferences.setString('booklist', jsonEncode(shelf));
    notifyListeners();
  }

  Future<void> add(BookInfo b) async {
    await preferences.setString('info:${key(b)}', jsonEncode(b));
    if (contains(b)) return;
    shelf.insert(
      0,
      Book(
        0,
        '',
        0,
        b.Id,
        b.Name,
        b.Author,
        b.Img,
        b.LastChapterId,
        b.LastChapter,
        b.LastTime,
      )..sourceId = b.sourceId,
    );
    await _saveShelf();
  }

  Future<void> remove(Book b) async {
    final info = infoFor(b);
    await clearCache(info);
    for (final localKey in [
      key(info),
      chaptersKey(info),
      'info:${key(info)}',
    ]) {
      await _removeLocalKey(localKey);
    }
    shelf.removeWhere((s) => s.Id == b.Id && s.sourceId == b.sourceId);
    await _saveShelf();
  }

  int cacheRevision(BookInfo book) => _cacheRevisions[key(book)] ?? 0;

  Future<void> advanceBqgHost(BookInfo book, {int? chapterId}) async {
    final hosts = BookSources.bqgHosts;
    final current =
        sources.bqgHost ??
        sources.bqgFallbackFor(book.Id, chapterId) ??
        hosts.first;
    final next = hosts[(hosts.indexOf(current) + 1) % hosts.length];
    if (!await preferences.setString(_bqgHostKey, next)) {
      throw SourceException('无法保存所选接口，请重试。');
    }
    sources.bqgHost = next;
    _cacheRevisions[key(book)] = cacheRevision(book) + 1;
  }

  Set<String> _cachedContentKeys(BookInfo book) {
    if (book.sourceId != 'legacy') {
      final prefix = 'content:${book.sourceId}:${book.Id}:';
      return preferences
          .getKeys()
          .where(
            (k) =>
                k.startsWith(prefix) &&
                int.tryParse(k.substring(prefix.length)) != null,
          )
          .toSet();
    }
    return cachedChapters(book)
        .where((c) => c.id > 0 && c.hasContent > 0)
        .map((c) => contentKey(book, c.id))
        .where(preferences.containsKey)
        .where((k) {
          try {
            final value = jsonDecode(preferences.getString(k)!);
            if (value is Map<String, dynamic> && value['chapters'] is List) {
              return false;
            }
          } catch (_) {
            /* Legacy chapter bodies are plain text. */
          }
          return true;
        })
        .toSet();
  }

  int cachedBookChapterCount(BookInfo book) =>
      _cachedContentKeys(book)
          .where((k) => preferences.getString(k)?.trim().isNotEmpty ?? false)
          .length;

  List<BookInfo> get cachedBooks {
    final books = {for (final b in shelf) key(infoFor(b)): infoFor(b)};
    for (final localKey in preferences.getKeys()) {
      if (localKey.startsWith('info:')) {
        try {
          final b = BookInfo.fromJson(
            jsonDecode(preferences.getString(localKey)!)
                as Map<String, dynamic>,
          );
          books[key(b)] = b;
        } catch (_) {
          /* Other valid cache keys can still identify the book. */
        }
      }
      final content = RegExp(r'^content:([^:]+):(\d+):\d+$')
          .firstMatch(localKey);
      if (content != null) {
        final b = BookInfo.id(int.parse(content[2]!), '书籍 ${content[2]}')
          ..sourceId = content[1]!;
        books.putIfAbsent(key(b), () => b);
      }
      if (RegExp(r'^\d+$').hasMatch(localKey)) {
        try {
          final saved = jsonDecode(preferences.getString(localKey)!);
          if (saved is Map<String, dynamic> && saved['chapters'] is List) {
            final b = BookInfo.id(
              int.parse(localKey),
              saved['name'] as String? ?? '旧版书籍 $localKey',
            );
            books[key(b)] = b;
          }
        } catch (_) {
          /* Numeric legacy chapter keys contain plain text. */
        }
      }
      final toc = RegExp(r'^(\d+)chapters$').firstMatch(localKey);
      if (toc != null) {
        final b = BookInfo.id(int.parse(toc[1]!), '旧版书籍 ${toc[1]}');
        books.putIfAbsent(key(b), () => b);
      }
    }
    return books.values
        .where(
          (b) =>
              cachedBookChapterCount(b) > 0 ||
              (record(b)?['content'] as String?)?.trim().isNotEmpty == true,
        )
        .toList()
      ..sort((a, b) => a.Name.compareTo(b.Name));
  }

  Future<void> _removeLocalKey(String localKey) async {
    if (!await preferences.remove(localKey)) {
      throw StateError('删除缓存失败，请重试。');
    }
  }

  Future<void> clearCache(BookInfo book) async {
    _cacheRevisions[key(book)] = cacheRevision(book) + 1;
    for (final localKey in _cachedContentKeys(book)) {
      await _removeLocalKey(localKey);
    }
    // Reading records also contained a copy of the current chapter's text.
    final saved = record(book);
    if (saved != null) {
      saved.remove('content');
      if (!await preferences.setString(key(book), jsonEncode(saved))) {
        throw StateError('删除缓存失败，请重试。');
      }
    }
    notifyListeners();
  }

  BookInfo infoFor(Book b) {
    final raw = preferences.getString(
      'info:${BookSources.recordKey(b.sourceId, b.Id)}',
    );
    if (raw != null) {
      try {
        return BookInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        /* The shelf itself still contains enough metadata to open cached text. */
      }
    }
    return BookInfo.id(b.Id, b.Name)
      ..sourceId = b.sourceId
      ..Author = b.Author
      ..Img = b.Img
      ..LastChapter = b.LastChapter
      ..LastChapterId = b.LastChapterId
      ..LastTime = b.UpdateTime;
  }

  Map<String, dynamic>? record(BookInfo b) {
    final raw = preferences.getString(key(b));
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  List<Chapter> cachedChapters(BookInfo b) {
    final raw = preferences.getString(chaptersKey(b));
    try {
      if (raw != null) {
        return (jsonDecode(raw) as List)
            .map((c) => Chapter.fromJson(c))
            .toList();
      }
      final saved = record(b);
      if (saved != null) return BookTag.fromJson(saved).chapters;
    } catch (_) {
      /* A failed directory read never deletes the underlying cached chapters. */
    }
    return [];
  }

  Future<List<Chapter>> loadChapters(BookInfo b) async {
    final revision = cacheRevision(b);
    if (b.sourceId == 'legacy') {
      final cached = cachedChapters(b)
          .where((c) => c.hasContent > 0 && c.id > 0)
          .toList();
      if (cached.isEmpty) throw SourceException('旧版书源已失效，请重新搜索；已有缓存仍会保留。');
      return cached;
    }
    try {
      final data = await sources.chapters(b.sourceId, b.Id);
      if (revision != cacheRevision(b)) throw SourceException('本书缓存已清理，请重新打开。');
      final chapters = data.map(Chapter.fromJson).toList();
      for (final c in chapters) {
        if (preferences.containsKey(contentKey(b, c.id))) c.hasContent = 2;
      }
      await preferences.setString(chaptersKey(b), jsonEncode(chapters));
      return chapters;
    } catch (_) {
      final cached = cachedChapters(b);
      if (cached.isEmpty) rethrow;
      return cached;
    }
  }

  Future<String> loadContent(
    BookInfo b,
    int chapter, {
    bool refresh = false,
  }) async {
    final revision = cacheRevision(b);
    final localKey = contentKey(b, chapter);
    final cached = preferences.getString(localKey);
    if (!refresh && cached != null && cached.trim().isNotEmpty) return cached;

    Future<String> fetch() async {
      final text = await sources.content(b.sourceId, b.Id, chapter);
      if (revision != cacheRevision(b)) {
        throw SourceException('本书缓存已变更，请重试。');
      }
      if (formatChapter(text).isEmpty) {
        throw SourceException('这个接口没有可读正文。');
      }
      await preferences.setString(localKey, text);
      notifyListeners();
      return text;
    }

    final requestKey = (localKey, revision);
    final pending = _pendingContent[requestKey];
    if (pending != null) return pending;
    final request = _pendingContent[requestKey] = fetch();
    try {
      return await request;
    } finally {
      _pendingContent.remove(requestKey);
    }
  }

  bool hasCachedChapter(BookInfo book, int chapter) =>
      preferences.getString(contentKey(book, chapter))?.trim().isNotEmpty ??
      false;

  int cachedChapterCount(BookInfo book, Iterable<Chapter> chapters) => chapters
      .where((c) => c.hasContent > 0 && hasCachedChapter(book, c.id))
      .length;

  Future<void> saveProgress(BookInfo b, BookTag tag, int textOffset) async {
    final data = tag.toJson()..['readerOffset'] = textOffset;
    if (tag.chapters.isNotEmpty &&
        tag.cur >= 0 &&
        tag.cur < tag.chapters.length &&
        !hasCachedChapter(b, tag.chapters[tag.cur].id)) {
      data.remove('content');
    }
    await preferences.setString(key(b), jsonEncode(data));
    final index = shelf.indexWhere(
      (s) => s.Id == b.Id && s.sourceId == b.sourceId,
    );
    if (index >= 0 && tag.chapters.isNotEmpty) {
      final current = shelf.removeAt(index);
      current.ChapterId = tag.chapters[tag.cur].id;
      current.ChapterName = tag.chapters[tag.cur].name;
      shelf.insert(0, current);
      await _saveShelf();
    }
  }

  Future<int> refreshShelf() async {
    var failed = 0;
    for (final item in List<Book>.from(shelf)) {
      if (item.sourceId == 'legacy') continue;
      try {
        final data = await sources.detail(item.sourceId, item.Id);
        final current = shelf
            .where((s) => s.Id == item.Id && s.sourceId == item.sourceId)
            .firstOrNull;
        if (current == null) continue;
        if (current.LastChapter != data['LastChapter']) {
          current.NewChapterCount = 1;
        }
        current.LastChapter = data['LastChapter'] as String;
        current.LastChapterId = data['LastChapterId'] as int;
        current.UpdateTime = data['LastTime'] as String;
        await preferences.setString(
          'info:${BookSources.recordKey(item.sourceId, item.Id)}',
          jsonEncode(data),
        );
      } catch (_) {
        failed++;
      }
    }
    await _saveShelf();
    return failed;
  }
}
