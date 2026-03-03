import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../../core/services/document_scanner_service.dart';
import '../../widgets/scanner/document_overlay.dart';
import 'result_page.dart';

/// 문서 영역 조정 페이지
class CropPage extends StatefulWidget {
  final String imagePath;
  final List<String>? batchImages;

  const CropPage({
    super.key,
    required this.imagePath,
    this.batchImages,
  });

  @override
  State<CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<CropPage> {
  final _scanner = DocumentScannerService.instance;

  List<Offset> _corners = [];
  bool _isDetecting = true;
  bool _isProcessing = false;

  Size? _imageSize;

  // 배치 모드
  int _currentBatchIndex = 0;
  final List<String> _croppedImages = [];

  String get _currentImagePath {
    if (widget.batchImages != null &&
        _currentBatchIndex < widget.batchImages!.length) {
      return widget.batchImages![_currentBatchIndex];
    }
    return widget.imagePath;
  }

  bool get _isBatchMode =>
      widget.batchImages != null && widget.batchImages!.length > 1;

  @override
  void initState() {
    super.initState();
    _detectCorners();
  }

  Future<void> _detectCorners() async {
    setState(() => _isDetecting = true);

    try {
      final file = File(_currentImagePath);
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _imageSize = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
    } catch (_) {
      _imageSize = null;
    }

    final corners = await _scanner.detectDocumentCorners(_currentImagePath);

    if (mounted) {
      setState(() {
        _corners = List.from(corners);
        _isDetecting = false;
      });
    }
  }

  void _selectFullArea() {
    setState(() {
      _corners = const [
        Offset(0.0, 0.0), Offset(1.0, 0.0),
        Offset(1.0, 1.0), Offset(0.0, 1.0),
      ];
    });
  }

  void _retryDetect() => _detectCorners();

  void _updateCorner(int index, Offset position) {
    setState(() {
      _corners[index] = Offset(
        position.dx.clamp(0.0, 1.0),
        position.dy.clamp(0.0, 1.0),
      );
    });
  }

  Future<void> _applyAndNext() async {
    setState(() => _isProcessing = true);

    try {
      final croppedPath = await _scanner.applyPerspectiveTransform(
        imagePath: _currentImagePath,
        corners: _corners,
      );

      if (croppedPath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('원근 보정 실패')),
          );
        }
        return;
      }

      if (_isBatchMode) {
        _croppedImages.add(croppedPath);

        if (_currentBatchIndex < widget.batchImages!.length - 1) {
          setState(() {
            _currentBatchIndex++;
            _isProcessing = false;
          });
          _detectCorners();
          return;
        }

        // 배치 모드 완료 → 결과 페이지로
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => ResultPage(imagePaths: _croppedImages),
            ),
          );
        }
      } else {
        // 단일 이미지 → 결과 페이지로
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ResultPage(imagePaths: [croppedPath]),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('크롭 처리 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('처리 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _isBatchMode
              ? '영역 조정 (${_currentBatchIndex + 1}/${widget.batchImages!.length})'
              : '영역 조정',
        ),
        actions: [
          IconButton(icon: const Icon(Icons.crop_free), tooltip: '전체 영역', onPressed: _selectFullArea),
          IconButton(icon: const Icon(Icons.auto_fix_high), tooltip: '자동 감지', onPressed: _retryDetect),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isDetecting
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 16),
                        Text('문서 영역을 감지하고 있습니다...', style: TextStyle(color: Colors.white70)),
                      ],
                    ),
                  )
                : _buildCropView(),
          ),
          if (!_isDetecting)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '모서리의 파란 점을 드래그하여 문서 영역을 조정하세요',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildCropView() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final containerW = constraints.maxWidth;
          final containerH = constraints.maxHeight;

          double imgDisplayW = containerW;
          double imgDisplayH = containerH;
          double offsetX = 0;
          double offsetY = 0;

          if (_imageSize != null) {
            final imgAspect = _imageSize!.width / _imageSize!.height;
            final containerAspect = containerW / containerH;

            if (imgAspect > containerAspect) {
              imgDisplayW = containerW;
              imgDisplayH = containerW / imgAspect;
            } else {
              imgDisplayH = containerH;
              imgDisplayW = containerH * imgAspect;
            }
            offsetX = (containerW - imgDisplayW) / 2;
            offsetY = (containerH - imgDisplayH) / 2;
          }

          return Stack(
            children: [
              Center(
                child: Image.file(File(_currentImagePath), fit: BoxFit.contain),
              ),
              if (_corners.length == 4)
                Positioned(
                  left: offsetX, top: offsetY,
                  width: imgDisplayW, height: imgDisplayH,
                  child: DocumentOverlay(
                    corners: _corners,
                    onCornerDragged: _updateCorner,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      color: Colors.black,
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('뒤로'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: _isProcessing ? null : _applyAndNext,
                icon: _isProcessing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(_isProcessing
                    ? '처리 중...'
                    : _isBatchMode && _currentBatchIndex < widget.batchImages!.length - 1
                        ? '다음 (${_currentBatchIndex + 2}/${widget.batchImages!.length})'
                        : '확인'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
