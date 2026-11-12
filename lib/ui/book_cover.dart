import 'package:flutter/material.dart';

import '../service/book_sources.dart';

class BookCover extends StatelessWidget {
  final String title, url;
  final double? width, height;
  const BookCover({
    super.key,
    required this.title,
    this.url = '',
    this.width,
    this.height,
  });
  @override
  Widget build(BuildContext context) {
    final compact = width != null && width! < 72;
    final fallback = ColoredBox(
      color: Color.lerp(
        const Color(0xFF334F43),
        const Color(0xFF8B6D4E),
        (title.runes.fold(0, (a, b) => a + b) % 5) / 4,
      )!,
      child: Padding(
        padding: EdgeInsets.all(compact ? 8 : 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFFFF9ED),
                  fontSize: 17,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (!compact) ...[
              Container(width: 24, height: 1, color: const Color(0xFFDDD3BB)),
              const SizedBox(height: 10),
              const Text(
                '清阅',
                style: TextStyle(color: Color(0xFFE6E0D0), fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
    return Semantics(
      label: '$title，封面',
      image: true,
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: url.isEmpty
              ? fallback
              : Image.network(
                  BookSources.cover(url),
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stackTrace) => fallback,
                ),
        ),
      ),
    );
  }
}
