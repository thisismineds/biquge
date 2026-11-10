import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/service/book_sources.dart';
import 'package:qingyue/entity/Book.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/entity/BookTag.dart';
import 'package:qingyue/entity/Chapter.dart';

class FixtureAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) respond;
  FixtureAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) => respond(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object value) => ResponseBody.fromString(
  jsonEncode(value),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

void main() {
  test('old reading progress retains cached text and page boundaries', () {
    final old = <String, dynamic>{
      'cur': 1,
      'index': 2,
      'name': '第二章',
      'chapters': [
        {'hasContent': 1, 'id': 96825218742211052, 'name': '第二章'},
      ],
      'pageOffsets': [2, 5],
      'content': '甲乙丙丁戊',
    };
    final tag = BookTag.fromJson(jsonDecode(jsonEncode(old)));
    expect(tag.chapters.single.id, 96825218742211052);
    expect(tag.pageOffsets, [2, 5]);
    expect(tag.stringAtPageIndex(1), '丙丁戊');
    expect(jsonDecode(jsonEncode(tag)), old);
    final missing = BookTag.fromJson({});
    expect(missing.cur, 0);
    expect(missing.index, 0);
    expect(missing.chapters, isEmpty);
    expect(missing.pageOffsets, isEmpty);
    expect(missing.content, isNull);
    expect(BookTag(0, 0, [Chapter(1, 1, '第一章')], '').pageCount, 0);
  });

  test(
    'partial legacy book details have safe defaults and preserve native IDs',
    () {
      final info = BookInfo.fromJson({'Id': 22543868000604102, 'Name': '书名'});
      expect(info.Id, 22543868000604102);
      expect(info.sourceId, 'legacy');
      expect(info.Author, '');
      expect(info.Img, '');
      expect(info.Desc, '');
      expect(info.LastChapterId, 0);
      expect(info.SameUserBooks, isEmpty);
      expect(BookInfo.fromJson(jsonDecode(jsonEncode(info))).Id, info.Id);
      expect(BookInfo.id(1, '书名').FirstChapterId, 0);
      expect(BookInfo.name(3, '分类').Id, 0);
      final vote = {'BookId': info.Id, 'Score': 8.5, 'VoterCount': 3};
      final withVote = BookInfo.fromJson({...info.toJson(), 'BookVote': vote});
      expect(jsonDecode(jsonEncode(withVote))['BookVote'], vote);
    },
  );

  test(
    'saved books retain their source while old shelf records stay legacy',
    () {
      final original = Book(0, '', 0, 1, '书名', '作者', '', 1, '第一章', '')
        ..sourceId = 'bqg631';
      expect(
        Book.fromJson(jsonDecode(jsonEncode(original))).sourceId,
        'bqg631',
      );
      final old = original.toJson()..remove('sourceId');
      expect(Book.fromJson(old).sourceId, 'legacy');
      final info = BookInfo.id(1, '书名')..sourceId = 'kuwo';
      expect(BookInfo.fromJson(jsonDecode(jsonEncode(info))).sourceId, 'kuwo');
    },
  );
  test('book and chapter cache keys distinguish sources and books', () {
    expect(
      BookSources.recordKey('bqg631', 1),
      isNot(BookSources.recordKey('kuwo', 1)),
    );
    expect(
      BookSources.contentKey('bqg631', 1, 1),
      isNot(BookSources.contentKey('bqg631', 2, 1)),
    );
    expect(BookSources.recordKey('legacy', 42), '42');
    expect(BookSources.contentKey('legacy', 42, 7), '7');
  });

  test(
    'bqg631 reads the website JSON API and encrypts chapter parameters',
    () async {
      final client = Dio();
      client.httpClientAdapter = FixtureAdapter((o) async {
        if (o.path.endsWith('/search')) {
          expect(o.queryParameters['q'], '三国 & 风云');
          return jsonBody({
            'data': [
              {'id': '582', 'title': '神话版三国', 'author': '坟土荒草', 'intro': '简介'},
            ],
          });
        }
        if (o.path.endsWith('/booklist')) {
          expect(o.queryParameters['id'], '582');
          return jsonBody({
            'list': ['第一章', '第二章'],
          });
        }
        if (o.path.endsWith('/book')) return jsonBody({'dirid': '582'});
        expect(o.path, endsWith('/chapter'));
        // Captured independently from the website's public request builder.
        expect(
          o.queryParameters['token'],
          'i1N8DBebwvZFUlsz7jMDPbqpyWm5+6DaZaeN/leR8nE=',
        );
        return jsonBody({'txt': '第一段\n第二段', 'chapterid': '1'});
      });
      final sources = BookSources(client: client);
      final results = await sources.search('bqg631', '三国 & 风云', 1);
      expect(results.single['Id'], '582');
      expect(results.single['sourceId'], 'bqg631');
      expect((await sources.chapters('bqg631', 582)).last['id'], 2);
      expect(await sources.content('bqg631', 1, 1), '第一段\n第二段');
      expect(await sources.search('bqg631', '三国', 2), isEmpty);
    },
  );

  test('kuwo preserves long native IDs and rejects business errors', () async {
    final client = Dio();
    client.httpClientAdapter = FixtureAdapter(
      (o) async => jsonBody({
        'code': 200,
        'data': [
          {
            'book_id': '22543868000604102',
            'chapter_id': '96825218742211052',
            'chapter_title': '第一章',
          },
        ],
      }),
    );
    final chapters = await BookSources(client: client)
        .chapters('kuwo', 22543868000604102);
    expect(chapters.single['id'].toString(), '96825218742211052');
    client.httpClientAdapter = FixtureAdapter(
      (o) async => jsonBody({'code': 403, 'message': 'not available'}),
    );
    expect(
      BookSources(client: client).search('kuwo', '书', 1),
      throwsA(isA<SourceException>()),
    );
  });

  test(
    'HTML source extracts nested titles and resolves chapter links',
    () async {
      final client = Dio();
      client.httpClientAdapter = FixtureAdapter(
        (o) async => ResponseBody.fromString(
          o.path.contains('/search')
              ? '<ul class="hot_4"><li><a href="/49943"><img src="/a.jpg"><div class="hot_name">神话版<mark>三国</mark></div><div class="author">作者</div><p class="hot_des">简介</p></a></li></ul>'
              : '<ul class="list"><li><a href="/49943/1" title="第一章">第一章</a></li></ul>',
          200,
        ),
      );
      final sources = BookSources(client: client);
      final search = await sources.search('biquges123', '三国', 1);
      expect(search.single['Name'], '神话版三国');
      expect(search.single['Img'], 'https://www.biquges123.com/a.jpg');
      expect((await sources.chapters('biquges123', 49943)).single['id'], 1);
    },
  );

  test(
    'empty or redirected responses never become an empty book or chapter',
    () async {
      final client = Dio();
      client.httpClientAdapter = FixtureAdapter(
        (o) async => ResponseBody.fromString(
          '<html><title>Redirecting</title></html>',
          200,
        ),
      );
      final sources = BookSources(client: client);
      expect(sources.search('kuwo', '书', 1), throwsA(isA<SourceException>()));
      expect(
        sources.content('biquges123', 1, 1),
        throwsA(isA<SourceException>()),
      );
      expect(sources.detail('legacy', 1), throwsA(isA<SourceException>()));
    },
  );

  test(
    'HTML details use author and introduction text, not their labels',
    () async {
      final client = Dio();
      client.httpClientAdapter = FixtureAdapter(
        (o) async => ResponseBody.fromString(
          '<h1 class="info_title">书名</h1><div class="info_ct"><div>状态：连载</div><div>作者：作者名</div><div>最后更新：<time>2026-11-05</time></div></div><div class="des"><span>简介：</span>真正的简介</div>',
          200,
        ),
      );
      final book = await BookSources(client: client).detail('biquges123', 1);
      expect(book['Author'], '作者名');
      expect(book['Desc'], '真正的简介');
      expect(book['LastTime'], '2026-11-05');
    },
  );

  test('chapter pagination joins only the current chapter and preserves paragraphs', () async {
    final paths = <String>[];
    final client = Dio();
    client.httpClientAdapter = FixtureAdapter((o) async {
      paths.add(o.uri.path);
      return ResponseBody.fromString(
        o.uri.path.endsWith('_2')
            ? '<div class="article"><p>第三段</p></div><div class="text_btn"><a></a><a></a><a href="/1/2">下一章</a></div>'
            : '<div class="article"><p>第一段</p><p>第二段</p></div><div class="text_btn"><a></a><a></a><a href="/1/1_2">下一页</a></div>',
        200,
      );
    });
    expect(
      await BookSources(client: client).content('biquges123', 1, 1),
      '第一段\n第二段\n\n第三段',
    );
    expect(paths, ['/1/1', '/1/1_2']);
  });

  test('bqg631 falls back only between the website API mirrors', () async {
    final hosts = <String>[];
    final client = Dio();
    client.httpClientAdapter = FixtureAdapter((o) async {
      hosts.add(o.uri.host);
      if (hosts.length == 1) return ResponseBody.fromString('', 503);
      return jsonBody({'data': []});
    });
    expect(await BookSources(client: client).search('bqg631', '书', 1), isEmpty);
    expect(hosts, ['apibi.cc', 'apiqu.cc']);
  });
}
