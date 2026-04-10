import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// 서명 입력 위젯 (CustomPainter 기반)
class SignaturePad extends StatefulWidget {
  const SignaturePad({super.key});

  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<SignaturePad> {
  final List<List<Offset>> _strokes = [];
  List<Offset> _currentStroke = [];

  bool get _hasSignature => _strokes.isNotEmpty;

  void _clear() {
    setState(() {
      _strokes.clear();
      _currentStroke.clear();
    });
  }

  Future<void> _confirm() async {
    if (!_hasSignature) return;

    // 서명 영역 계산
    double minX = double.infinity, minY = double.infinity;
    double maxX = 0, maxY = 0;
    for (final stroke in _strokes) {
      for (final pt in stroke) {
        if (pt.dx < minX) minX = pt.dx;
        if (pt.dy < minY) minY = pt.dy;
        if (pt.dx > maxX) maxX = pt.dx;
        if (pt.dy > maxY) maxY = pt.dy;
      }
    }

    // 여백 추가
    const padding = 20.0;
    minX = (minX - padding).clamp(0, double.infinity);
    minY = (minY - padding).clamp(0, double.infinity);
    maxX += padding;
    maxY += padding;

    final width = (maxX - minX).toInt().clamp(1, 2000);
    final height = (maxY - minY).toInt().clamp(1, 2000);

    // PNG로 렌더링
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (final stroke in _strokes) {
      if (stroke.length < 2) continue;
      final path = Path()
        ..moveTo(stroke.first.dx - minX, stroke.first.dy - minY);
      for (int i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx - minX, stroke[i].dy - minY);
      }
      canvas.drawPath(path, paint);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    if (byteData != null && mounted) {
      Navigator.pop(context, byteData.buffer.asUint8List());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 헤더
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.draw, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('서명 입력',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              TextButton(
                onPressed: _clear,
                child: const Text('지우기'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // 서명 영역
        Expanded(
          child: GestureDetector(
            onPanStart: (details) {
              setState(() {
                _currentStroke = [details.localPosition];
              });
            },
            onPanUpdate: (details) {
              setState(() {
                _currentStroke.add(details.localPosition);
              });
            },
            onPanEnd: (_) {
              setState(() {
                _strokes.add(List.from(_currentStroke));
                _currentStroke = [];
              });
            },
            child: Container(
              width: double.infinity,
              color: Colors.white,
              child: CustomPaint(
                painter: _SignaturePainter(
                  strokes: _strokes,
                  currentStroke: _currentStroke,
                ),
              ),
            ),
          ),
        ),

        // 확인 버튼
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _hasSignature ? _confirm : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('서명 적용', style: TextStyle(fontSize: 16)),
            ),
          ),
        ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final List<Offset> currentStroke;

  _SignaturePainter({required this.strokes, required this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // 가이드 텍스트
    if (strokes.isEmpty && currentStroke.isEmpty) {
      final textPainter = TextPainter(
        text: const TextSpan(
          text: '여기에 서명하세요',
          style: TextStyle(color: Colors.grey, fontSize: 18),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset((size.width - textPainter.width) / 2, (size.height - textPainter.height) / 2),
      );

      // 가이드 라인
      final linePaint = Paint()
        ..color = Colors.grey[300]!
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(size.width * 0.15, size.height * 0.7),
        Offset(size.width * 0.85, size.height * 0.7),
        linePaint,
      );
    }

    // 기존 스트로크
    for (final stroke in strokes) {
      _drawStroke(canvas, stroke, paint);
    }

    // 현재 스트로크
    if (currentStroke.isNotEmpty) {
      _drawStroke(canvas, currentStroke, paint);
    }
  }

  void _drawStroke(Canvas canvas, List<Offset> stroke, Paint paint) {
    if (stroke.length < 2) return;
    final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
    for (int i = 1; i < stroke.length; i++) {
      path.lineTo(stroke[i].dx, stroke[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SignaturePainter oldDelegate) => true;
}
