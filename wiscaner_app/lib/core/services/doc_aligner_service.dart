import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'document_scanner_service.dart';

/// DocAligner(ONNX) 기반 문서/책 4꼭짓점 감지 서비스
/// 모델: doc_aligner_book_v2.onnx — 바인더 노트 포함 합성 데이터 7,000장으로 fine-tuned
/// 입력: [1, 3, 256, 256] float32 (RGB, NCHW, 0~1 정규화)
/// 출력: points [1, 8] (TL/TR/BR/BL x,y 정규화 좌표), has_obj [1, 1] (문서 확률)

/// DocAligner 감지 결과 (코너 + 신뢰도)
class DocAlignerResult {
  final List<Offset> corners; // [TL, TR, BR, BL] 정규화 좌표 (0~1)
  final double confidence;    // has_obj 값 (0~1)
  const DocAlignerResult(this.corners, this.confidence);
}

class DocAlignerService {
  DocAlignerService._();
  static final DocAlignerService instance = DocAlignerService._();

  OrtSession? _session;
  OrtSessionOptions? _sessionOptions;
  bool _initialized = false;

  static const String _modelAsset =
      'assets/models/doc_aligner_book_v2.onnx';
  static const int _inputSize = 256;
  static const double _hasObjThreshold = 0.6;

  /// 모델 초기화 (첫 사용 시 자동 호출)
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      OrtEnv.instance.init();
      final cores = Platform.numberOfProcessors;
      final threads = (cores ~/ 2).clamp(1, 4);
      _sessionOptions = OrtSessionOptions()
        ..setInterOpNumThreads(threads)
        ..setIntraOpNumThreads(threads)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

