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
import 'package:shared_preferences/shared_preferences.dart';
import 'crop_page.dart';
import '../../../core/services/document_scanner_service.dart';
import '../../../core/services/doc_aligner_service.dart';
import '../../../core/services/training_data_service.dart';

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
  bool _isStreamStarting = false;

  // 연속 촬영 모드
  bool _batchMode = false;
  final List<String> _batchImages = [];

  // ID카드 모드
  bool _idCardMode = false;
  String? _idCardFrontPath;  // 앞면 촬영 완료 시

  // 자동 스캔 모드
  bool _autoMode = true;
  int _lastDetectionMs = 0;
  Map<String, dynamic>? _qualityInfo;
  int _stableFrameCount = 0;
  int _autoCountdown = 0;
  Timer? _countdownTimer;
  static const int _requiredStableFrames = 10;

  // 경계선 안정화
  List<Offset>? _smoothedCorners;
  static const double _smoothingFactor = 0.35;
  static const int _bufferSize = 3;
  final List<List<Offset>> _cornerBuffer = [];
  int _noDetectionCount = 0;
  bool _isDetecting = false;

  // 촬영 피드백
  bool _showCapturedFeedback = false;
  bool _showCaptureFlash = false;

  // 학습 데이터 수집용: 마지막 프레임 Y plane 보관
  Uint8List? _lastYBytes;
  int _lastYWidth = 0;
  int _lastYHeight = 0;
  int _lastYBytesPerRow = 0;

  // 터치 촬영
  bool _tapToCapture = false;

  // 음성 명령 촬영
  bool _voiceMode = false;
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechInitialized = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _initCameraAndSpeech();
  }

  Future<void> _initCameraAndSpeech() async {
    await _initCamera();
    await _initSpeech();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _autoMode = prefs.getBool('autoScan') ?? true;
        _tapToCapture = prefs.getBool('tapToCapture') ?? false;
      });
    }
  }

  Future<void> _initSpeech() async {
    try {
      // 마이크 권한 확인
      final micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        final result = await Permission.microphone.request();
        if (!result.isGranted) {
          debugPrint('마이크 권한 거부됨');
          return;
        }
      }

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
    if (!_autoMode || _isStreamStarting) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (_cameraController!.value.isStreamingImages) return;
    _isStreamStarting = true;
    try {
      _cameraController!.startImageStream(_onCameraFrame);
    } catch (e) {
      debugPrint('[스캐너] 이미지 스트림 시작 실패: $e');
    } finally {
      _isStreamStarting = false;
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
        ResolutionPreset.max,
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
        // 카메라 초점/노출 안정화 대기 후 감지 시작
        await Future.delayed(const Duration(seconds: 2));
        if (mounted && _autoMode) _startAutoDetection();
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
    if (now - _lastDetectionMs < 300) return;
    if (_isDetecting || _isCapturing || _showCapturedFeedback) return;

    _lastDetectionMs = now;
    _isDetecting = true;

    final yPlane = image.planes[0];
    final yBytes = yPlane.bytes;
    final width = image.width;
    final height = image.height;
    final bytesPerRow = yPlane.bytesPerRow;

    // 학습 데이터 수집용 보관
    _lastYBytes = Uint8List.fromList(yBytes);
    _lastYWidth = width;
    _lastYHeight = height;
    _lastYBytesPerRow = bytesPerRow;

    final sensorOrientation = _cameras?.first.sensorOrientation ?? 0;
    final needsRotation = (sensorOrientation == 90 || sensorOrientation == 270)
        && width > height;

    _processFrame(yBytes, width, height, bytesPerRow, needsRotation, sensorOrientation);
  }

  Future<void> _processFrame(
    Uint8List yBytes, int width, int height, int bytesPerRow,
    bool needsRotation, int sensorOrientation,
  ) async {
    try {
      // OpenCV 기반 실시간 감지 (좌표가 정확함)
      List<Offset>? corners;
      try {
        final cvCorners = await DocumentScannerService.instance
            .detectCornersFromGrayscale(yBytes, width, height, bytesPerRow);
        if (cvCorners.length == 4 && !_isDefaultCorners(cvCorners)) {
          corners = cvCorners;
        }
      } catch (_) {}

      // OpenCV 실패 시 DocAligner fallback
      if (corners == null || _isDefaultCorners(corners)) {
        final dlResult = await DocAlignerService.instance
            .detectCornersFromYPlane(yBytes, width, height, bytesPerRow,
                needsRotation: needsRotation,
                sensorOrientation: sensorOrientation);
        if (dlResult != null && dlResult.corners.length == 4) {
          corners = dlResult.corners;
        }
      }

      if (!mounted) return;

      final isDefault = corners == null || _isDefaultCorners(corners);

      if (isDefault) {
        _noDetectionCount++;
        if (_noDetectionCount >= 5) {
          _cornerBuffer.clear();
          _stableFrameCount = 0;
          _autoCountdown = 0;
          setState(() {
            _smoothedCorners = null;
            _qualityInfo = {'isGood': false, 'score': 0.0, 'issues': <String>['문서를 찾을 수 없음']};
          });
        }
      } else {
        _noDetectionCount = 0;
        final ordered = DocumentScannerService.orderCorners(corners);
        final smoothed = _applySmoothingToCorners(ordered);

        if (smoothed == null) {
          _isDetecting = false;
          return;
        }

        final avgBright = _averageBrightnessFast(yBytes, width, height, bytesPerRow);
        final quality = _quickQuality(corners, avgBright);
        final isGood = quality['isGood'] == true;

        if (isGood) {
          _stableFrameCount++;
        } else {
          _stableFrameCount = 0;
          if (_autoCountdown > 0) {
            _countdownTimer?.cancel();
            _countdownTimer = null;
            _autoCountdown = 0;
          }
        }
        setState(() {
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
    if (area < 0.15) { issues.add('문서가 너무 작음'); score -= 30; }

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
    if (angleScore < 70) { issues.add('각도가 기울어짐'); score -= 25; }

    if (!DocumentScannerService.isConvexQuad(corners)) {
      issues.add('영역이 올바르지 않음');
      score -= 30;
    }

    // 좌표 순서 검증: TL(좌상) TR(우상) BR(우하) BL(좌하)
    // TL.x < TR.x, TL.y < BL.y, BR.x > BL.x, BR.y > TR.y
    if (corners.length == 4) {
      final tl = corners[0], tr = corners[1], br = corners[2], bl = corners[3];
      if (tl.dx >= tr.dx || tl.dy >= bl.dy || br.dx <= bl.dx || br.dy <= tr.dy) {
        issues.add('좌표 순서 이상');
        score -= 40;
      }
    }

    return {
      'isGood': score >= 70,
      'score': score.clamp(0.0, 100.0),
      'issues': issues,
    };
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
    return totalDist < 0.04;
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

      if (_idCardMode) {
        // ID카드 모드: 앞면 → 뒷면 순차 촬영
        if (_idCardFrontPath == null) {
          // 앞면 촬영 완료
          setState(() {
            _idCardFrontPath = xFile.path;
            _isCapturing = false;
            _showCapturedFeedback = true;
          });
          _resetDetectionState();
          await Future.delayed(const Duration(milliseconds: 1200));
          if (mounted) {
            setState(() => _showCapturedFeedback = false);
            if (_autoMode) _startAutoDetection();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('앞면 촬영 완료! 뒷면을 촬영하세요'),
                backgroundColor: Colors.blue,
                duration: Duration(seconds: 2),
              ),
            );
          }
        } else {
          // 뒷면 촬영 완료 → 합치기
          setState(() => _isCapturing = true);
          try {
            final combined = await DocumentScannerService.instance
                .combineImagesVertically(_idCardFrontPath!, xFile.path);
            if (combined != null && mounted) {
              setState(() {
                _idCardFrontPath = null;
                _isCapturing = false;
              });
              _navigateToCrop(combined);
            }
          } catch (e) {
            debugPrint('ID카드 합치기 실패: $e');
            if (mounted) {
              setState(() => _isCapturing = false);
              _navigateToCrop(xFile.path);
            }
          }
        }
      } else if (_batchMode) {
        setState(() {
          _batchImages.add(xFile.path);
          _isCapturing = false;
        });
        _resetDetectionState();

        if (_autoMode && mounted) {
          setState(() => _showCapturedFeedback = true);
          await Future.delayed(const Duration(milliseconds: 1200));
          if (mounted) {
            setState(() => _showCapturedFeedback = false);
            _startAutoDetection();
          }
        }
      } else if (TrainingDataService.instance.enabled) {
        // 수집 모드: 데이터만 저장하고 바로 다음 촬영
        _collectTrainingData(xFile.path);
        _resetDetectionState();
        if (mounted) {
          setState(() {
            _isCapturing = false;
            _showCapturedFeedback = true;
          });
          await Future.delayed(const Duration(milliseconds: 800));
          if (mounted) {
            setState(() => _showCapturedFeedback = false);
            if (_autoMode) _startAutoDetection();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('수집 완료 (${await TrainingDataService.instance.getCount()}개)'),
                duration: const Duration(seconds: 1),
                backgroundColor: Colors.blue,
              ),
            );
          }
        }
      } else {
        // 일반 모드: 크롭 페이지로 이동
        _collectTrainingData(xFile.path);
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

  /// 감지 상태 초기화 (촬영 후, CropPage 복귀 시)
  void _resetDetectionState() {
    _cornerBuffer.clear();
    _smoothedCorners = null;
    _qualityInfo = null;
    _stableFrameCount = 0;
    _autoCountdown = 0;
    _noDetectionCount = 0;
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  void _collectTrainingData(String highResPath) {
    if (_lastYBytes == null) return;
    final sensorOrientation = _cameras?.first.sensorOrientation ?? 0;
    final needsRotation = (sensorOrientation == 90 || sensorOrientation == 270)
        && _lastYWidth > _lastYHeight;
    TrainingDataService.instance.collectData(
      yBytes: _lastYBytes!,
      srcWidth: _lastYWidth,
      srcHeight: _lastYHeight,
      bytesPerRow: _lastYBytesPerRow,
      highResImagePath: highResPath,
      needsRotation: needsRotation,
      sensorOrientation: sensorOrientation,
    );
  }

  void _navigateToCrop(String imagePath) {
    _stopAutoDetection();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CropPage(imagePath: imagePath),
      ),
    ).then((_) {
      if (mounted) {
        _resetDetectionState();
        if (_autoMode && _isCameraAvailable) _startAutoDetection();
      }
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
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        title: const Text('문서 스캔', style: TextStyle(shadows: [Shadow(blurRadius: 4, color: Colors.black)])),
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
              _idCardMode ? Icons.badge : Icons.badge_outlined,
              color: _idCardMode ? Colors.cyan : Colors.white,
            ),
            tooltip: 'ID카드 스캔',
            onPressed: () {
              setState(() {
                _idCardMode = !_idCardMode;
                _idCardFrontPath = null;
                if (_idCardMode) _batchMode = false;
              });
            },
          ),
          IconButton(
            icon: Icon(
              _batchMode ? Icons.burst_mode : Icons.burst_mode_outlined,
              color: _batchMode ? Colors.amber : Colors.white,
            ),
            tooltip: '연속 촬영 모드',
            onPressed: () {
              setState(() {
                _batchMode = !_batchMode;
                if (_batchMode) {
                  _idCardMode = false;
                  _idCardFrontPath = null;
                }
              });
            },
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
      body: isLandscape ? _buildLandscapeBody() : _buildPortraitBody(),
    );
  }

  Widget _buildPortraitBody() {
    return Column(
      children: [
        Expanded(
          child: _isCameraAvailable && _isCameraInitialized
              ? _buildCameraPreview()
              : _buildNoCameraView(),
        ),
        if (_batchMode && _batchImages.isNotEmpty) _buildBatchPreview(),
        _buildBottomControls(),
      ],
    );
  }

  Widget _buildLandscapeBody() {
    return Row(
      children: [
        Expanded(
          child: _isCameraAvailable && _isCameraInitialized
              ? _buildCameraPreview()
              : _buildNoCameraView(),
        ),
        SafeArea(
          child: Container(
            width: 100,
            color: Colors.black,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_batchMode && _batchImages.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      '${_batchImages.length}장',
                      style: const TextStyle(color: Colors.amber, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                _buildControlButton(icon: Icons.photo_library, label: '파일', onTap: _pickFromFile),
                const SizedBox(height: 24),
                if (_isCameraAvailable && _isCameraInitialized)
                  GestureDetector(
                    onTap: _isCapturing ? null : _captureImage,
                    child: Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isCapturing ? Colors.grey : Colors.white,
                        border: Border.all(color: Colors.white30, width: 3),
                      ),
                      child: _isCapturing
                          ? const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black54))
                          : const Icon(Icons.camera, size: 30, color: Colors.black),
                    ),
                  ),
                const SizedBox(height: 24),
                _buildControlButton(icon: Icons.image, label: '갤러리', onTap: _pickFromGallery),
                if (_batchMode && _batchImages.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  GestureDetector(
                    onTap: _finishBatch,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('완료', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCameraPreview() {
    final previewSize = _cameraController!.value.previewSize!;
    final orientation = MediaQuery.of(context).orientation;
    // 카메라 previewSize는 landscape 기준
    // 세로 모드에서는 뒤집어서 세로 비율로, 가로 모드에서는 그대로
    final cameraAspect = orientation == Orientation.portrait
        ? previewSize.height / previewSize.width
        : previewSize.width / previewSize.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final widgetWidth = constraints.maxWidth;
        final widgetHeight = constraints.maxHeight;
        final widgetAspect = widgetWidth / widgetHeight;

        // Cover 방식: 화면을 꽉 채우고 넘치는 부분 잘라냄 (카메라 앱처럼)
        double renderWidth, renderHeight;
        if (widgetAspect > cameraAspect) {
          // 위젯이 더 넓음 → 가로 기준 채움, 세로 넘침
          renderWidth = widgetWidth;
          renderHeight = widgetWidth / cameraAspect;
        } else {
          // 위젯이 더 좁음 → 세로 기준 채움, 가로 넘침
          renderHeight = widgetHeight;
          renderWidth = widgetHeight * cameraAspect;
        }

        final dx = (widgetWidth - renderWidth) / 2;
        final dy = (widgetHeight - renderHeight) / 2;

        return GestureDetector(
          onTap: _tapToCapture && !_isCapturing ? _captureImage : null,
          child: ClipRect(
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

              // 문서 감지 오버레이 (cover 크롭 보정)
              // 카메라 좌표(0~1)를 화면에 보이는 영역에 맞게 변환
              if (_autoMode && _smoothedCorners != null && _smoothedCorners!.length == 4)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _DetectionOverlayPainter(
                      corners: _smoothedCorners!,
                      isGood: _qualityInfo?['isGood'] == true,
                      // cover 크롭 오프셋: 카메라 전체 이미지 중 잘린 비율
                      cropOffsetX: dx < 0 ? -dx / renderWidth : 0,
                      cropOffsetY: dy < 0 ? -dy / renderHeight : 0,
                      cropScaleX: widgetWidth / renderWidth,
                      cropScaleY: widgetHeight / renderHeight,
                    ),
                  ),
                ),

              if (!_autoMode)
                Positioned.fill(
                  child: CustomPaint(painter: _ScanGuideOverlayPainter()),
                ),

              // 자동 모드 상태 + 좌표 로그
              if (_autoMode && _qualityInfo != null)
                Positioned(
                  top: 16, left: 8, right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _qualityInfo!['isGood'] == true ? Icons.check_circle : Icons.search,
                              color: _qualityInfo!['isGood'] == true ? Colors.green : Colors.white70,
                              size: 16,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _qualityInfo!['isGood'] == true
                                  ? '감지됨 (s:$_stableFrameCount/$_requiredStableFrames)'
                                  : '찾는 중...',
                              style: TextStyle(
                                color: _qualityInfo!['isGood'] == true ? Colors.green : Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                        if (_smoothedCorners != null && _smoothedCorners!.length == 4) ...[
                          const SizedBox(height: 2),
                          Text(
                            'TL(${_smoothedCorners![0].dx.toStringAsFixed(2)},${_smoothedCorners![0].dy.toStringAsFixed(2)}) '
                            'TR(${_smoothedCorners![1].dx.toStringAsFixed(2)},${_smoothedCorners![1].dy.toStringAsFixed(2)}) '
                            'BR(${_smoothedCorners![2].dx.toStringAsFixed(2)},${_smoothedCorners![2].dy.toStringAsFixed(2)}) '
                            'BL(${_smoothedCorners![3].dx.toStringAsFixed(2)},${_smoothedCorners![3].dy.toStringAsFixed(2)}) '
                            'sc:${(_qualityInfo!['score'] as num).toStringAsFixed(0)}',
                            style: const TextStyle(color: Colors.yellow, fontSize: 9, fontFamily: 'monospace'),
                          ),
                        ],
                      ],
                    ),
                  ),
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
                        Text(
                          _idCardMode ? '앞면 촬영 완료' : '${_batchImages.length}장 촬영',
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),

              // ID카드 모드 안내
              if (_idCardMode)
                Positioned(
                  bottom: 10, left: 20, right: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.cyan.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.badge, color: Colors.white, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          _idCardFrontPath == null ? 'ID카드 앞면을 촬영하세요' : 'ID카드 뒷면을 촬영하세요',
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            ),
          ),
        );
      },
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

/// 문서 감지 결과를 카메라 프리뷰 위에 그리는 페인터
/// corners는 카메라 전체 이미지 기준 정규화 좌표 (0~1)
/// cover 크롭 보정: 화면에 보이는 영역만큼 좌표를 변환
class _DetectionOverlayPainter extends CustomPainter {
  final List<Offset> corners;
  final bool isGood;
  // cover 크롭 보정 파라미터
  final double cropOffsetX; // 잘린 왼쪽 비율 (0~0.x)
  final double cropOffsetY; // 잘린 위쪽 비율
  final double cropScaleX;  // 보이는 영역 / 전체 비율 (< 1.0)
  final double cropScaleY;

  _DetectionOverlayPainter({
    required this.corners,
    required this.isGood,
    this.cropOffsetX = 0,
    this.cropOffsetY = 0,
    this.cropScaleX = 1,
    this.cropScaleY = 1,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;

    // 카메라 좌표(0~1) → 화면 보이는 영역 픽셀 좌표
    // 1) 좌표에서 크롭 오프셋 빼기: 잘린 부분 보정
    // 2) 보이는 비율로 스케일: 전체→보이는 영역
    final pts = corners.map((c) {
      final x = (c.dx - cropOffsetX) / cropScaleX * size.width;
      final y = (c.dy - cropOffsetY) / cropScaleY * size.height;
      return Offset(x, y);
    }).toList();

    final path = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy)
      ..lineTo(pts[3].dx, pts[3].dy)
      ..close();

    // 반투명 채우기
    canvas.drawPath(
      path,
      Paint()
        ..color = (isGood ? Colors.green : Colors.orange).withValues(alpha: 0.15),
    );

    // 경계선
    canvas.drawPath(
      path,
      Paint()
        ..color = isGood ? Colors.green : Colors.orange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // 꼭짓점 원
    final dotPaint = Paint()
      ..color = isGood ? Colors.green : Colors.orange
      ..style = PaintingStyle.fill;
    for (final pt in pts) {
      canvas.drawCircle(pt, 6, dotPaint);
      canvas.drawCircle(
        pt,
        6,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionOverlayPainter oldDelegate) {
    return corners != oldDelegate.corners || isGood != oldDelegate.isGood;
  }
}
