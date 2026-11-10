import 'Chapter.dart';

class BookTag {
  List<int> pageOffsets = [];
  String? content;
  String name = '';
  int cur = 0;
  int index = 0;
  List<Chapter> chapters;

  BookTag(this.cur, this.index, this.chapters, this.name);

  String stringAtPageIndex(int index) => (content ?? '')
      .substring(index == 0 ? 0 : pageOffsets[index - 1], pageOffsets[index]);

  int get pageCount => pageOffsets.length;

  factory BookTag.fromJson(Map<String, dynamic> json) => BookTag(
        json['cur'] as int? ?? 0,
        json['index'] as int? ?? 0,
        (json['chapters'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(Chapter.fromJson)
            .toList(),
        json['name'] as String? ?? '',
      )
        ..pageOffsets =
            (json['pageOffsets'] as List? ?? []).cast<int>().toList()
        ..content = json['content'] as String?;

  Map<String, dynamic> toJson() => {
        'pageOffsets': pageOffsets,
        'content': content,
        'name': name,
        'cur': cur,
        'index': index,
        'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
      };
}
