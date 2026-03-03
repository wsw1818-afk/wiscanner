import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:image/image.dart' as img;

/// 양면 펼침 페이지 감지 결과
class DualPageResult {
  /// 페이지 수: 0=문서없음, 1=단면, 2=양면
  final int pageCount;

  /// 분류 신뢰도 (softmax 최대값)
  final double confidence;

  /// 중앙 분할선 x좌표 (정규화 0~1, pageCount=2일 때만 유효)
  final double spineX;

  /// 왼쪽 페이지 4코너 [TL, TR, BR, BL] (정규화 0~1)
  final List<Offset> leftCorners;

  /// 오른쪽 페이지 4코너 [TL, TR, BR, BL] (정규화 0~1, pageCount=2일 때만)
  final List<Offset> rightCorners;

  const DualPageResult({
    required this.pageCount,
    required this.confidence,
    required this.spineX,
    required this.leftCorners,
    required this.rightCorners,
  });

  @override
  String toString() =>
      'DualPageResult(pages=$pageCount, conf=${confidence.toStringAsFixed(2)}, '
      'spine=${spineX.toStringAsFixed(2)})';
}

/// DualPageDetector ONNX 추론 서비스
/// 모델: dual_page_detector_int8.onnx (MobileNetV3-Small 기반)
/// 입력: [1, 3, 256, 256] float32 (RGB, NCHW, 0~1)
/// 출력: page_count [1,3], spine_x [1,1], left_corners [1,8], right_corners [1,8]
class DualPageDetectorService {
  DualPageDetectorService._();
  static final DualPageDetectorService instance = DualPageDetectorService._();

  OrtSession? _session;
  OrtSessionOptions? _sessionOptions;
  bool _initialized = false;

  static const String _modelAsset =
      'assets/models/dual_page_detector_int8.onnx';
  static const int _inputSize = 256;

  /// 모델 초기화
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      OrtEnv.instance.init();
      _sessionOptions = OrtSessionOptions()
        ..setInterOpNumThreads(2)
        ..setIntraOpNumThreads(2)
        ..setSessionGraphOptimizationLevel(
            GraphOptimizationLevel.ortEnableAll);

