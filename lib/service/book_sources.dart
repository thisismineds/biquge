import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart' as cipher;
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' show Element;

class SourceException implements Exception {
  final String message;
  SourceException(this.message);
  @override
  String toString() => message;
}

class BookSource {
  final String id, name, url;
  const BookSource(this.id, this.name, this.url);
}

/// Adapts the three sites to the existing reader's JSON models.
class BookSources {
  static const sources = <BookSource>[
    BookSource('bqg631', '笔趣阁 631', 'https://www.bqg631.xyz/'),
    BookSource('kuwo', '酷我小说', 'https://appi.kuwo.cn/'),
    BookSource('biquges123', '新笔趣阁', 'https://www.biquges123.com/'),
  ];
  static final instance = BookSources();
  static String activeId = 'bqg631';
  static const bqgHosts = ['apibi.cc', 'apiqu.cc', 'apige.cc'];
  String? bqgHost;
  final Map<(int, int), String> _bqgFallbackByChapter = {};
  final Dio client;

  BookSources({Dio? client})
    : client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              headers: {'User-Agent': 'Mozilla/5.0'},
            ),
          );

  static BookSource source(String id) => sources.firstWhere(
    (s) => s.id == id,
    orElse: () => throw SourceException('旧版书源已失效，请在新书源中重新搜索这本书。'),
  );
  static String recordKey(String sourceId, int id) =>
      sourceId == 'legacy' ? '$id' : 'record:$sourceId:$id';
  static String contentKey(String sourceId, int bookId, int chapterId) =>
      sourceId == 'legacy'
      ? '$chapterId'
      : 'content:$sourceId:$bookId:$chapterId';
  static String cover(String? url) => url == null || url.isEmpty
      ? ''
      : (url.startsWith('http')
            ? url
            : url.startsWith('//')
            ? 'https:$url'
            : 'https://appbdimg.cdn.bcebos.com/BookFiles/BookImages/$url');

  Future<String> _get(String url, [Map<String, dynamic>? query]) async {
    try {
      final r = await client.get(
        url,
        queryParameters: query,
        options: Options(responseType: ResponseType.plain),
      );
      if (r.data is! String || (r.data as String).trim().isEmpty) {
        throw SourceException('书源返回了空响应，请稍后重试或切换书源。');
      }
      return r.data as String;
    } on DioException {
      throw SourceException('书源暂时无法连接，请重试或切换书源。');
    }
  }

  Future<Map<String, dynamic>> _json(
    String url, [
    Map<String, dynamic>? query,
  ]) async {
    final body = await _get(url, query);
    dynamic data;
    try {
      data = jsonDecode(body);
    } on FormatException {
      throw SourceException('书源返回的不是小说数据，可能已变更或需要验证。');
    }
    if (data is! Map<String, dynamic> ||
        (data.containsKey('code') && data['code'].toString() != '200')) {
      throw SourceException('书源暂时未提供有效数据。');
    }
    return data;
  }

  Future<Map<String, dynamic>> _bqg(
    String action,
    Map<String, dynamic> query,
  ) async {
    final chapter = action == 'chapter'
        ? (query['id'] as int, query['chapterid'] as int)
        : null;
    if (chapter != null) {
      // Matches the public request builder in bqg631.xyz/js/read.js (2026-11-10).
      final aes = cipher.Encrypter(
        cipher.AES(
          cipher.Key.fromUtf8('a3dc22cf70418a51'),
          mode: cipher.AESMode.cbc,
        ),
      );
      query = {
        'token': aes
            .encrypt(
              jsonEncode(query),
              iv: cipher.IV.fromUtf8('394c2c3202da6270'),
            )
            .base64,
      };
    }
    late SourceException last;
    final selectedHost = bqgHost;
    final hosts = selectedHost == null
        ? bqgHosts
        : [
            selectedHost,
            if (action != 'chapter')
              ...bqgHosts.where((h) => h != selectedHost),
          ];
    for (final host in hosts) {
      try {
        final result = await _json('https://$host/api/$action', query);
        if (chapter != null &&
            selectedHost == null &&
            result['txt'] is String &&
            (result['txt'] as String).trim().isNotEmpty) {
          if (host == bqgHosts.first) {
            _bqgFallbackByChapter.remove(chapter);
          } else {
            _bqgFallbackByChapter[chapter] = host;
          }
        }
        return result;
      } on SourceException catch (e) {
        last = e;
      }
    }
    throw last;
  }

  String? bqgFallbackFor(int bookId, int? chapterId) =>
      chapterId == null ? null : _bqgFallbackByChapter[(bookId, chapterId)];

  Future<Map<String, dynamic>> _kuwo(
    String path, [
    Map<String, dynamic>? query,
  ]) => _json('https://appi.kuwo.cn/novels/api/book$path', query);

  String _attribute(Element? element, String name) =>
      element == null ? '' : element.attributes[name] ?? '';

  int _id(dynamic value) {
    final id = int.tryParse('$value');
    if (id == null || id < 1) throw SourceException('书源的书籍或章节编号无效。');
    return id;
  }

  List _list(dynamic value) {
    if (value is! List) throw SourceException('书源的数据结构已变更，请切换书源。');
    return value;
  }

  Map<String, dynamic> _book(
    String sourceId,
    dynamic id,
    String? name, {
    String? author = '',
    String? image = '',
    String? intro = '',
    String? category = '',
    String? status = '',
    int lastId = 0,
    String? last = '',
    String? updated = '',
  }) {
    if (name == null || name.trim().isEmpty) throw SourceException('书源未返回书名。');
    final bookId = _id(id);
    return {
      'Id': bookId,
      'Name': name,
      'Author': author ?? '',
      'Img': image ?? '',
      'Desc': intro ?? '',
      'CId': 0,
      'CName': category ?? '',
      'BookStatus': status ?? '',
      'LastChapterId': lastId,
      'LastChapter': last ?? '',
      'FirstChapterId': 1,
      'LastTime': updated ?? '',
      'BookVote': null,
      'SameUserBooks': <dynamic>[],
      'sourceId': sourceId,
    };
  }

  Map<String, dynamic> _searchResult(Map<String, dynamic> book) => {
    ...book,
    'Id': '${book['Id']}',
    'LastChapterId': '${book['LastChapterId']}',
    'UpdateTime': book['LastTime'],
  };

  Future<List<Map<String, dynamic>>> search(
    String sourceId,
    String query,
    int page,
  ) async {
    final origin = source(sourceId).url;
    query = query.trim();
    if (query.isEmpty) return [];
    if (sourceId == 'bqg631') {
      // shortcut: this endpoint returns all matches, add pagination if its API changes.
      if (page > 1) return [];
      final data = await _bqg('search', {'q': query});
      return _list(data['data'])
          .map(
            (b) => _searchResult(
              _book(
                sourceId,
                b['id'],
                b['title'],
                author: b['author'],
                intro: b['intro'],
                image:
                    '${origin}bookimg/${_id(b['id']) ~/ 1000}/${b['id']}.jpg',
              ),
            ),
          )
          .toList();
    }
    if (sourceId == 'kuwo') {
      final data = await _kuwo('/search', {
        'keyword': query,
        'pi': page,
        'ps': 30,
      });
      return _list(data['data'])
          .map(
            (b) => _searchResult(
              _book(
                sourceId,
                b['book_id'],
                b['title'],
                author: b['author_name'],
                image: b['cover_url'],
                intro: b['intro'],
                category: b['category_name'],
              ),
            ),
          )
          .toList();
    }
    final doc = html.parse(
      await _get('${origin}search', {'keyword': query, 'page': page}),
    );
    final results = doc.querySelectorAll('.hot_4 li');
    if (results.isEmpty && doc.querySelector('main, .class') == null) {
      throw SourceException('书源搜索页面已变更或暂时不可访问。');
    }
    return results.map((e) {
      final href = _attribute(e.querySelector('a'), 'href');
      final id = RegExp(r'^/(\d+)/?$').firstMatch(href)?.group(1);
      return _searchResult(
        _book(
          sourceId,
          id,
          e.querySelector('.hot_name')?.text,
          author: e.querySelector('.author')?.text,
          intro: e.querySelector('.hot_des')?.text,
          image: Uri.parse(origin)
              .resolve(_attribute(e.querySelector('img'), 'src'))
              .toString(),
        ),
      );
    }).toList();
  }

  Future<Map<String, dynamic>> detail(String sourceId, int bookId) async {
    final origin = source(sourceId).url;
    if (sourceId == 'bqg631') {
      final b = await _bqg('book', {'id': '$bookId'});
      return _book(
        sourceId,
        b['id'],
        b['title'],
        author: b['author'],
        image: '${origin}bookimg/${bookId ~/ 1000}/$bookId.jpg',
        intro: b['intro'],
        category: b['sortname'],
        status: b['full'],
        lastId: int.tryParse('${b['lastchapterid']}') ?? 0,
        last: b['lastchapter'],
        updated: b['lastupdate'],
      );
    }
    if (sourceId == 'kuwo') {
      final b = (await _kuwo('/$bookId'))['data'];
      if (b is! Map) throw SourceException('书籍详情暂不可用。');
      return _book(
        sourceId,
        b['book_id'],
        b['title'],
        author: b['author_name'],
        image: b['cover_url'],
        intro: b['intro'],
        category: b['category_name'],
        status: '${b['status']}' == '50' ? '完结' : '连载',
        lastId: int.tryParse('${b['new_chapter_id']}') ?? 0,
        last: b['new_chapter_name'],
        updated: b['update_time'],
      );
    }
    final doc = html.parse(await _get('$origin$bookId'));
    String text(String selector) =>
        doc.querySelector(selector)?.text.trim() ?? '';
    String textAt(String selector, int index) {
      final elements = doc.querySelectorAll(selector);
      return elements.length > index ? elements[index].text.trim() : '';
    }

    return _book(
      sourceId,
      bookId,
      text('.info_title'),
      author: textAt('.info_ct > div', 1).replaceFirst('作者：', ''),
      image: Uri.parse(origin)
          .resolve(_attribute(doc.querySelector('.info_lt img'), 'src'))
          .toString(),
      intro: text('.des').replaceFirst('简介：', '').trim(),
      status: textAt('.info_ct > div', 0).replaceFirst('状态：', ''),
      updated: text('.info_ct time'),
      category: textAt('.bread a', 1),
      last: text('.ud a'),
    );
  }

  Future<List<Map<String, dynamic>>> chapters(
    String sourceId,
    int bookId,
  ) async {
    final origin = source(sourceId).url;
    List<Map<String, dynamic>> result;
    if (sourceId == 'bqg631') {
      final detail = await _bqg('book', {'id': '$bookId'});
      final toc = await _bqg('booklist', {
        'id': '${detail['dirid'] ?? bookId}',
      });
      final names = _list(toc['list']);
      result = List.generate(
        names.length,
        (i) => {'id': i + 1, 'name': '${names[i]}', 'hasContent': 1},
      );
    } else if (sourceId == 'kuwo') {
      final data = await _kuwo('/$bookId/chapters', {'paging': 0});
      result = _list(data['data'])
          .map(
            (c) => <String, dynamic>{
              'id': _id(c['chapter_id']),
              'name': '${c['chapter_title']}',
              'hasContent': 1,
            },
          )
          .toList();
    } else {
      final doc = html.parse(await _get('$origin$bookId'));
      final seen = <int>{};
      result = <Map<String, dynamic>>[];
      for (final a in doc.querySelectorAll('.list li a')) {
        final match = RegExp('^/$bookId/(\\d+)/?\$')
            .firstMatch(a.attributes['href'] ?? '');
        if (match == null) continue;
        final id = _id(match.group(1));
        if (seen.add(id)) {
          result.add({
            'id': id,
            'name': a.attributes['title'] ?? a.text,
            'hasContent': 1,
          });
        }
      }
    }
    if (result.isEmpty) throw SourceException('未能获取章节目录，请重试或切换书源。');
    return result;
  }

  Future<String> content(String sourceId, int bookId, int chapterId) async {
    final origin = source(sourceId).url;
    String? text;
    if (sourceId == 'bqg631') {
      final data = await _bqg('chapter', {
        'id': bookId,
        'chapterid': chapterId,
      });
      text = data['txt'] is String ? data['txt'] as String : null;
    } else if (sourceId == 'kuwo') {
      final data = (await _kuwo('/$bookId/chapters/$chapterId'))['data'];
      text = data is Map && data['content'] is String
          ? data['content'] as String
          : null;
    } else {
      final parts = <String>[], seen = <String>{};
      String? url = '$origin$bookId/$chapterId';
      while (url != null) {
        if (!seen.add(url) || seen.length > 30) {
          throw SourceException('章节分页异常，请到原站检查。');
        }
        final doc = html.parse(await _get(url));
        final article = doc.querySelector('.article');
        if (article == null) throw SourceException('正文页面已变更或暂时不可访问。');
        article
            .querySelectorAll('script, style, .readinline')
            .forEach((e) => e.remove());
        parts.add(
          html
                  .parseFragment(
                    article.innerHtml
                        .replaceAll(
                          RegExp(r'<br\s*/?>', caseSensitive: false),
                          '\n',
                        )
                        .replaceAll('</p>', '\n'),
                  )
                  .text ??
              '',
        );
        final buttons = doc.querySelectorAll('.text_btn a');
        final href = buttons.length > 2 ? _attribute(buttons[2], 'href') : null;
        final next = href == null ? null : Uri.parse(url).resolve(href);
        // Follow only another page of this chapter, never the next chapter.
        url =
            next != null &&
                next.host == Uri.parse(origin).host &&
                RegExp('^/$bookId/${chapterId}_\\d+/?\$').hasMatch(next.path)
            ? next.toString()
            : null;
      }
      text = parts.join('\n');
    }
    if (text == null || text.trim().isEmpty) {
      throw SourceException('该章节暂无可读正文，请重试或切换书源。');
    }
    return text.replaceAll('\r\n', '\n').trim();
  }
}
