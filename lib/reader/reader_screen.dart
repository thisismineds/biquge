import 'dart:async';

import 'package:flutter/material.dart';

import '../app/reader_theme.dart';
import '../entity/BookInfo.dart';
import '../entity/BookTag.dart';
import '../entity/Chapter.dart';
import '../storage/app_store.dart';
import '../ui/cache_progress_button.dart';
import 'reading_layout.dart';

class ReaderScreen extends StatefulWidget {
  final AppStore store;
  final BookInfo book;
  final int? chapterIndex;
  const ReaderScreen({
    super.key,
    required this.store,
    required this.book,
    this.chapterIndex,
  });
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  List<Chapter> _chapters = [];
  List<ReadingPage> _pages = [];
  PageController? _controller;
  String _text = '';
  Record? _layoutKey;
  String? _error;
  int _chapter = 0, _page = 0, _pendingOffset = 0, _attempt = 0;
  int _downloadCached = 0, _downloadTotal = 0;
  bool _attemptEnd = false;
  Map<String, dynamic>? _attemptSaved;
  bool _busy = true, _chrome = true, _end = false, _downloading = false;
  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_changed);
    _initialize();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    try {
      final saved = store.record(widget.book);
      _chapters = await store.loadChapters(widget.book);
      if (!mounted) return;
      var index = widget.chapterIndex ?? (saved?['cur'] as int? ?? 0);
      if (saved != null && widget.chapterIndex == null) {
        final old = BookTag.fromJson(saved);
        if (old.cur >= 0 && old.cur < old.chapters.length) {
          final current = _chapters.indexWhere(
            (c) => c.id == old.chapters[old.cur].id,
          );
          if (current >= 0) index = current;
        }
      }
      await _open(
        index.clamp(0, _chapters.length - 1),
        saved: widget.chapterIndex == null ? saved : null,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _open(
    int index, {
    bool end = false,
    Map<String, dynamic>? saved,
  }) async {
    _attempt = index;
    _attemptEnd = end;
    _attemptSaved = saved;
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final raw = await store.loadContent(widget.book, _chapters[index].id);
      final text = formatChapter(raw);
      if (text.isEmpty) throw StateError('这一章暂时没有可读正文。');
      var offset = 0;
      if (saved != null) {
        final tag = BookTag.fromJson(saved);
        final oldOffset =
            saved['readerOffset'] as int? ??
            (tag.index > 0 && tag.index <= tag.pageOffsets.length
                ? tag.pageOffsets[tag.index - 1]
                : 0);
        final oldText =
            tag.content ?? (saved.containsKey('readerOffset') ? text : raw);
        offset = remapTextOffset(oldText, oldOffset, text);
      }
      if (!mounted) return;
      setState(() {
        _chapter = index;
        _text = text;
        _pendingOffset = offset;
        _end = end;
        _page = 0;
        _pages = [];
        _layoutKey = null;
        _chapters[index].hasContent = 2;
        if (!_downloading) {
          _downloadCached = 0;
          _downloadTotal = 0;
        }
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  void _layout(Size size, ReadingStyle style, TextScaler scaler) {
    final signature = readingLayoutSignature(
      size,
      style,
      store.marginPresetId,
      scaler,
    );
    if (signature == _layoutKey) return;
    final anchor = _pages.isNotEmpty
        ? _pages[_page.clamp(0, _pages.length - 1)].start
        : _pendingOffset;
    _pages = paginateChapter(_text, size, style, textScaler: scaler);
    if (_pages.isEmpty) return;
    _page = _end ? _pages.length - 1 : _pages.indexWhere((p) => anchor < p.end);
    if (_page < 0) _page = _pages.length - 1;
    _end = false;
    _layoutKey = signature;
    final old = _controller;
    _controller = PageController(initialPage: _page + 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      old?.dispose();
      if (mounted) {
        setState(() {});
        _save();
      }
    });
  }

  Future<void> _save() async {
    if (_text.isEmpty || _pages.isEmpty || _error != null || _busy) return;
    final tag = BookTag(_chapter, _page, _chapters, widget.book.Name)
      ..content = _text
      ..pageOffsets = _pages.map((p) => p.end).toList();
    await store.saveProgress(widget.book, tag, _pages[_page].start);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _save();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(_changed);
    _save();
    _controller?.dispose();
    super.dispose();
  }

  void _turn(int delta) {
    if (_busy || _controller == null || !_controller!.hasClients) return;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    _controller!.animateToPage(
      _page + 1 + delta,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  void _pageChanged(int index) {
    if (_busy) return;
    if (index == 0) {
      if (_chapter > 0) {
        _save();
        _open(_chapter - 1, end: true);
      } else {
        _controller?.jumpToPage(1);
      }
    } else if (index == _pages.length + 1) {
      if (_chapter + 1 < _chapters.length) {
        _save();
        _open(_chapter + 1);
      } else {
        _controller?.jumpToPage(_pages.length);
      }
    } else {
      setState(() {
        _page = index - 1;
      });
      _save();
    }
  }

  Future<void> _directory() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .75,
        builder: (context, scroll) => AnimatedBuilder(
          animation: store,
          builder: (context, _) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text('章节目录', style: Theme.of(context).textTheme.titleLarge),
                    Wrap(
                      spacing: 10,
                      children: [
                        Text('共 ${_chapters.length} 章'),
                        Text(
                          '已缓存 ${store.cachedChapterCount(widget.book, _chapters)} 章',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  itemCount: _chapters.length,
                  itemBuilder: (context, i) => ListTile(
                    selected: i == _chapter,
                    title: Text(
                      _chapters[i].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing:
                        store.hasCachedChapter(widget.book, _chapters[i].id)
                        ? const Icon(
                            Icons.offline_pin_outlined,
                            size: 18,
                            semanticLabel: '已缓存',
                          )
                        : null,
                    onTap: () => Navigator.pop(context, i),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      await _save();
      await _open(selected);
    }
  }

  Future<void> _download() async {
    if (_downloading) return;
    final chapters = _chapters.skip(_chapter).toList();
    final cacheRevision = store.cacheRevision(widget.book);
    setState(() {
      _downloading = true;
      _downloadTotal = chapters.length;
      _downloadCached = store.cachedChapterCount(widget.book, chapters);
    });
    try {
      for (final chapter in chapters) {
        if (!mounted) break;
        if (cacheRevision != store.cacheRevision(widget.book)) return;
        if (store.hasCachedChapter(widget.book, chapter.id)) continue;
        await store.loadContent(widget.book, chapter.id);
        if (!mounted) return;
        chapter.hasContent = 2;
        setState(() {
          _downloadCached++;
        });
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (mounted) {
        setState(() {
          _downloadCached = _downloadTotal;
        });
        _notice('缓存完成，离线时也能继续阅读。');
      }
    } catch (e) {
      if (mounted) _notice('已下载的章节会保留。$e');
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
        });
      }
    }
  }

  void _notice(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final style = store.effectiveReadingStyle(MediaQuery.sizeOf(context).width);
    final dark = store.dark;
    final background = dark
        ? const Color(0xFF262626)
        : ReaderTheme.readingBackgrounds[store.backgroundIndex];
    final ink = dark ? const Color(0xFFDCDDD3) : const Color(0xFF30372E);
    final secondary = ink.withValues(alpha: .72);
    return Scaffold(
      backgroundColor: background,
      appBar: _chrome
          ? AppBar(
              backgroundColor: background,
              title: Text(
                widget.book.Name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, color: secondary),
              ),
              actions: [
                IconButton(
                  tooltip: '章节目录',
                  onPressed: _busy ? null : _directory,
                  icon: const Icon(Icons.format_list_bulleted_rounded),
                ),
                IconButton(
                  tooltip: '阅读设置',
                  onPressed: () => showReadingSettings(context, store),
                  icon: const Icon(Icons.text_fields_rounded),
                ),
              ],
            )
          : null,
      body: SafeArea(
        child: _error != null
            ? _errorView()
            : _busy
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_chrome)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        style.horizontalPadding,
                        8,
                        style.horizontalPadding,
                        22,
                      ),
                      child: Text(
                        _chapters[_chapter].name,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          height: 1.5,
                          color: ink,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: style.horizontalPadding,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _layout(
                            Size(constraints.maxWidth, constraints.maxHeight),
                            style,
                            MediaQuery.textScalerOf(context),
                          );
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (details) {
                              final part =
                                  details.localPosition.dx /
                                  constraints.maxWidth;
                              if (part < .28) {
                                _turn(-1);
                              } else if (part > .72) {
                                _turn(1);
                              } else {
                                setState(() {
                                  _chrome = !_chrome;
                                });
                              }
                            },
                            child: PageView.builder(
                              key: ValueKey((_chapter, _layoutKey)),
                              controller: _controller,
                              itemCount: _pages.length + 2,
                              onPageChanged: _pageChanged,
                              itemBuilder: (context, i) =>
                                  i == 0 || i > _pages.length
                                  ? Center(
                                      child: Text(
                                        i == 0 ? '上一章' : '下一章',
                                        style: TextStyle(color: secondary),
                                      ),
                                    )
                                  : ReadingPageView(
                                      page: _pages[i - 1],
                                      style: style,
                                      color: ink,
                                    ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: style.horizontalPadding,
                      vertical: 17,
                    ),
                    child: Row(
                      children: [
                        Text(
                          '${_chapter + 1} / ${_chapters.length} 章',
                          style: TextStyle(color: secondary, fontSize: 12),
                        ),
                        const Spacer(),
                        Text(
                          '第${_page + 1}/${_pages.length}页',
                          style: TextStyle(color: secondary, fontSize: 12),
                        ),
                        if (_chrome) ...[
                          const SizedBox(width: 14),
                          CacheProgressButton(
                            active: _downloading,
                            cached: _downloadCached,
                            total: _downloadTotal,
                            tooltip: '从当前章缓存',
                            onPressed: _downloading ? null : _download,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _errorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, size: 32),
          const SizedBox(height: 18),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: () => _chapters.isEmpty
                ? _initialize()
                : _open(_attempt, end: _attemptEnd, saved: _attemptSaved),
            child: const Text('重新加载'),
          ),
          if (_text.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                _error = null;
              }),
              child: const Text('继续阅读已加载内容'),
            ),
        ],
      ),
    ),
  );
}

Future<void> showReadingSettings(BuildContext context, AppStore store) async {
  final spacing = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => AnimatedBuilder(
      animation: store,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text('阅读设置', style: Theme.of(context).textTheme.titleLarge),
                    const Spacer(),
                    IconButton(
                      tooltip: '关闭阅读设置',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('阅读背景'),
                ),
                Wrap(
                  spacing: 8,
                  children: List.generate(
                    ReaderTheme.readingBackgrounds.length,
                    (i) => Semantics(
                      selected: store.backgroundIndex == i,
                      child: IconButton(
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        visualDensity: VisualDensity.standard,
                        tooltip: '阅读背景 ${i + 1}',
                        onPressed: () => store.setBackgroundIndex(i),
                        style: IconButton.styleFrom(
                          backgroundColor: ReaderTheme.readingBackgrounds[i],
                          foregroundColor: const Color(0xFF30372E),
                          side: BorderSide(
                            color: store.backgroundIndex == i
                                ? ReaderTheme.ink
                                : ReaderTheme.ink.withValues(alpha: .2),
                          ),
                        ),
                        icon: Icon(
                          store.backgroundIndex == i
                              ? Icons.check_rounded
                              : Icons.circle_outlined,
                        ),
                      ),
                    ),
                  ),
                ),
                _ReadingSlider(
                  label: '字号',
                  valueLabel: '${store.readingStyle.fontSize.round()}',
                  value: store.readingStyle.fontSize,
                  min: 16,
                  max: 30,
                  divisions: 14,
                  onChanged: (v) => store.setReadingStyle(
                    store.readingStyle.copyWith(fontSize: v),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.format_line_spacing_rounded),
                  title: const Text('间距设置'),
                  subtitle: const Text('行段间距与页面边距'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, true),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('夜间阅读'),
                  value: store.dark,
                  onChanged: store.setDark,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (spacing == true && context.mounted) {
    await showSpacingSettings(context, store);
  }
}

Future<void> showSpacingSettings(
  BuildContext context,
  AppStore store,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('间距设置', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭间距设置',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text('行段间距', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children:
                    const {
                          'small': '小',
                          'compact': '较小',
                          'comfortable': '适中',
                          'large': '大',
                          'custom': '自定义',
                        }.entries
                        .map(
                          (entry) => ChoiceChip(
                            label: Text(entry.value),
                            selected: store.spacingPresetId == entry.key,
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            visualDensity: VisualDensity.standard,
                            onSelected: (_) =>
                                store.setSpacingPreset(entry.key),
                          ),
                        )
                        .toList(),
              ),
              if (store.spacingPresetId == 'custom') ...[
                _ReadingSlider(
                  label: '行距',
                  valueLabel: store.readingStyle.lineHeight.toStringAsFixed(2),
                  value: store.readingStyle.lineHeight,
                  min: 1.3,
                  max: 2.2,
                  divisions: 18,
                  onChanged: (v) => store.setCustomSpacing(lineHeight: v),
                ),
                _ReadingSlider(
                  label: '段间距',
                  valueLabel: '${store.readingStyle.paragraphGap.round()}',
                  value: store.readingStyle.paragraphGap,
                  min: 4,
                  max: 24,
                  divisions: 10,
                  onChanged: (v) => store.setCustomSpacing(paragraphGap: v),
                ),
              ],
              const SizedBox(height: 24),
              Text('页面边距', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children:
                    const {
                          'small': '小',
                          'normal': '适中',
                          'wide': '较大',
                          'large': '大',
                          'smart': '智能匹配',
                        }.entries
                        .map(
                          (entry) => ChoiceChip(
                            label: Text(entry.value),
                            selected: store.marginPresetId == entry.key,
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            visualDensity: VisualDensity.standard,
                            onSelected: (_) => store.setMarginPreset(entry.key),
                          ),
                        )
                        .toList(),
              ),
              const SizedBox(height: 8),
              Text(
                store.marginPresetId == 'smart'
                    ? '随屏幕宽度调整，宽屏也能舒适阅读。'
                    : '当前边距 ${store.readingStyle.horizontalPadding.round()}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

class _ReadingSlider extends StatelessWidget {
  final String label, valueLabel;
  final double value, min, max;
  final int divisions;
  final ValueChanged<double> onChanged;
  const _ReadingSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      children: [
        Row(
          children: [
            Text(label),
            const Spacer(),
            Text(
              valueLabel,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ],
        ),
        Slider(
          semanticFormatterCallback: (_) => '$label $valueLabel',
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    ),
  );
}