      final rawAsset = await rootBundle.load(_modelAsset);
      final bytes = rawAsset.buffer.asUint8List();
      _session = OrtSession.fromBuffer(bytes, _sessionOptions!);
      debugPrint(
          '[DualPageDetector] 모델 로드 완료 (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)');
    } catch (e) {
      debugPrint('[DualPageDetector] 모델 로드 실패: $e');
    }
  }

  /// 이미지 bytes(JPEG/PNG)에서 양면/단면 감지
  Future<DualPageResult?> detect(Uint8List imageBytes) async {
    if (!_initialized) await init();
    if (_session == null) return null;

    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;

      final resized = img.copyResize(decoded,
          width: _inputSize,
          height: _inputSize,
          interpolation: img.Interpolation.linear);

      final inputData = _imageToNCHW(resized);
      return await _runInference(inputData);
    } catch (e) {
      debugPrint('[DualPageDetector] 추론 실패: $e');
      return null;
    }
  }

  /// 카메라 Y plane에서 실시간 감지
  Future<DualPageResult?> detectFromYPlane(
    Uint8List yBytes,
    int srcWidth,
    int srcHeight,
    int bytesPerRow, {
    bool needsRotation = false,
  }) async {
    if (!_initialized) await init();
    if (_session == null) return null;

    try {
      final inputData = _yPlaneToNCHW(
          yBytes, srcWidth, srcHeight, bytesPerRow, needsRotation);
      return await _runInference(inputData);
    } catch (e) {
      debugPrint('[DualPageDetector] Y plane 추론 실패: $e');
      return null;
    }
  }

  /// NCHW float32 입력으로 ONNX 추론 실행
  Future<DualPageResult?> _runInference(Float32List inputData) async {
    final inputTensor = OrtValueTensor.createTensorWithDataList(
      inputData,
      [1, 3, _inputSize, _inputSize],
    );

    final inputs = {'img': inputTensor};
    final runOptions = OrtRunOptions();

    try {
      final outputs = await _session!.runAsync(runOptions, inputs);

      // 출력 파싱
      final pageCountLogits = outputs?[0]?.value as List<List<double>>;
      final spineXRaw = outputs?[1]?.value as List<List<double>>;
      final leftRaw = outputs?[2]?.value as List<List<double>>;
      final rightRaw = outputs?[3]?.value as List<List<double>>;

      // Softmax로 분류 확률 계산
      final logits = pageCountLogits[0];
      final probs = _softmax(logits);
      int pageCount = 0;
      double maxProb = probs[0];
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > maxProb) {
          maxProb = probs[i];
          pageCount = i;
        }
      }

      final spineX = spineXRaw[0][0].clamp(0.0, 1.0);

      // 코너 파싱
      final leftCorners = <Offset>[];
      final rightCorners = <Offset>[];

      if (pageCount >= 1) {
        final lc = leftRaw[0];
        for (int i = 0; i < 4; i++) {
          leftCorners.add(Offset(
            lc[i * 2].clamp(0.0, 1.0),
            lc[i * 2 + 1].clamp(0.0, 1.0),
          ));
        }
      }

      if (pageCount == 2) {
        final rc = rightRaw[0];
        for (int i = 0; i < 4; i++) {
          rightCorners.add(Offset(
            rc[i * 2].clamp(0.0, 1.0),
            rc[i * 2 + 1].clamp(0.0, 1.0),
          ));
        }
      }

      // 결과 정리
      for (final output in outputs ?? []) {
        output?.release();
      }
      inputTensor.release();
      runOptions.release();

      return DualPageResult(
        pageCount: pageCount,
        confidence: maxProb,
        spineX: spineX,
        leftCorners: leftCorners,
        rightCorners: rightCorners,
      );
    } catch (e) {
      inputTensor.release();
      runOptions.release();
      rethrow;
    }
  }

  /// 이미지 → NCHW float32 변환
  Float32List _imageToNCHW(img.Image resized) {
    final inputData = Float32List(_inputSize * _inputSize * 3);
    final planeSize = _inputSize * _inputSize;
    for (int y = 0; y < _inputSize; y++) {
      for (int x = 0; x < _inputSize; x++) {
        final pixel = resized.getPixel(x, y);
        final idx = y * _inputSize + x;
        inputData[idx] = pixel.r / 255.0;
        inputData[planeSize + idx] = pixel.g / 255.0;
        inputData[planeSize * 2 + idx] = pixel.b / 255.0;
      }
    }
    return inputData;
  }

  /// Y plane → NCHW float32 변환 (그레이스케일 → R=G=B)
  Float32List _yPlaneToNCHW(
    Uint8List yBytes,
    int srcWidth,
    int srcHeight,
    int bytesPerRow,
    bool needsRotation,
  ) {
    final inputData = Float32List(_inputSize * _inputSize * 3);
    final planeSize = _inputSize * _inputSize;

    final effectiveW = needsRotation ? srcHeight : srcWidth;
    final effectiveH = needsRotation ? srcWidth : srcHeight;

    final scaleX = effectiveW / _inputSize;
    final scaleY = effectiveH / _inputSize;

    for (int dy = 0; dy < _inputSize; dy++) {
      final srcY = (dy * scaleY).toInt().clamp(0, effectiveH - 1);
      for (int dx = 0; dx < _inputSize; dx++) {
        final srcX = (dx * scaleX).toInt().clamp(0, effectiveW - 1);

        int yVal;
        if (needsRotation) {
          final rotX = srcY;
          final rotY = srcWidth - 1 - srcX;
          final byteIdx = rotY * bytesPerRow + rotX;
          yVal = byteIdx < yBytes.length ? yBytes[byteIdx] : 128;
        } else {
          final byteIdx = srcY * bytesPerRow + srcX;
          yVal = byteIdx < yBytes.length ? yBytes[byteIdx] : 128;
        }

        final normalized = yVal / 255.0;
        final idx = dy * _inputSize + dx;
        inputData[idx] = normalized;
        inputData[planeSize + idx] = normalized;
        inputData[planeSize * 2 + idx] = normalized;
      }
    }

    return inputData;
  }

  /// Softmax 계산
  List<double> _softmax(List<double> logits) {
    final maxVal = logits.reduce((a, b) => a > b ? a : b);
    final exps = logits.map((x) => _exp(x - maxVal)).toList();
    final sumExp = exps.reduce((a, b) => a + b);
    return exps.map((e) => e / sumExp).toList();
  }

  double _exp(double x) {
    // 안전한 exp (오버플로 방지)
    if (x > 88) return double.maxFinite;
    if (x < -88) return 0.0;
    return x.isNaN ? 0.0 : _nativeExp(x);
  }

  double _nativeExp(double x) {
    // dart:math exp 사용
    return x == 0 ? 1.0 : (x > 0 ? _posExp(x) : 1.0 / _posExp(-x));
  }

  double _posExp(double x) {
    // Taylor approximation for positive x
    double result = 1.0;
    double term = 1.0;
    for (int i = 1; i <= 20; i++) {
      term *= x / i;
      result += term;
      if (term < 1e-15) break;
    }
    return result;
  }

  /// 리소스 정리
  void dispose() {
    _session?.release();
    _sessionOptions?.release();
    _session = null;
    _sessionOptions = null;
    _initialized = false;
  }
}
