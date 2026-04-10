import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'doc_aligner_service.dart';
import 'document_scanner_service.dart';

/// 딥러닝 학습 데이터 수집 서비스
/// 촬영 시 자동으로:
/// 1) 카메라 Y plane → 256×256 PNG 저장 (모델 입력과 동일)
/// 2) 고해상도 이미지에서 DocAligner로 정확한 좌표 감지 → 라벨 JSON 저장
class TrainingDataService {
  TrainingDataService._();
  static final TrainingDataService instance = TrainingDataService._();

  String? _dataDir;
  bool _enabled = false;
  int _count = 0;

  bool get enabled => _enabled;
  int get count => _count;

  /// 초기화: 설정에서 수집 모드 상태 로드
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('trainingDataMode') ?? false;
    await _ensureDir();
    await _updateCount();
  }

  /// 수집 모드 토글
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('trainingDataMode', value);
  }

  Future<String> _ensureDir() async {
    if (_dataDir != null) return _dataDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _dataDir = '${appDir.path}${Platform.pathSeparator}WiScanner${Platform.pathSeparator}training_data';
    final dir = Directory(_dataDir!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _dataDir!;
  }

  Future<void> _updateCount() async {
    final dir = Directory(await _ensureDir());
    if (!await dir.exists()) { _count = 0; return; }
    final pngFiles = await dir.list()
        .where((f) => f.path.endsWith('.png'))
        .length;
    _count = pngFiles;
  }

  /// 촬영 시 호출: Y plane + 고해상도 이미지에서 라벨 자동 생성
  /// [yBytes]: 카메라 Y plane 원본
  /// [srcWidth], [srcHeight]: Y plane 크기
  /// [bytesPerRow]: Y plane 바이트/행
  /// [highResImagePath]: 촬영된 고해상도 이미지 경로
  /// [needsRotation]: 회전 필요 여부
  /// [sensorOrientation]: 센서 방향
  Future<void> collectData({
    required Uint8List yBytes,
    required int srcWidth,
    required int srcHeight,
    required int bytesPerRow,
    required String highResImagePath,
    required bool needsRotation,
    required int sensorOrientation,
  }) async {
    if (!_enabled) return;

    try {
      final dir = await _ensureDir();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final baseName = 'td_$timestamp';

      // 1) Y plane → 256×256 PNG (모델 입력과 동일한 방식)
      const inputSize = 256;
      final int yLen = yBytes.length;

      // Y plane → 원본 크기 img.Image
      final yImage = img.Image(width: srcWidth, height: srcHeight);
      for (int y = 0; y < srcHeight; y++) {
        final rowStart = y * bytesPerRow;
        for (int x = 0; x < srcWidth; x++) {
          final idx = rowStart + x;
          final v = (idx < yLen) ? yBytes[idx] : 0;
          yImage.setPixelRgb(x, y, v, v, v);
        }
      }

      // CameraPreview와 동일하게 회전
      img.Image portrait;
      if (needsRotation && sensorOrientation == 90) {
        portrait = img.copyRotate(yImage, angle: 90);
      } else if (needsRotation && sensorOrientation == 270) {
        portrait = img.copyRotate(yImage, angle: -90);
      } else {
        portrait = yImage;
      }

      // 256×256으로 리사이즈 (모델 입력과 동일)
      final inputImage = img.copyResize(portrait,
          width: inputSize, height: inputSize,
          interpolation: img.Interpolation.linear);

      final pngPath = '$dir${Platform.pathSeparator}$baseName.png';
      File(pngPath).writeAsBytesSync(img.encodePng(inputImage));

      // 2) 고해상도 이미지에서 DocAligner로 정확한 좌표 감지
      final highResBytes = await File(highResImagePath).readAsBytes();
      final corners = await DocAlignerService.instance.detectCorners(highResBytes);

      // 고해상도 이미지 크기
      final decoded = img.decodeImage(highResBytes);
      if (decoded == null) return;
      final origW = decoded.width.toDouble();
      final origH = decoded.height.toDouble();

      // 좌표를 정규화 (0~1)
      List<double> normalizedCorners;
      if (corners != null && corners.length == 4) {
        normalizedCorners = [];
        for (final c in corners) {
          normalizedCorners.add((c.dx / origW).clamp(0.0, 1.0));
          normalizedCorners.add((c.dy / origH).clamp(0.0, 1.0));
        }
      } else {
        // DocAligner 실패 시 OpenCV fallback
        final cvCorners = await DocumentScannerService.instance
            .detectDocumentCorners(highResImagePath);
        normalizedCorners = [];
        for (final c in cvCorners) {
          normalizedCorners.add(c.dx.clamp(0.0, 1.0));
          normalizedCorners.add(c.dy.clamp(0.0, 1.0));
        }
      }

      // 3) 라벨 JSON 저장
      final labelPath = '$dir${Platform.pathSeparator}$baseName.json';
      final json = '{"image":"$baseName.png",'
          '"corners":[${normalizedCorners.map((v) => v.toStringAsFixed(6)).join(",")}],'
          '"src_width":$srcWidth,"src_height":$srcHeight,'
          '"rotation":$sensorOrientation,"needs_rotation":$needsRotation,'
          '"high_res":"${highResImagePath.split(Platform.pathSeparator).last}"}';
      File(labelPath).writeAsStringSync(json);

      _count++;
      debugPrint('[수집] 데이터 저장 완료: $baseName (총 $_count개)');
    } catch (e) {
      debugPrint('[수집] 데이터 저장 실패: $e');
    }
  }

  /// 수집된 데이터 수
  Future<int> getCount() async {
    await _updateCount();
    return _count;
  }

  /// 데이터 디렉토리 경로
  Future<String> getDataPath() async {
    return await _ensureDir();
  }

  /// 수집 데이터 전체 삭제
  Future<void> clearData() async {
    final dir = Directory(await _ensureDir());
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
    _count = 0;
  }
}
