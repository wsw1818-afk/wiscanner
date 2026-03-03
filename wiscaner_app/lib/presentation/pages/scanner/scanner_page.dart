import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'crop_page.dart';
import '../../../core/services/document_scanner_service.dart';
import '../../../core/services/doc_aligner_service.dart';

/// 카메라 미리보기 + 촬영 / 파일 선택 페이지
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraInitialized = false;
  bool _isCameraAvailable = false;
  bool _isCapturing = false;

  // 연속 촬영 모드
  bool _batchMode = false;
  final List<String> _batchImages = [];

  // 자동 스캔 모드
  bool _autoMode = true;
  int _lastDetectionMs = 0;
  List<Offset>? _detectedCorners;
  Map<String, dynamic>? _qualityInfo;
  DocumentSize? _documentSize;
  int _stableFrameCount = 0;
  int _autoCountdown = 0;
  Timer? _countdownTimer;
  static const int _requiredStableFrames = 5;

  // 경계선 안정화
  List<Offset>? _smoothedCorners;
  static const double _smoothingFactor = 0.20;
  static const int _bufferSize = 3;
  final List<List<Offset>> _cornerBuffer = [];
  int _noDetectionCount = 0;
  bool _isDetecting = false;

  // 촬영 피드백
  bool _showCapturedFeedback = false;
  bool _showCaptureFlash = false;

  // 음성 명령 촬영
  bool _voiceMode = false;
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechInitialized = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    try {
      _speechInitialized = await _speech.initialize(
        onError: (error) => debugPrint('음성 인식 에러: $error'),
        onStatus: (status) => debugPrint('음성 인식 상태: $status'),
      );
      if (_speechInitialized && mounted) setState(() {});
    } catch (e) {
      debugPrint('음성 인식 초기화 실패: $e');
    }
  }

  void _startListening() {
    if (!_speechInitialized) return;
    _speech.listen(
      onResult: (result) {
        final words = result.recognizedWords.toLowerCase();
        if (words.contains('촬영') || words.contains('찍어') ||
            words.contains('캡처') || words.contains('스캔')) {
          _captureImage();
          _speech.stop();
        }
      },
      localeId: 'ko_KR',
    );
  }

  void _stopListening() => _speech.stop();

  void _startAutoDetection() {
    if (!_autoMode) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (_cameraController!.value.isStreamingImages) return;
    try {
      _cameraController!.startImageStream(_onCameraFrame);
    } catch (e) {
      debugPrint('[스캐너] 이미지 스트림 시작 실패: $e');
    }
  }

  void _stopAutoDetection() {
    try {
      if (_cameraController != null && _cameraController!.value.isStreamingImages) {
        _cameraController!.stopImageStream();
      }
    } catch (e) {
      debugPrint('이미지 스트림 정지 실패: $e');
    }
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  bool _permissionDenied = false;

  Future<void> _initCamera() async {
    try {
      // 권한 확인 및 요청
      final cameraStatus = await Permission.camera.status;
      if (!cameraStatus.isGranted) {
        final result = await Permission.camera.request();
        if (!result.isGranted) {
          if (mounted) {
            setState(() {
              _isCameraAvailable = false;
              _permissionDenied = true;
            });
          }
          return;
        }
      }

      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        setState(() => _isCameraAvailable = false);
        return;
      }

      _cameraController = CameraController(
        _cameras!.first,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      try {
        await _cameraController!.setFocusMode(FocusMode.auto);
      } catch (e) {
        debugPrint('[스캐너] 자동 초점 설정 실패: $e');
      }

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _isCameraAvailable = true;
          _permissionDenied = false;
        });
        _startAutoDetection();
      }
    } catch (e) {
      debugPrint('카메라 초기화 실패: $e');
      if (mounted) setState(() => _isCameraAvailable = false);
    }
  }

  @override
  void dispose() {
    _stopAutoDetection();
    _stopListening();
    _countdownTimer?.cancel();
    _cornerBuffer.clear();
    _cameraController?.dispose();
    super.dispose();
  }

  void _onCameraFrame(CameraImage image) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastDetectionMs < 350) return;
    if (_isDetecting || _isCapturing || _showCapturedFeedback) return;

    _lastDetectionMs = now;
    _isDetecting = true;

    final yPlane = image.planes[0];
    final yBytes = yPlane.bytes;
    final width = image.width;
    final height = image.height;
    final bytesPerRow = yPlane.bytesPerRow;

    final sensorOrientation = _cameras?.first.sensorOrientation ?? 0;
    final needsRotation = (sensorOrientation == 90 || sensorOrientation == 270)
        && width > height;
    debugPrint('[스캐너] 프레임: ${width}x$height, sensor=$sensorOrientation, rotate=$needsRotation');

    _processFrame(yBytes, width, height, bytesPerRow, needsRotation, sensorOrientation);
  }

  Future<void> _processFrame(
    Uint8List yBytes, int width, int height, int bytesPerRow,
    bool needsRotation, int sensorOrientation,
  ) async {
    try {
      final dlResult = await DocAlignerService.instance
          .detectCornersFromYPlane(yBytes, width, height, bytesPerRow,
              needsRotation: needsRotation,
              sensorOrientation: sensorOrientation);

      if (!mounted) return;

      List<Offset>? corners;
      if (dlResult != null && dlResult.corners.length == 4) {
        corners = dlResult.corners;
      }

      final isDefault = corners == null || _isDefaultCorners(corners);

      if (isDefault) {
        _noDetectionCount++;
        if (_noDetectionCount >= 5) {
          _cornerBuffer.clear();
          _stableFrameCount = 0;
          _autoCountdown = 0;
          setState(() {
            _detectedCorners = null;
            _smoothedCorners = null;
            _qualityInfo = {'isGood': false, 'score': 0.0, 'issues': <String>['문서를 찾을 수 없음']};
            _documentSize = null;
          });
        }
      } else {
        _noDetectionCount = 0;
        final ordered = _orderCorners(corners);
        final smoothed = _applySmoothingToCorners(ordered);

        if (smoothed == null) {
          _isDetecting = false;
          return;
        }

        final avgBright = _averageBrightnessFast(yBytes, width, height, bytesPerRow);
        final quality = _quickQuality(corners, avgBright);
        final isGood = quality['isGood'] == true;

        if (isGood) { _stableFrameCount++; } else { _stableFrameCount = 0; _autoCountdown = 0; }
        setState(() {
          _detectedCorners = smoothed;
          _smoothedCorners = smoothed;
          _qualityInfo = quality;
        });

        if (isGood && _stableFrameCount >= _requiredStableFrames && _autoCountdown == 0) {
          _startAutoCountdown();
        }
      }
    } catch (e) {
      debugPrint('프레임 처리 실패: $e');
    } finally {
      _isDetecting = false;
    }
  }

  double _averageBrightnessFast(Uint8List yBytes, int w, int h, int bytesPerRow) {
    int sum = 0;
    int count = 0;
    for (int y = 0; y < h; y += 64) {
      for (int x = 0; x < w; x += 64) {
        final idx = y * bytesPerRow + x;
        if (idx < yBytes.length) { sum += yBytes[idx]; count++; }
      }
    }
    return count > 0 ? sum / count : 128;
  }

  Map<String, dynamic> _quickQuality(List<Offset> corners, double avgBright) {
    final issues = <String>[];
    double score = 100.0;

    final lightScore = (avgBright / 255 * 100).clamp(0.0, 100.0);
    if (lightScore < 30) { issues.add('너무 어두움'); score -= 25; }
    else if (lightScore > 92) { issues.add('너무 밝음'); score -= 20; }

    double area = 0;
    for (int i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      area += corners[i].dx * corners[j].dy;
      area -= corners[j].dx * corners[i].dy;
    }
    area = area.abs() / 2;
    if (area < 0.15) { issues.add('문서가 너무 작음'); score -= 25; }

    final sides = <double>[];
    for (int i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      final dx = corners[j].dx - corners[i].dx;
      final dy = corners[j].dy - corners[i].dy;
      sides.add(math.sqrt(dx * dx + dy * dy));
    }
    final r1 = sides[0] > 0 ? math.min(sides[0], sides[2]) / math.max(sides[0], sides[2]) : 0.0;
    final r2 = sides[1] > 0 ? math.min(sides[1], sides[3]) / math.max(sides[1], sides[3]) : 0.0;
    final angleScore = ((r1 + r2) / 2 * 100).clamp(0.0, 100.0);
    if (angleScore < 60) { issues.add('각도가 기울어짐'); score -= 20; }

    if (!_isConvexQuad(corners)) {
      issues.add('영역이 올바르지 않음');
      score -= 25;
    }

    return {
      'isGood': score >= 70 && issues.isEmpty,
      'score': score.clamp(0.0, 100.0),
      'issues': issues,
    };
  }

  bool _isConvexQuad(List<Offset> corners) {
    if (corners.length != 4) return false;
    bool? positive;
    for (int i = 0; i < 4; i++) {
      final a = corners[i];
      final b = corners[(i + 1) % 4];
      final c = corners[(i + 2) % 4];
      final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
      if (cross.abs() < 1e-9) continue;
      if (positive == null) {
        positive = cross > 0;
      } else if ((cross > 0) != positive) {
        return false;
      }
    }
    return true;
  }

  /// 꼭짓점을 좌상→우상→우하→좌하 순서로 정렬하여 사각형 유지
  List<Offset> _orderCorners(List<Offset> corners) {
    if (corners.length != 4) return corners;
    final sorted = List<Offset>.from(corners);
    // 중심점 계산
    final cx = sorted.map((p) => p.dx).reduce((a, b) => a + b) / 4;
    final cy = sorted.map((p) => p.dy).reduce((a, b) => a + b) / 4;
    // 각도 기준 정렬 (좌상부터 시계방향)
    final topLeft = sorted.where((p) => p.dx <= cx && p.dy <= cy).toList();
    final topRight = sorted.where((p) => p.dx > cx && p.dy <= cy).toList();
    final bottomRight = sorted.where((p) => p.dx > cx && p.dy > cy).toList();
    final bottomLeft = sorted.where((p) => p.dx <= cx && p.dy > cy).toList();
    // 각 사분면에 정확히 1개씩 있으면 정렬 적용
    if (topLeft.length == 1 && topRight.length == 1 &&
        bottomRight.length == 1 && bottomLeft.length == 1) {
      return [topLeft[0], topRight[0], bottomRight[0], bottomLeft[0]];
    }
    // 불균형 시 atan2 기반 정렬
    sorted.sort((a, b) {
      final angleA = math.atan2(a.dy - cy, a.dx - cx);
      final angleB = math.atan2(b.dy - cy, b.dx - cx);
      return angleA.compareTo(angleB);
    });
    // atan2에서 좌상(−π 근처)이 첫 번째가 되도록 회전
    // 가장 좌상 포인트 찾기
    int tlIdx = 0;
    double minSum = double.infinity;
    for (int i = 0; i < 4; i++) {
      final sum = sorted[i].dx + sorted[i].dy;
      if (sum < minSum) { minSum = sum; tlIdx = i; }
    }
    return [
      sorted[tlIdx], sorted[(tlIdx + 1) % 4],
      sorted[(tlIdx + 2) % 4], sorted[(tlIdx + 3) % 4],
    ];
  }

  bool _isDefaultCorners(List<Offset> corners) {
    if (corners.length != 4) return true;
    final defaultCorners = [
      const Offset(0.05, 0.05), const Offset(0.95, 0.05),
      const Offset(0.95, 0.95), const Offset(0.05, 0.95),
    ];
    double totalDist = 0;
    for (int i = 0; i < 4; i++) {
      totalDist += (corners[i] - defaultCorners[i]).distance;
    }
    return totalDist < 0.02;
  }

  List<Offset>? _applySmoothingToCorners(List<Offset> newCorners) {
    if (_smoothedCorners != null && _smoothedCorners!.length == 4) {
      double maxDelta = 0;
      for (int i = 0; i < 4; i++) {
        final d = (newCorners[i] - _smoothedCorners![i]).distance;
        if (d > maxDelta) maxDelta = d;
      }
      if (maxDelta > 0.50) {
        _cornerBuffer.clear();
        _cornerBuffer.add(List.from(newCorners));
        return List.from(newCorners);
      }
    }

    _cornerBuffer.add(List.from(newCorners));
    if (_cornerBuffer.length > _bufferSize) _cornerBuffer.removeAt(0);

    if (_cornerBuffer.length < 2) return List.from(newCorners);

    final avgCorners = List.generate(4, (i) {
      final dxs = _cornerBuffer.map((f) => f[i].dx).toList()..sort();
      final dys = _cornerBuffer.map((f) => f[i].dy).toList()..sort();
      final medDx = dxs[dxs.length ~/ 2];
      final medDy = dys[dys.length ~/ 2];
      const outlierThreshX = 0.08;
      const outlierThreshY = 0.12;
      final filtDx = dxs.where((v) => (v - medDx).abs() <= outlierThreshX).toList();
      final filtDy = dys.where((v) => (v - medDy).abs() <= outlierThreshY).toList();
      final dx = filtDx.isEmpty ? medDx : filtDx.reduce((a, b) => a + b) / filtDx.length;
      final dy = filtDy.isEmpty ? medDy : filtDy.reduce((a, b) => a + b) / filtDy.length;
      return Offset(dx, dy);
    });

    if (_smoothedCorners == null || _smoothedCorners!.length != 4) {
      return avgCorners;
    }
    return List.generate(4, (i) => Offset(
      _smoothedCorners![i].dx * (1 - _smoothingFactor) + avgCorners[i].dx * _smoothingFactor,
      _smoothedCorners![i].dy * (1 - _smoothingFactor) + avgCorners[i].dy * _smoothingFactor,
    ));
  }

  void _startAutoCountdown() {
    _countdownTimer?.cancel();
    setState(() => _autoCountdown = 1);

    _countdownTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      _countdownTimer = null;
      setState(() => _autoCountdown = 0);
      _captureImage();
    });
  }

  Future<void> _captureImage() async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isCapturing) return;

    setState(() {
      _isCapturing = true;
      _showCaptureFlash = true;
    });
    _stopAutoDetection();

    // 플래시 효과 해제
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _showCaptureFlash = false);
    });

    try {
      final xFile = await _cameraController!.takePicture();

      if (_batchMode) {
        setState(() {
          _batchImages.add(xFile.path);
          _isCapturing = false;
          _stableFrameCount = 0;
          _autoCountdown = 0;
          _noDetectionCount = 0;
        });

        if (_autoMode && mounted) {
          setState(() => _showCapturedFeedback = true);
          await Future.delayed(const Duration(milliseconds: 1200));
          if (mounted) {
            setState(() {
              _showCapturedFeedback = false;
              _detectedCorners = null;
              _smoothedCorners = null;
              _qualityInfo = null;
            });
            _startAutoDetection();
          }
        }
      } else {
        if (mounted) _navigateToCrop(xFile.path);
      }
    } catch (e) {
      debugPrint('촬영 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('촬영 실패: $e')),
        );
        if (_autoMode) _startAutoDetection();
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _pickFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: _batchMode,
      );
      if (result == null || result.files.isEmpty) return;

      if (_batchMode) {
        for (final file in result.files) {
          if (file.path != null) setState(() => _batchImages.add(file.path!));
        }
      } else {
        final filePath = result.files.first.path;
        if (filePath != null && mounted) _navigateToCrop(filePath);
      }
    } catch (e) {
      debugPrint('파일 선택 실패: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      if (_batchMode) {
        setState(() => _batchImages.add(picked.path));
      } else {
        if (mounted) _navigateToCrop(picked.path);
      }
    } catch (e) {
      debugPrint('갤러리 선택 실패: $e');
    }
  }

  void _navigateToCrop(String imagePath) {
    _stopAutoDetection();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CropPage(imagePath: imagePath),
      ),
    ).then((_) {
      if (mounted && _autoMode && _isCameraAvailable) _startAutoDetection();
    });
  }

  void _finishBatch() {
    if (_batchImages.isEmpty) return;
    _stopAutoDetection();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CropPage(
          imagePath: _batchImages.first,
          batchImages: _batchImages,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('문서 스캔'),
        actions: [
          IconButton(
            icon: Icon(
              _autoMode ? Icons.auto_awesome : Icons.auto_awesome_outlined,
              color: _autoMode ? Colors.green : Colors.white,
            ),
            tooltip: '자동 촬영 모드',
            onPressed: () {
              setState(() {
                _autoMode = !_autoMode;
                if (_autoMode) {
                  _startAutoDetection();
                } else {
                  _stopAutoDetection();
                  _detectedCorners = null;
                  _smoothedCorners = null;
                  _qualityInfo = null;
                  _stableFrameCount = 0;
                  _autoCountdown = 0;
                  _noDetectionCount = 0;
                }
              });
            },
          ),
          if (_speechInitialized)
            IconButton(
              icon: Icon(
                _voiceMode ? Icons.mic : Icons.mic_none,
                color: _voiceMode ? Colors.blue : Colors.white,
              ),
              tooltip: '음성 명령 촬영',
              onPressed: () {
                setState(() {
                  _voiceMode = !_voiceMode;
                  if (_voiceMode) { _startListening(); } else { _stopListening(); }
                });
              },
            ),
          IconButton(
            icon: Icon(
              _batchMode ? Icons.burst_mode : Icons.burst_mode_outlined,
              color: _batchMode ? Colors.amber : Colors.white,
            ),
            tooltip: '연속 촬영 모드',
            onPressed: () => setState(() => _batchMode = !_batchMode),
          ),
          if (_batchMode && _batchImages.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.check, color: Colors.green),
              label: Text(
                '완료 (${_batchImages.length}장)',
                style: const TextStyle(color: Colors.green),
              ),
              onPressed: _finishBatch,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isCameraAvailable && _isCameraInitialized
                ? _buildCameraPreview()
                : _buildNoCameraView(),
          ),
          if (_batchMode && _batchImages.isNotEmpty) _buildBatchPreview(),
          _buildBottomControls(),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final previewSize = _cameraController!.value.previewSize!;
    // 카메라 previewSize는 landscape 기준 (width > height)
    // 세로 모드에서는 뒤집어야 함
    final cameraAspect = previewSize.height / previewSize.width;

    return LayoutBuilder(
      builder: (context, constraints) {
        final widgetWidth = constraints.maxWidth;
        final widgetHeight = constraints.maxHeight;
        final widgetAspect = widgetWidth / widgetHeight;

        double renderWidth, renderHeight;
        if (widgetAspect > cameraAspect) {
          // 위젯이 더 넓음 → 가로 기준 채움
          renderWidth = widgetWidth;
          renderHeight = widgetWidth / cameraAspect;
        } else {
          // 위젯이 더 좁음 → 세로 기준 채움
          renderHeight = widgetHeight;
          renderWidth = widgetHeight * cameraAspect;
        }

        final dx = (widgetWidth - renderWidth) / 2;
        final dy = (widgetHeight - renderHeight) / 2;

        return ClipRect(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: dx,
                top: dy,
                width: renderWidth,
                height: renderHeight,
                child: CameraPreview(_cameraController!),
              ),

              if (_autoMode && _detectedCorners != null)
                Positioned(
                  left: dx,
                  top: dy,
                  width: renderWidth,
                  height: renderHeight,
                  child: CustomPaint(
                    painter: _DetectedDocumentPainter(
                      corners: _detectedCorners!,
                      quality: _qualityInfo,
                    ),
                  ),
                ),

              if (!_autoMode)
                Positioned.fill(
                  child: CustomPaint(painter: _ScanGuideOverlayPainter()),
                ),

              if (_autoMode && _qualityInfo != null)
                Positioned(
                  top: 20, left: 20, right: 20,
                  child: _buildQualityIndicator(),
                ),

              if (_autoCountdown > 0)
                Center(
                  child: Container(
                    width: 120, height: 120,
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.8),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text('$_autoCountdown',
                        style: const TextStyle(color: Colors.white, fontSize: 64, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),

              // 촬영 플래시 효과
              if (_showCaptureFlash)
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: _showCaptureFlash ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 100),
                    child: Container(color: Colors.white),
                  ),
                ),

              if (_showCapturedFeedback)
                Center(
                  child: Container(
                    width: 160, height: 160,
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.85),
                      shape: BoxShape.circle,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.check, color: Colors.white, size: 64),
                        const SizedBox(height: 4),
                        Text('${_batchImages.length}장 촬영',
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQualityIndicator() {
    final quality = _qualityInfo!;
    final score = quality['score'] as double;
    final isGood = quality['isGood'] as bool;
    final issues = quality['issues'] as List<String>;

    Color indicatorColor;
    IconData indicatorIcon;
    String statusText;

    if (isGood) {
      indicatorColor = Colors.green;
      indicatorIcon = Icons.check_circle;
      statusText = '촬영 준비 완료';
    } else if (score >= 50) {
      indicatorColor = Colors.orange;
      indicatorIcon = Icons.warning;
      statusText = '품질 개선 필요';
    } else {
      indicatorColor = Colors.red;
      indicatorIcon = Icons.error;
      statusText = '문서를 찾을 수 없음';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(indicatorIcon, color: indicatorColor, size: 24),
              const SizedBox(width: 8),
              Text(statusText, style: TextStyle(color: indicatorColor, fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('${score.toInt()}%', style: TextStyle(color: indicatorColor, fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          if (issues.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...issues.map((issue) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                const Icon(Icons.info_outline, color: Colors.white70, size: 16),
                const SizedBox(width: 6),
                Text(issue, style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ]),
            )),
          ],
          if (_documentSize != null && _documentSize!.detectedSize != PaperSize.unknown) ...[
            const SizedBox(height: 8),
            const Divider(color: Colors.white30, height: 1),
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.straighten, color: Colors.white70, size: 16),
              const SizedBox(width: 6),
              Text(_documentSize!.toString(), style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _buildNoCameraView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _permissionDenied ? Icons.no_photography_outlined : Icons.camera_alt_outlined,
            size: 80,
            color: Colors.white.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            _permissionDenied ? '카메라 권한이 필요합니다' : '카메라를 사용할 수 없습니다',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            _permissionDenied
                ? '문서를 스캔하려면 카메라 권한을 허용해주세요.\n설정에서 권한을 변경할 수 있습니다.'
                : '카메라가 감지되지 않습니다.\n아래 버튼으로 이미지 파일을 선택해주세요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14),
          ),
          const SizedBox(height: 24),
          if (_permissionDenied) ...[
            ElevatedButton.icon(
              onPressed: () => openAppSettings(),
              icon: const Icon(Icons.settings),
              label: const Text('설정으로 이동'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            onPressed: () async => await _initCamera(),
            icon: const Icon(Icons.refresh, color: Colors.white70),
            label: const Text('다시 시도', style: TextStyle(color: Colors.white70)),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white30)),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchPreview() {
    return Container(
      height: 80,
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _batchImages.length,
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(_batchImages[index]), width: 60, height: 72, fit: BoxFit.cover),
                ),
                Positioned(
                  bottom: 2, right: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                    child: Text('${index + 1}', style: const TextStyle(color: Colors.white, fontSize: 10)),
                  ),
                ),
                Positioned(
                  top: 0, right: 0,
                  child: GestureDetector(
                    onTap: () => setState(() => _batchImages.removeAt(index)),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                      child: const Icon(Icons.close, size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      color: Colors.black,
      child: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildControlButton(icon: Icons.photo_library, label: '파일 선택', onTap: _pickFromFile),
            if (_isCameraAvailable && _isCameraInitialized)
              GestureDetector(
                onTap: _isCapturing ? null : _captureImage,
                child: Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isCapturing ? Colors.grey : Colors.white,
                    border: Border.all(color: Colors.white30, width: 4),
                  ),
                  child: _isCapturing
                      ? const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black54))
                      : const Icon(Icons.camera, size: 36, color: Colors.black),
                ),
              ),
            _buildControlButton(icon: Icons.image, label: '갤러리', onTap: _pickFromGallery),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({required IconData icon, required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 28),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ScanGuideOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final margin = size.width * 0.08;
    final rect = Rect.fromLTRB(margin, size.height * 0.05, size.width - margin, size.height * 0.95);
    final cornerLen = 30.0;

    canvas.drawLine(rect.topLeft, rect.topLeft + Offset(cornerLen, 0), paint);
    canvas.drawLine(rect.topLeft, rect.topLeft + Offset(0, cornerLen), paint);
    canvas.drawLine(rect.topRight, rect.topRight + Offset(-cornerLen, 0), paint);
    canvas.drawLine(rect.topRight, rect.topRight + Offset(0, cornerLen), paint);
    canvas.drawLine(rect.bottomRight, rect.bottomRight + Offset(-cornerLen, 0), paint);
    canvas.drawLine(rect.bottomRight, rect.bottomRight + Offset(0, -cornerLen), paint);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + Offset(cornerLen, 0), paint);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + Offset(0, -cornerLen), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DetectedDocumentPainter extends CustomPainter {
  final List<Offset> corners;
  final Map<String, dynamic>? quality;

  _DetectedDocumentPainter({required this.corners, this.quality});

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;

    Color lineColor;
    if (quality != null && quality!['isGood'] == true) {
      lineColor = Colors.green;
    } else if (quality != null && quality!['score'] >= 50) {
      lineColor = Colors.orange;
    } else {
      lineColor = Colors.red;
    }

    final points = corners.map((c) => Offset(c.dx * size.width, c.dy * size.height)).toList();

    final docPath = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[2].dx, points[2].dy)
      ..lineTo(points[3].dx, points[3].dy)
      ..close();

    final maskPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;
    final fullPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final maskPath = Path.combine(PathOperation.difference, fullPath, docPath);
    canvas.drawPath(maskPath, maskPaint);

    canvas.drawPath(docPath, Paint()..color = lineColor..style = PaintingStyle.stroke..strokeWidth = 4.0);

    final handlePaint = Paint()..color = lineColor..style = PaintingStyle.fill;
    for (final point in points) {
      canvas.drawCircle(point, 12, Paint()..color = Colors.white..style = PaintingStyle.fill);
      canvas.drawCircle(point, 8, handlePaint);
    }
  }

  @override
  bool shouldRepaint(_DetectedDocumentPainter oldDelegate) {
    return corners != oldDelegate.corners || quality != oldDelegate.quality;
  }
}