      final rawAsset = await rootBundle.load(_modelAsset);
      final bytes = rawAsset.buffer.asUint8List();
      _session = OrtSession.fromBuffer(bytes, _sessionOptions!);
      debugPrint('[DocAligner] 모델 로드 완료 (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)');
    } catch (e) {
      debugPrint('[DocAligner] 모델 로드 실패: $e');
    }
  }

  /// 이미지 bytes(JPEG/PNG)에서 4꼭짓점 감지
  /// 반환: [TL, TR, BR, BL] 픽셀 좌표, 감지 실패 시 null
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async {
    if (!_initialized) await init();
    if (_session == null) return null;

    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;
      final origW = decoded.width.toDouble();
      final origH = decoded.height.toDouble();

      final resized = img.copyResize(decoded,
          width: _inputSize,
          height: _inputSize,
          interpolation: img.Interpolation.linear);

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

      final inputTensor = OrtValueTensor.createTensorWithDataList(
          inputData, [1, 3, _inputSize, _inputSize]);
      final runOptions = OrtRunOptions();
      final outputs = await _session!.runAsync(
          runOptions, {'img': inputTensor});
      inputTensor.release();
      runOptions.release();

      if (outputs == null) return null;

      final hasObjVal = outputs[1]?.value;
      final hasObj = hasObjVal is List
          ? ((hasObjVal[0] is List) ? (hasObjVal[0][0] as double) : (hasObjVal[0] as double))
          : 0.0;

      for (final o in outputs) { o?.release(); }

      if (hasObj < _hasObjThreshold) return null;

      final pointsVal = outputs[0]?.value;
      List<double> points;
      if (pointsVal is List) {
        final inner = pointsVal[0];
        if (inner is List) {
          points = inner.map((v) => (v as num).toDouble()).toList();
        } else {
          points = [for (final v in pointsVal) (v as num).toDouble()];
        }
      } else {
        return null;
      }

      final corners = <Offset>[];
      for (int i = 0; i < 4; i++) {
        corners.add(Offset(points[i * 2] * origW, points[i * 2 + 1] * origH));
      }

      return corners;
    } catch (e, st) {
      debugPrint('[DocAligner] 추론 오류: $e\n$st');
      return null;
    }
  }

  /// 카메라 Y plane에서 4꼭짓점 감지 (실시간 자동 스캔용)
  /// detectCorners(파일용)와 동일한 추론 경로 사용 — 회전/채널 문제 원천 제거
  Future<DocAlignerResult?> detectCornersFromYPlane(
    Uint8List yBytes, int srcWidth, int srcHeight, int bytesPerRow,
    {bool needsRotation = false, int sensorOrientation = 90}
  ) async {
    if (!_initialized) await init();
    if (_session == null) return null;

    try {
      // Y plane에서 직접 256x256 + 회전을 한 번에 수행 (고속)
      // img.Image/copyRotate/copyResize 없이 직접 샘플링
      const planeSize = _inputSize * _inputSize;
      final inputData = Float32List(planeSize * 3);

      // portrait 크기 결정
      final int portW, portH;
      if (needsRotation) {
        portW = srcHeight; // 1080
        portH = srcWidth;  // 1920
      } else {
        portW = srcWidth;
        portH = srcHeight;
      }
      final double scaleX = portW / _inputSize;
      final double scaleY = portH / _inputSize;
      final int yLen = yBytes.length;

      for (int oy = 0; oy < _inputSize; oy++) {
        final int portY = (oy * scaleY).toInt().clamp(0, portH - 1);
        for (int ox = 0; ox < _inputSize; ox++) {
          final int portX = (ox * scaleX).toInt().clamp(0, portW - 1);

          // portrait → landscape 역매핑 (Y plane 좌표)
          int rawX, rawY;
          if (needsRotation && sensorOrientation == 90) {
            // 시계 90도 회전의 역: portrait(px,py) → landscape(py, W-1-px)
            //   여기서 W=portW=srcHeight
            rawX = portY;
            rawY = (srcWidth - 1 - portX).clamp(0, srcWidth - 1);
          } else if (needsRotation && sensorOrientation == 270) {
            // 반시계 90도의 역
            rawX = (srcHeight - 1 - portY).clamp(0, srcHeight - 1);
            rawY = portX;
          } else {
            rawX = portX;
            rawY = portY;
          }

          final idx = rawY * bytesPerRow + rawX;
          final val = (idx >= 0 && idx < yLen) ? yBytes[idx] / 255.0 : 0.0;
          final outIdx = oy * _inputSize + ox;
          inputData[outIdx] = val;
        }
      }

      // 그레이스케일 → RGB 3채널 복제
      inputData.setRange(planeSize, planeSize * 2, inputData, 0);
      inputData.setRange(planeSize * 2, planeSize * 3, inputData, 0);

      final inputTensor = OrtValueTensor.createTensorWithDataList(
          inputData, [1, 3, _inputSize, _inputSize]);
      final runOptions = OrtRunOptions();
      final outputs = await _session!.runAsync(
          runOptions, {'img': inputTensor});
      inputTensor.release();
      runOptions.release();

      if (outputs == null) return null;

      final hasObjVal = outputs[1]?.value;
      final hasObj = hasObjVal is List
          ? ((hasObjVal[0] is List) ? (hasObjVal[0][0] as double) : (hasObjVal[0] as double))
          : 0.0;

      if (hasObj < _hasObjThreshold) {
        for (final o in outputs) { o?.release(); }
        return null;
      }

      final pointsVal = outputs[0]?.value;
      List<double> points;
      if (pointsVal is List) {
        final inner = pointsVal[0];
        if (inner is List) {
          points = inner.map((v) => (v as num).toDouble()).toList();
        } else {
          points = [for (final v in pointsVal) (v as num).toDouble()];
        }
      } else {
        for (final o in outputs) { o?.release(); }
        return null;
      }

      for (final o in outputs) { o?.release(); }

      // 4) 모델 출력 = portrait 이미지 기준 정규화 좌표 = CameraPreview 좌표
      //    detectCorners와 동일 경로이므로 추가 변환 불필요
      final corners = <Offset>[];
      for (int i = 0; i < 4; i++) {
        corners.add(Offset(
          points[i * 2].clamp(0.0, 1.0),
          points[i * 2 + 1].clamp(0.0, 1.0),
        ));
      }

      return DocAlignerResult(corners, hasObj);
    } catch (e) {
      debugPrint('[DocAligner] Y plane 추론 오류: $e');
      return null;
    }
  }

  void dispose() {
    _session?.release();
    _sessionOptions?.release();
    _session = null;
    _sessionOptions = null;
    _initialized = false;
    OrtEnv.instance.release();
  }
}
