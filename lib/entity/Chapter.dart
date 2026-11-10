class Chapter {
  int hasContent;
  int id;
  String name;

  Chapter(this.hasContent, this.id, this.name);

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        json['hasContent'] as int? ?? 0,
        json['id'] as int? ?? 0,
        json['name'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'hasContent': hasContent,
        'id': id,
        'name': name,
      };
}
