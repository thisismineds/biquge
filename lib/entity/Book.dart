class Book {
  String sourceId = 'legacy';
  int ChapterId;
  String ChapterName;
  int NewChapterCount;
  int Id;
  String Name;
  String Author;
  String Img;
  int LastChapterId;
  String LastChapter;
  String UpdateTime;

  Book(
      this.ChapterId,
      this.ChapterName,
      this.NewChapterCount,
      this.Id,
      this.Name,
      this.Author,
      this.Img,
      this.LastChapterId,
      this.LastChapter,
      this.UpdateTime);

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        json['ChapterId'] as int? ?? 0,
        json['ChapterName'] as String? ?? '',
        json['NewChapterCount'] as int? ?? 0,
        json['Id'] as int? ?? 0,
        json['Name'] as String? ?? '',
        json['Author'] as String? ?? '',
        json['Img'] as String? ?? '',
        json['LastChapterId'] as int? ?? 0,
        json['LastChapter'] as String? ?? '',
        json['UpdateTime'] as String? ?? '',
      )..sourceId = json['sourceId'] as String? ?? 'legacy';

  Map<String, dynamic> toJson() => {
        'ChapterId': ChapterId,
        'ChapterName': ChapterName,
        'NewChapterCount': NewChapterCount,
        'Id': Id,
        'Name': Name,
        'Author': Author,
        'Img': Img,
        'LastChapterId': LastChapterId,
        'LastChapter': LastChapter,
        'UpdateTime': UpdateTime,
        'sourceId': sourceId,
      };
}
