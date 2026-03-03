import 'package:flutter/material.dart';

/// 문서 영역을 표시하는 오버레이 위젯
/// 4꼭짓점을 연결하는 반투명 영역과 드래그 핸들을 표시
class DocumentOverlay extends StatelessWidget {
  /// 정규화된 좌표 (0~1), 순서: 좌상→우상→우하→좌하
  final List<Offset> corners;

  /// 꼭짓점 드래그 콜백 (index, newPosition)
  final void Function(int index, Offset normalizedPosition)? onCornerDragged;

  /// 드래그 종료 콜백
  final VoidCallback? onDragEnd;

  /// 오버레이 색상
  final Color overlayColor;

  /// 경계선 색상
  final Color borderColor;

  /// 핸들 크기
  final double handleSize;

  const DocumentOverlay({
    super.key,
    required this.corners,
    this.onCornerDragged,
    this.onDragEnd,
    this.overlayColor = const Color(0x40000000),
    this.borderColor = const Color(0xFF2196F3),
    this.handleSize = 28,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;

        final pixelCorners =
            corners.map((c) => Offset(c.dx * w, c.dy * h)).toList();

        return Stack(
          children: [
            CustomPaint(
              size: Size(w, h),
              painter: _OverlayPainter(
                corners: pixelCorners,
                overlayColor: overlayColor,
                borderColor: borderColor,
              ),
            ),
            for (int i = 0; i < 4; i++)
              Positioned(
                left: pixelCorners[i].dx - handleSize / 2,
                top: pixelCorners[i].dy - handleSize / 2,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    if (onCornerDragged == null) return;
                    final newX =
                        (pixelCorners[i].dx + details.delta.dx).clamp(0.0, w);
                    final newY =
                        (pixelCorners[i].dy + details.delta.dy).clamp(0.0, h);
                    onCornerDragged!(i, Offset(newX / w, newY / h));
                  },
                  onPanEnd: (_) => onDragEnd?.call(),
                  child: _CornerHandle(
                    size: handleSize,
                    color: borderColor,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CornerHandle extends StatelessWidget {
  final double size;
  final Color color;

  const _CornerHandle({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: color, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final List<Offset> corners;
  final Color overlayColor;
  final Color borderColor;

  _OverlayPainter({
    required this.corners,
    required this.overlayColor,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;

    final docPath = Path()
      ..moveTo(corners[0].dx, corners[0].dy)
      ..lineTo(corners[1].dx, corners[1].dy)
      ..lineTo(corners[2].dx, corners[2].dy)
      ..lineTo(corners[3].dx, corners[3].dy)
      ..close();

    final fullPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final overlayPath =
        Path.combine(PathOperation.difference, fullPath, docPath);

    canvas.drawPath(
      overlayPath,
      Paint()..color = overlayColor,
    );

    canvas.drawPath(
      docPath,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    final midTop = Offset(
      (corners[0].dx + corners[1].dx) / 2,
      (corners[0].dy + corners[1].dy) / 2,
    );
    final midBottom = Offset(
      (corners[3].dx + corners[2].dx) / 2,
      (corners[3].dy + corners[2].dy) / 2,
    );
    final midLeft = Offset(
      (corners[0].dx + corners[3].dx) / 2,
      (corners[0].dy + corners[3].dy) / 2,
    );
    final midRight = Offset(
      (corners[1].dx + corners[2].dx) / 2,
      (corners[1].dy + corners[2].dy) / 2,
    );

    final guidePaint = Paint()
      ..color = borderColor.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawLine(midTop, midBottom, guidePaint);
    canvas.drawLine(midLeft, midRight, guidePaint);
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) {
    return corners != oldDelegate.corners;
  }
}
