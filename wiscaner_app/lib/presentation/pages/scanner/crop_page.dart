import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../../core/services/document_scanner_service.dart';
import '../../widgets/scanner/document_overlay.dart';
import 'result_page.dart';

/// 문서 영역 조정 페이지
/// 흐름: 자동 감지 → 원근보정 결과 미리보기 → 부족하면 영역 재조정 → 다시 보정
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

  // 보정 결과 미리보기
  String? _previewPath;       // 원근보정된 이미지 경로
  bool _showPreview = false;  // true=보정 결과 보기, false=원본+꼭짓점 조정

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
    _detectAndPreview();
  }

  /// 자동 감지 → 원근보정 → 미리보기 전환
  Future<void> _detectAndPreview() async {
    setState(() {
      _isDetecting = true;
      _showPreview = false;
      _previewPath = null;
    });

    // 이미지 크기 읽기
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

    // 코너 감지
    final corners = await _scanner.detectDocumentCorners(_currentImagePath);

    if (!mounted) return;

    setState(() {
      _corners = List.from(corners);
      _isDetecting = false;
    });

    // 기본값(전체 영역)이 아니면 자동으로 원근보정 미리보기
    final isDefault = _isDefaultCorners(corners);
    if (!isDefault) {
      await _applyPreview();
    }
  }

  bool _isDefaultCorners(List<Offset> corners) {
    if (corners.length != 4) return true;
    final defaults = [
      const Offset(0.05, 0.05), const Offset(0.95, 0.05),
      const Offset(0.95, 0.95), const Offset(0.05, 0.95),
    ];
    double totalDist = 0;
    for (int i = 0; i < 4; i++) {
      totalDist += (corners[i] - defaults[i]).distance;
    }
    return totalDist < 0.08;
  }

  /// 현재 꼭짓점으로 원근보정 → 미리보기
  Future<void> _applyPreview() async {
    setState(() => _isProcessing = true);
    try {
      final croppedPath = await _scanner.applyPerspectiveTransform(
        imagePath: _currentImagePath,
        corners: _corners,
      );
      if (croppedPath != null && mounted) {
        setState(() {
          _previewPath = croppedPath;
          _showPreview = true;
          _isProcessing = false;
        });
      } else {
        if (mounted) {
          setState(() => _isProcessing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('원근 보정 실패')),
          );
        }
      }
    } catch (e) {
      debugPrint('미리보기 보정 실패: $e');
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  /// 미리보기 → 재조정 모드 전환
  void _switchToAdjust() {
    setState(() {
      _showPreview = false;
    });
  }

  /// 전체 영역 선택
  void _selectFullArea() {
    setState(() {
      _corners = const [
        Offset(0.0, 0.0), Offset(1.0, 0.0),
        Offset(1.0, 1.0), Offset(0.0, 1.0),
      ];
      _showPreview = false;
      _previewPath = null;
    });
  }

  /// 자동 재감지
  void _retryDetect() => _detectAndPreview();

  void _updateCorner(int index, Offset position) {
    setState(() {
      _corners[index] = Offset(
        position.dx.clamp(0.0, 1.0),
        position.dy.clamp(0.0, 1.0),
      );
      // 꼭짓점 변경 시 미리보기 무효화
      _previewPath = null;
      _showPreview = false;
    });
  }

  /// 확인 → 결과 페이지로 이동
  Future<void> _confirmAndNext() async {
    // 미리보기가 있으면 그대로 사용, 없으면 보정 수행
    String? finalPath = _previewPath;

    if (finalPath == null) {
      setState(() => _isProcessing = true);
      try {
        finalPath = await _scanner.applyPerspectiveTransform(
          imagePath: _currentImagePath,
          corners: _corners,
        );
      } catch (e) {
        debugPrint('크롭 처리 실패: $e');
      }
      if (mounted) setState(() => _isProcessing = false);
    }

    if (finalPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('원근 보정 실패')),
        );
      }
      return;
    }

    if (_isBatchMode) {
      _croppedImages.add(finalPath);
      if (_currentBatchIndex < widget.batchImages!.length - 1) {
        setState(() {
          _currentBatchIndex++;
          _previewPath = null;
          _showPreview = false;
        });
        _detectAndPreview();
        return;
      }
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ResultPage(imagePaths: _croppedImages),
          ),
        );
      }
    } else {
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ResultPage(imagePaths: [finalPath!]),
          ),
        );
      }
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
              : _showPreview ? '스캔 결과' : '영역 조정',
        ),
        actions: [
          if (!_showPreview) ...[
            IconButton(icon: const Icon(Icons.crop_free), tooltip: '전체 영역', onPressed: _selectFullArea),
            IconButton(icon: const Icon(Icons.auto_fix_high), tooltip: '자동 감지', onPressed: _retryDetect),
          ],
        ],
        bottom: _isBatchMode
            ? PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: LinearProgressIndicator(
                  value: (_currentBatchIndex + 1) / widget.batchImages!.length,
                  backgroundColor: Colors.grey[800],
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                ),
              )
            : null,
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
                        Text('문서를 감지하고 있습니다...', style: TextStyle(color: Colors.white70)),
                      ],
                    ),
                  )
                : _showPreview && _previewPath != null
                    ? _buildPreviewView()
                    : _buildCropView(),
          ),
          if (!_isDetecting)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _showPreview
                    ? '스캔 결과를 확인하세요. 부족하면 영역을 재조정할 수 있습니다.'
                    : '모서리의 파란 점을 드래그하여 문서 영역을 조정하세요',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  /// 보정 결과 미리보기
  Widget _buildPreviewView() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Image.file(
          File(_previewPath!),
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  /// 원본 + 꼭짓점 조정 뷰
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
        child: _showPreview ? _buildPreviewButtons() : _buildAdjustButtons(),
      ),
    );
  }

  /// 미리보기 모드 버튼: 재조정 / 확인
  Widget _buildPreviewButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _switchToAdjust,
            icon: const Icon(Icons.tune, size: 18),
            label: const Text('영역 재조정'),
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
            onPressed: _isProcessing ? null : _confirmAndNext,
            icon: const Icon(Icons.check),
            label: Text(_isBatchMode && _currentBatchIndex < widget.batchImages!.length - 1
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
    );
  }

  /// 영역 조정 모드 버튼: 뒤로 / 적용 미리보기
  Widget _buildAdjustButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () {
              if (_previewPath != null) {
                // 이전 미리보기가 있으면 미리보기로 돌아가기
                setState(() => _showPreview = true);
              } else {
                Navigator.of(context).pop();
              }
            },
            icon: const Icon(Icons.arrow_back),
            label: Text(_previewPath != null ? '결과 보기' : '뒤로'),
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
            onPressed: _isProcessing ? null : _applyPreview,
            icon: _isProcessing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.visibility),
            label: Text(_isProcessing ? '처리 중...' : '스캔 적용'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ],
    );
  }
}
