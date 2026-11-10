import 'package:flutter/material.dart';

class CacheProgressButton extends StatelessWidget {
  final bool active;
  final int cached, total;
  final String tooltip;
  final VoidCallback? onPressed;
  const CacheProgressButton({
    super.key,
    required this.active,
    required this.cached,
    required this.total,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final progress = total > 0 ? (cached / total).clamp(0.0, 1.0) : null;
    final complete = progress == 1;
    final percent = ((progress ?? 0) * 100).floor();
    final color = Theme.of(context).colorScheme.primary;
    return Semantics(
      value: total > 0
          ? '$percent%，已缓存 $cached / $total 章'
          : active
          ? '正在获取目录'
          : null,
      child: IconButton(
        tooltip: complete ? '缓存完成' : tooltip,
        onPressed: complete ? null : onPressed,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        visualDensity: VisualDensity.standard,
        padding: const EdgeInsets.all(6),
        icon: ExcludeSemantics(
          child: SizedBox.square(
            dimension: 36,
            child: complete
                ? Icon(
                    Icons.check_circle_outline_rounded,
                    color: color,
                    size: 27,
                  )
                : active || total > 0
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 2.5,
                          color: color,
                          backgroundColor: color.withValues(alpha: .16),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            progress == null ? '…' : '$percent%',
                            style: TextStyle(
                              color: color,
                              fontSize: 11,
                              height: 1,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : const Icon(Icons.download_outlined, size: 20),
          ),
        ),
      ),
    );
  }
}
