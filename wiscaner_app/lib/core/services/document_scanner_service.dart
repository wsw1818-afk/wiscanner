import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dartcv4/dartcv.dart' as cv;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'doc_aligner_service.dart';
import 'dual_page_detector_service.dart';

/// 스캔 필터 종류
enum ScanFilter {
  original,  // 원본
  document,  // 문서 모드 (흑백 이진화)
  grayscale, // 흑백
  bright,    // 밝게 + 대비 강화
  highContrast, // 높은 대비
}

/// 표준 용지 크기 (mm)
enum PaperSize {
  a4(210, 297, 'A4'),
  a5(148, 210, 'A5'),
  b5(176, 250, 'B5'),
  letter(216, 279, 'Letter'),
  legal(216, 356, 'Legal'),
  businessCard(85, 55, '명함'),
  unknown(0, 0, '알 수 없음');

  final double widthMm;
  final double heightMm;
  final String label;

  const PaperSize(this.widthMm, this.heightMm, this.label);

  double get aspectRatio =>
      widthMm > 0 ? widthMm / heightMm : 1.0;

  @override
  String toString() => '$label (${widthMm.toInt()}x${heightMm.toInt()}mm)';
}

/// 문서 크기 측정 결과
class DocumentSize {
  final PaperSize detectedSize;
  final double widthMm;
  final double heightMm;
  final double confidence;

  DocumentSize({
    required this.detectedSize,
    required this.widthMm,
    required this.heightMm,
    required this.confidence,
  });

  @override
  String toString() {
    if (detectedSize == PaperSize.unknown) {
      return '${widthMm.toInt()}x${heightMm.toInt()}mm';
    }
    return confidence > 0.9
        ? detectedSize.toString()
        : '$detectedSize (약 ${widthMm.toInt()}x${heightMm.toInt()}mm)';
  }
}

/// 스캔 결과
class ScanResult {
  final String imagePath;
  final List<Offset> corners;
  final int originalWidth;
  final int originalHeight;

  ScanResult({
    required this.imagePath,
    required this.corners,
    required this.originalWidth,
    required this.originalHeight,
  });
}

/// 양면 분할 결과
class DualPageSplitResult {
  final int pageCount;
  final List<String> paths;
  final double? spineX;
  final double? confidence;

  DualPageSplitResult({
    required this.pageCount,
    required this.paths,
    this.spineX,
    this.confidence,
  });
}

/// 문서 스캔 서비스 — OpenCV (dartcv4) 기반
/// Phase 1: Isolate 분리, 적응형 파라미터
/// Phase 2: Canny + findContours + warpPerspective
/// Phase 3: 그림자 제거, 화이트밸런스, 곡률 보정, 손가락 감지
class DocumentScannerService {
  DocumentScannerService._();
  static final DocumentScannerService instance = DocumentScannerService._();

  String? _scanCacheDir;

  /// OpenCV 사용 가능 여부 (플랫폼 체크)
  bool get _useOpenCV {
    // OpenCV는 Android/Windows/iOS/Linux/macOS 지원
    return Platform.isAndroid || Platform.isWindows || Platform.isIOS ||
           Platform.isLinux || Platform.isMacOS;
  }

  Future<String> get scanCacheDirectory async {
    if (_scanCacheDir != null) return _scanCacheDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _scanCacheDir =
        '${appDir.path}${Platform.pathSeparator}WiScanner${Platform.pathSeparator}scan_cache';
    final dir = Directory(_scanCacheDir!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _scanCacheDir!;
  }

  Future<String> get scanSaveDirectory async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(
        '${appDir.path}${Platform.pathSeparator}WiScanner${Platform.pathSeparator}scans');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  // ─── Phase 2: OpenCV 기반 문서 감지 ───

  /// 이미지 파일에서 문서 코너 감지
  /// 전략 순서: 1) DocAligner(ONNX 딥러닝) → 2) OpenCV → 3) fallback
  Future<List<Offset>> detectDocumentCorners(String imagePath) async {
    // ── 전략 1: DocAligner 딥러닝 (최우선) ──────────────────────────────
    try {
      final imageBytes = await File(imagePath).readAsBytes();
      final corners = await DocAlignerService.instance.detectCorners(imageBytes);
      if (corners != null && corners.length == 4) {
        // corners는 픽셀 좌표 → 정규화 좌표로 변환
        final src = cv.imread(imagePath);
        final w = src.cols.toDouble();
        final h = src.rows.toDouble();
        src.dispose();
        final normalized = corners
            .map((p) => Offset(
                  (p.dx / w).clamp(0.0, 1.0),
                  (p.dy / h).clamp(0.0, 1.0),
                ))
            .toList();
        debugPrint('[감지] DocAligner 성공');
        return normalized;
      }
    } catch (e) {
      debugPrint('[DocAligner] 오류: $e');
    }

    // ── 전략 2: OpenCV (fallback) ─────────────────────────────────────
    try {
      if (_useOpenCV) {
        return await _detectCornersOpenCV(imagePath);
      }
      return await _detectCornersFallback(imagePath);
    } catch (e) {
      debugPrint('[OpenCV] 문서 감지 실패, fallback 사용: $e');
      try {
        return await _detectCornersFallback(imagePath);
      } catch (_) {
        return _defaultCorners();
      }
    }
  }

  /// OpenCV 기반 코너 감지
  Future<List<Offset>> _detectCornersOpenCV(String imagePath) async {
    final src = cv.imread(imagePath);
    if (src.isEmpty) return _defaultCorners();

    try {
      final corners = _findDocumentCornersFromMat(src);
      if (corners != null) {
        return corners
            .map((p) => Offset(
                  (p.dx / src.cols).clamp(0.0, 1.0),
                  (p.dy / src.rows).clamp(0.0, 1.0),
                ))
            .toList();
      }
      return _defaultCorners();
    } finally {
      src.dispose();
    }
  }

  /// Mat에서 문서 4코너 찾기
  /// 전략 1: Canny → contour → 가장 큰 사각형 (테스트베드 검증: 이 이미지에서 정확)
  /// 전략 2: Otsu 이진화 → 밝은 blob → approxPolyDP
  /// 전략 3: HoughLinesP → 수평/수직 직선 교차점
  List<Offset>? _findDocumentCornersFromMat(cv.Mat src) {
    final h = src.rows;
    final w = src.cols;

    const maxSize = 640;
    final scale = math.min(maxSize / w.toDouble(), maxSize / h.toDouble());
    cv.Mat work;
    if (scale < 1.0) {
      work = cv.resize(src, ((w * scale).round(), (h * scale).round()));
    } else {
      work = src.clone();
    }

    try {
      final ww = work.cols.toDouble();
      final wh = work.rows.toDouble();

      // 1) 그레이스케일
      final cv.Mat gray;
      if (work.channels > 1) {
        gray = cv.cvtColor(work, cv.COLOR_BGR2GRAY);
      } else {
        gray = work.clone();
      }

      // ── 전략 1: Canny → contour (테스트베드에서 정확도 확인됨) ─────────────
      {
        final result = _cornersFromCanny(gray, ww, wh, scale);
        if (result != null) {
          debugPrint('[감지] 전략1(Canny) 성공: ${result.map((p) => '(${(p.dx/w).toStringAsFixed(2)},${(p.dy/h).toStringAsFixed(2)})').join(' ')}');
          gray.dispose();
          return result;
        }
        debugPrint('[감지] 전략1(Canny) 실패 → 전략2 시도');
      }

      // ── 전략 2: Otsu blob (책 페이지가 배경보다 뚜렷이 밝을 때) ──────────
      {
        final result = _cornersFromLargestBright(gray, ww, wh, scale);
        if (result != null) {
          debugPrint('[감지] 전략2(Otsu-blob) 성공: ${result.map((p) => '(${(p.dx/w).toStringAsFixed(2)},${(p.dy/h).toStringAsFixed(2)})').join(' ')}');
          gray.dispose();
          return result;
        }
        debugPrint('[감지] 전략2(Otsu-blob) 실패 → 전략3 시도');
      }

      // 3) Black Top-Hat + Canny 엣지 (전략 3용 엣지)
      final thSize = ((work.cols * 0.06).toInt() | 1).clamp(15, 51);
      final thKernel = cv.getStructuringElement(cv.MORPH_RECT, (thSize, thSize));
      final blackHat = cv.morphologyEx(gray, cv.MORPH_BLACKHAT, thKernel);
      thKernel.dispose();
      final clahe = cv.createCLAHE(clipLimit: 4.0, tileGridSize: (16, 16));
      final enhanced = clahe.apply(gray);
      final enhancedWithEdges = cv.add(enhanced, blackHat);
      enhanced.dispose();
      blackHat.dispose();
      final blurred = cv.gaussianBlur(enhancedWithEdges, (5, 5), 1.0);
      enhancedWithEdges.dispose();
      final edges = cv.canny(blurred, 30.0, 90.0);
      blurred.dispose();

      // ── 전략 3: HoughLinesP → 직선 교차점 ──────────────────────────────
      final result = _cornersFromHoughLines(edges, gray, ww, wh, scale);
      if (result != null) {
        debugPrint('[감지] 전략3(Hough) 성공: ${result.map((p) => '(${(p.dx/w).toStringAsFixed(2)},${(p.dy/h).toStringAsFixed(2)})').join(' ')}');
        edges.dispose();
        gray.dispose();
        return result;
      }
      debugPrint('[감지] 전략3(Hough) 실패 → null 반환');
      edges.dispose();
      gray.dispose();
      return null;
    } finally {
      if (scale < 1.0) work.dispose();
    }
  }

  /// Canny 엣지 → dilate → contour → 가장 큰 사각형 반환
  /// [테스트베드 검증] 책 페이지가 화면 대부분을 차지하는 경우 정확
  List<Offset>? _cornersFromCanny(
      cv.Mat gray, double ww, double wh, double scale) {
    final blurred = cv.gaussianBlur(gray, (5, 5), 0);
    final edges = cv.canny(blurred, 50.0, 150.0);
    blurred.dispose();

    // 엣지 연결: dilate → close
    final dk = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
    final dilated = cv.dilate(edges, dk, iterations: 1);
    edges.dispose();
    dk.dispose();

    final (contours, hier) = cv.findContours(
        dilated, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
    dilated.dispose();
    hier.dispose();

    if (contours.isEmpty) return null;

    final workArea = ww * wh;
    List<Offset>? bestQuad;
    double bestScore = 0;

    // 면적 상위 10개만 검사
    final sorted = List.generate(contours.length, (i) => i)
      ..sort((a, b) => cv.contourArea(contours[b])
          .compareTo(cv.contourArea(contours[a])));
    final topN = sorted.take(10);

    for (final i in topN) {
      final area = cv.contourArea(contours[i]);
      final ratio = area / workArea;
      if (ratio < 0.10 || ratio > 0.92) continue;

      final perimeter = cv.arcLength(contours[i], true);
      List<Offset>? quad;
      for (final eps in [0.02, 0.04, 0.06, 0.08, 0.10]) {
        final approx = cv.approxPolyDP(contours[i], eps * perimeter, true);
        if (approx.length == 4) {
          final pts = <Offset>[];
          for (int j = 0; j < 4; j++) {
            pts.add(Offset(approx[j].x.toDouble(), approx[j].y.toDouble()));
          }
          if (_isConvexQuad(pts) && _isRectangularEnough(pts, maxAngleRange: 50.0)) {
            quad = _orderCorners(pts);
            break;
          }
        }
      }
      if (quad == null) continue;

      final ys = quad.map((p) => p.dy);
      final xs = quad.map((p) => p.dx);
      final yMin = ys.reduce(math.min);
      final yMax = ys.reduce(math.max);
      final xMin = xs.reduce(math.min);
      final xMax = xs.reduce(math.max);

      // 배경 포함 거부: 상단이 화면 최상단 3% 이내
      if (yMin / wh < 0.03) continue;
      // 너무 작거나(높이 20% 미만) 좁은(너비 15% 미만) 것 제외
      if (yMax - yMin < wh * 0.20) continue;
      if (xMax - xMin < ww * 0.15) continue;

      // 점수: 면적 비율 (클수록 책이 화면을 많이 차지)
      // 내부 밝기 보너스: 책 페이지(밝음) vs 배경(어두움)
      final rx = xMin.toInt().clamp(0, gray.cols - 1);
      final ry = yMin.toInt().clamp(0, gray.rows - 1);
      final rw = (xMax - xMin).toInt().clamp(1, gray.cols - rx);
      final rh = (yMax - yMin).toInt().clamp(1, gray.rows - ry);
      final roi = gray.region(cv.Rect(rx, ry, rw, rh));
      final meanVal = cv.mean(roi).val1;
      roi.dispose();
      final brightnessBonus = (meanVal / 150.0).clamp(0.5, 1.5);
      final score = ratio * brightnessBonus;

      debugPrint('[Canny] contour$i 면적비=${ratio.toStringAsFixed(2)} brightness=${meanVal.toStringAsFixed(0)} score=${score.toStringAsFixed(3)}');

      if (score > bestScore) {
        bestScore = score;
        bestQuad = quad;
      }
    }
    contours.dispose();

    if (bestQuad == null) return null;
    debugPrint('[Canny] 최적 score=${bestScore.toStringAsFixed(3)}');

    if (scale < 1.0) {
      bestQuad = bestQuad.map((p) => Offset(p.dx / scale, p.dy / scale)).toList();
    }
    return bestQuad;
  }

  /// 가장 큰 밝은 연결 영역(책 페이지)을 찾아 4꼭짓점 반환
  /// Otsu 자동 임계값 → 후보 blob들 중 최적 사각형 선택 → approxPolyDP → 4각형
  List<Offset>? _cornersFromLargestBright(
      cv.Mat gray, double ww, double wh, double scale) {
    // Otsu: 이미지 내용에 따라 자동으로 최적 임계값 결정
    final blurred = cv.gaussianBlur(gray, (5, 5), 0);
    final (otsuThresh, binary) = cv.threshold(blurred, 0, 255,
        cv.THRESH_BINARY | cv.THRESH_OTSU);
    blurred.dispose();
    debugPrint('[Otsu] 자동 임계값=$otsuThresh ww=${ww.toInt()} wh=${wh.toInt()}');

    // 모폴로지: 책 내부 텍스트/그림으로 생긴 구멍을 메워 단일 blob으로 만듦
    final kSize = ((ww * 0.04).toInt() | 1).clamp(11, 41);
    final k = cv.getStructuringElement(cv.MORPH_RECT, (kSize, kSize));
    final closed = cv.morphologyEx(binary, cv.MORPH_CLOSE, k, iterations: 3);
    final opened = cv.morphologyEx(closed, cv.MORPH_OPEN, k, iterations: 1);
    k.dispose();
    binary.dispose();
    closed.dispose();

    // 외곽선 찾기 → 후보 blob들 평가
    final (contours, hier) = cv.findContours(
        opened, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
    opened.dispose();
    hier.dispose();

    if (contours.isEmpty) return null;

    final workArea = ww * wh;
    debugPrint('[Otsu] blob 개수=${contours.length}개');

    // 크기 범위(15%~65%)에 드는 모든 후보 blob에서 가장 좋은 사각형 찾기
    // 상한을 0.65로 낮춤: 책+배경이 합쳐진 대형 blob(0.70+) 제외
    List<Offset>? bestQuad;
    double bestScore = 0;

    for (int i = 0; i < contours.length; i++) {
      final area = cv.contourArea(contours[i]);
      final ratio = area / workArea;
      if (ratio < 0.15 || ratio > 0.65) continue;

      // approxPolyDP로 4각형 근사
      final perimeter = cv.arcLength(contours[i], true);
      List<Offset>? quad;
      for (final eps in [0.02, 0.04, 0.06, 0.08, 0.10]) {
        final approx = cv.approxPolyDP(contours[i], eps * perimeter, true);
        if (approx.length == 4) {
          final pts = <Offset>[];
          for (int j = 0; j < 4; j++) {
            pts.add(Offset(approx[j].x.toDouble(), approx[j].y.toDouble()));
          }
          if (_isConvexQuad(pts) && _isRectangularEnough(pts, maxAngleRange: 50.0)) {
            quad = _orderCorners(pts);
            break;
          }
        }
      }
      if (quad == null) continue;

      // 배경 포함 quad 거부: 상단 y가 화면 5% 이내 = 배경 최상단 포함
      final yMin = quad.map((p) => p.dy).reduce(math.min);
      final yMax = quad.map((p) => p.dy).reduce(math.max);
      if (yMin / wh < 0.05) {
        debugPrint('[Otsu] blob$i 거부: yMin=${(yMin/wh).toStringAsFixed(2)} < 0.05 (배경 포함)');
        continue;
      }
      // 기본 유효성: 상단 40% 이내, 하단 60% 이상
      if (yMin / wh > 0.40 || yMax / wh < 0.60) continue;

      // 점수: 면적 비율 + 직사각형도(Hu 불변량 대신 종횡비 활용)
      final qArea = _quadArea(quad);
      final rectScore = qArea / workArea; // 클수록 책이 화면을 많이 차지
      final score = rectScore;
      debugPrint('[Otsu] blob$i 면적비=${ratio.toStringAsFixed(2)} yMin=${(yMin/wh).toStringAsFixed(2)} score=${score.toStringAsFixed(3)}');

      if (score > bestScore) {
        bestScore = score;
        bestQuad = quad;
      }
    }
    contours.dispose();

    if (bestQuad == null) {
      debugPrint('[Otsu] 유효한 사각형 blob 없음');
      return null;
    }

    debugPrint('[Otsu] 최적 blob score=${bestScore.toStringAsFixed(3)}');

    if (scale < 1.0) {
      bestQuad = bestQuad.map((p) => Offset(p.dx / scale, p.dy / scale)).toList();
    }
    return bestQuad;
  }

  /// HoughLinesP로 수평/수직 직선 감지 → 교차점 4개를 꼭짓점으로 반환
  /// [출처: OpenCV HoughLinesP docs + andrewdcampbell Scanner approach]
  List<Offset>? _cornersFromHoughLines(
      cv.Mat edges, cv.Mat gray, double ww, double wh, double scale) {
    // threshold=30, minLength=이미지 너비 15%, maxGap=30 (테스트베드 검증값)
    final minLen = ww * 0.15;
    final lines = cv.HoughLinesP(edges, 1.0, math.pi / 180, 30,
        minLineLength: minLen, maxLineGap: 30.0);

    if (lines.rows == 0) return null;

    // 수평(각도 ±20°) / 수직(각도 70~110°) 분류
    // 각 직선: (x1,y1,x2,y2) = lines.at<int>(i, 0~3)
    final List<(double, double, double, double)> horiz = [];
    final List<(double, double, double, double)> vert = [];

    for (int i = 0; i < lines.rows; i++) {
      final x1 = lines.at<int>(i, 0).toDouble();
      final y1 = lines.at<int>(i, 1).toDouble();
      final x2 = lines.at<int>(i, 2).toDouble();
      final y2 = lines.at<int>(i, 3).toDouble();
      final angle = math.atan2((y2 - y1).abs(), (x2 - x1).abs()) * 180 / math.pi;
      if (angle < 25) {
        horiz.add((x1, y1, x2, y2));
      } else if (angle > 65) {
        vert.add((x1, y1, x2, y2));
      }
    }
    lines.dispose();

    if (horiz.length < 2 || vert.length < 2) return null;

    // 수평선을 y 중간값 기준으로 정렬 → 가장 위(topLine)와 가장 아래(botLine) 선택
    horiz.sort((a, b) => ((a.$2 + a.$4) / 2).compareTo((b.$2 + b.$4) / 2));
    // 수직선을 x 중간값 기준으로 정렬 → 가장 왼쪽(leftLine)과 가장 오른쪽(rightLine)
    vert.sort((a, b) => ((a.$1 + a.$3) / 2).compareTo((b.$1 + b.$3) / 2));

    // 상단/하단은 각각 상위 30% / 하위 30% 중에서 가장 극단적인 것
    final topCandidates = horiz.take((horiz.length * 0.4).ceil().clamp(1, horiz.length)).toList();
    final botCandidates = horiz.reversed.take((horiz.length * 0.4).ceil().clamp(1, horiz.length)).toList();
    final leftCandidates = vert.take((vert.length * 0.4).ceil().clamp(1, vert.length)).toList();
    final rightCandidates = vert.reversed.take((vert.length * 0.4).ceil().clamp(1, vert.length)).toList();

    // 각 그룹에서 y/x 극단값 선 선택
    final topLine = topCandidates.reduce((a, b) => (a.$2 + a.$4) < (b.$2 + b.$4) ? a : b);
    final botLine = botCandidates.reduce((a, b) => (a.$2 + a.$4) > (b.$2 + b.$4) ? a : b);
    final leftLine = leftCandidates.reduce((a, b) => (a.$1 + a.$3) < (b.$1 + b.$3) ? a : b);
    final rightLine = rightCandidates.reduce((a, b) => (a.$1 + a.$3) > (b.$1 + b.$3) ? a : b);

    // ── 화면 경계 Fallback (테스트베드 검증) ────────────────────────────────
    // 책이 화면 상단/하단 밖으로 나간 경우 가상 경계선 사용
    final topMidY = (topLine.$2 + topLine.$4) / 2;
    final botMidY = (botLine.$2 + botLine.$4) / 2;
    final effectiveTopLine = topMidY > wh * 0.30
        ? (0.0, 0.0, ww, 0.0)   // 가상 상단 직선 (y=0)
        : topLine;
    final effectiveBotLine = botMidY < wh * 0.50
        ? (0.0, wh, ww, wh)     // 가상 하단 직선 (y=wh)
        : botLine;

    if (topMidY > wh * 0.30) {
      debugPrint('[Hough] 상단선 없음(y_mid=${topMidY.toInt()} > ${(wh*0.30).toInt()}) → 화면 상단(y=0) 사용');
    }
    if (botMidY < wh * 0.50) {
      debugPrint('[Hough] 하단선 없음(y_mid=${botMidY.toInt()} < ${(wh*0.50).toInt()}) → 화면 하단(y=$wh) 사용');
    }

    // 직선 교차점 계산: ax + by + c = 0 연립방정식
    Offset? intersect((double, double, double, double) l1, (double, double, double, double) l2) {
      final (x1, y1, x2, y2) = l1;
      final (x3, y3, x4, y4) = l2;
      final denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4);
      if (denom.abs() < 1e-6) return null;
      final t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom;
      return Offset(x1 + t * (x2 - x1), y1 + t * (y2 - y1));
    }

    final tl = intersect(effectiveTopLine, leftLine);
    final tr = intersect(effectiveTopLine, rightLine);
    final br = intersect(effectiveBotLine, rightLine);
    final bl = intersect(effectiveBotLine, leftLine);

    if (tl == null || tr == null || br == null || bl == null) return null;

    // 유효 범위 검사: 꼭짓점이 이미지 범위의 ±20% 내에 있어야 함
    final margin = 0.20;
    for (final p in [tl, tr, br, bl]) {
      if (p.dx < -ww * margin || p.dx > ww * (1 + margin)) return null;
      if (p.dy < -wh * margin || p.dy > wh * (1 + margin)) return null;
    }

    // 최소 면적 검사: 이미지 면적의 15% 이상
    final quadArea = _quadArea([tl, tr, br, bl]);
    if (quadArea < ww * wh * 0.15) return null;

    // 직사각형 검사
    final quad = [tl, tr, br, bl];
    if (!_isRectangularEnough(quad, maxAngleRange: 45.0)) return null;

    // 원본 좌표로 변환
    if (scale < 1.0) {
      return [tl, tr, br, bl].map((p) => Offset(p.dx / scale, p.dy / scale)).toList();
    }
    return [tl, tr, br, bl];
  }

  /// 사각형 넓이 계산 (Shoelace 공식)
  double _quadArea(List<Offset> pts) {
    double area = 0;
    final n = pts.length;
    for (int i = 0; i < n; i++) {
      final j = (i + 1) % n;
      area += pts[i].dx * pts[j].dy;
      area -= pts[j].dx * pts[i].dy;
    }
    return area.abs() / 2;
  }

  /// 카메라 Y plane에서 코너 감지 (Phase 2 OpenCV + Phase 1 Isolate)
  Future<List<Offset>> detectCornersFromGrayscale(
    Uint8List yBytes, int srcWidth, int srcHeight, int bytesPerRow,
  ) async {
    try {
      if (_useOpenCV) {
        return await _detectCornersFromYPlaneOpenCV(
          yBytes, srcWidth, srcHeight, bytesPerRow,
        );
      }
      return await _detectCornersFromYPlaneFallback(
        yBytes, srcWidth, srcHeight, bytesPerRow,
      );
    } catch (e) {
      debugPrint('[감지] OpenCV 실패, fallback: $e');
      try {
        return await _detectCornersFromYPlaneFallback(
          yBytes, srcWidth, srcHeight, bytesPerRow,
        );
      } catch (_) {
        return _defaultCorners();
      }
    }
  }

  /// OpenCV 기반 Y plane 코너 감지
  Future<List<Offset>> _detectCornersFromYPlaneOpenCV(
    Uint8List yBytes, int srcWidth, int srcHeight, int bytesPerRow,
  ) async {
    debugPrint('[감지] OpenCV 시작: src=${srcWidth}x$srcHeight');

    // Y plane → Mat (bytesPerRow가 width와 다를 수 있으므로 처리)
    final yList = <int>[];
    for (int y = 0; y < srcHeight; y++) {
      final rowStart = y * bytesPerRow;
      for (int x = 0; x < srcWidth; x++) {
        final idx = rowStart + x;
        yList.add(idx < yBytes.length ? yBytes[idx] : 0);
      }
    }

    cv.Mat yMat = cv.Mat.fromList(
      srcHeight, srcWidth, cv.MatType.CV_8UC1, yList,
    );

    // 센서가 가로(landscape)이고 화면이 세로(portrait)면 90도 회전
    // → OpenCV에 넘기기 전에 미리 회전해야 정확하게 4각형을 찾을 수 있음
    final needsRotation = srcWidth > srcHeight;
    int outWidth = srcWidth;
    int outHeight = srcHeight;
    if (needsRotation) {
      final rotated = cv.rotate(yMat, cv.ROTATE_90_CLOCKWISE);
      yMat.dispose();
      yMat = rotated;
      outWidth = srcHeight;
      outHeight = srcWidth;
    }

    try {
      final corners = _findDocumentCornersFromMat(yMat);
      if (corners != null) {
        final result = corners
            .map((p) => Offset(
                  (p.dx / outWidth).clamp(0.0, 1.0),
                  (p.dy / outHeight).clamp(0.0, 1.0),
                ))
            .toList();
        debugPrint('[감지] OpenCV 성공: ${result.map((c) => "(${c.dx.toStringAsFixed(2)},${c.dy.toStringAsFixed(2)})").join(",")}');
        return result;
      }

      debugPrint('[감지] OpenCV: 문서 감지 실패 → 기본값');
      return _defaultCorners();
    } finally {
      yMat.dispose();
    }
  }

  /// 4개 코너를 좌상→우상→우하→좌하 순서로 정렬
  List<Offset> _orderCorners(List<Offset> pts) {
    // 합(x+y)이 최소 = 좌상, 최대 = 우하
    // 차(y-x)가 최소 = 우상, 최대 = 좌하
    final sorted = List<Offset>.from(pts);
    sorted.sort((a, b) => (a.dx + a.dy).compareTo(b.dx + b.dy));
    final topLeft = sorted.first;
    final bottomRight = sorted.last;

    sorted.sort((a, b) => (a.dy - a.dx).compareTo(b.dy - b.dx));
    final topRight = sorted.first;
    final bottomLeft = sorted.last;

    return [topLeft, topRight, bottomRight, bottomLeft];
  }

  /// 직사각형에 가까운지 내각 범위로 검증
  /// [출처: andrewdcampbell/OpenCV-Document-Scanner, MAX_QUAD_ANGLE_RANGE=40]
  /// 직사각형: 모든 내각 90° → 범위 0 / 왜곡된 사각형: 범위 40° 초과
  bool _isRectangularEnough(List<Offset> pts, {double maxAngleRange = 40.0}) {
    if (pts.length != 4) return false;

    double getAngle(Offset p1, Offset vertex, Offset p3) {
      final v1 = Offset(p1.dx - vertex.dx, p1.dy - vertex.dy);
      final v2 = Offset(p3.dx - vertex.dx, p3.dy - vertex.dy);
      final dot = v1.dx * v2.dx + v1.dy * v2.dy;
      final len1 = math.sqrt(v1.dx * v1.dx + v1.dy * v1.dy);
      final len2 = math.sqrt(v2.dx * v2.dx + v2.dy * v2.dy);
      if (len1 < 1e-6 || len2 < 1e-6) return 90.0;
      return math.acos((dot / (len1 * len2)).clamp(-1.0, 1.0)) * 180 / math.pi;
    }

    // _orderCorners 기준: [0]=좌상, [1]=우상, [2]=우하, [3]=좌하
    final tl = pts[0], tr = pts[1], br = pts[2], bl = pts[3];
    final angles = [
      getAngle(bl, tl, tr), // 좌상단 내각
      getAngle(tl, tr, br), // 우상단 내각
      getAngle(tr, br, bl), // 우하단 내각
      getAngle(br, bl, tl), // 좌하단 내각
    ];

    final minA = angles.reduce(math.min);
    final maxA = angles.reduce(math.max);
    return (maxA - minA) <= maxAngleRange;
  }

  /// 유효한 사각형인지 확인
  /// 1) 꼭짓점 중복 없어야 함 (삼각형 오감지 제거)
  /// 2) 볼록이거나 오목 1개까지 허용 (책 접힘 대응)
  bool _isConvexQuad(List<Offset> pts) {
    if (pts.length != 4) return false;

    // 꼭짓점 중복 검사: 두 점이 5px 이내로 가까우면 삼각형 → 제거
    // 로그에서 (0.74,0.26),(0.74,0.26)처럼 동일 좌표가 나타나는 오감지 방지
    for (int i = 0; i < 4; i++) {
      for (int j = i + 1; j < 4; j++) {
        if ((pts[i] - pts[j]).distance < 5.0) return false;
      }
    }

    bool? positive;
    int concaveCount = 0;
    for (int i = 0; i < 4; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % 4];
      final c = pts[(i + 2) % 4];
      final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
      if (cross.abs() < 1e-6) continue;
      if (positive == null) {
        positive = cross > 0;
      } else if ((cross > 0) != positive) {
        concaveCount++;
      }
    }
    return concaveCount <= 1;
  }

  List<Offset> _defaultCorners() {
    return const [
      Offset(0.05, 0.05),
      Offset(0.95, 0.05),
      Offset(0.95, 0.95),
      Offset(0.05, 0.95),
    ];
  }

  // ─── 순수 Dart Fallback (OpenCV 불가 시) ───

  Future<List<Offset>> _detectCornersFallback(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) return _defaultCorners();

    final scales = [512, 384, 256];
    for (final maxSize in scales) {
      final scale = math.min(
        maxSize / original.width.toDouble(),
        maxSize / original.height.toDouble(),
      );
      final workImg = scale < 1.0
          ? img.copyResize(original,
              width: (original.width * scale).round(),
              height: (original.height * scale).round())
          : original;

      final gray = img.grayscale(workImg);
      for (final blurRadius in [11, 7]) {
        final blurred = img.gaussianBlur(gray, radius: blurRadius);
        final edges = _detectEdgesDart(blurred);
        final corners = _findLargestQuadDart(edges, workImg.width, workImg.height);

        if (corners != null) {
          final area = _quadArea(corners);
          final imgArea = workImg.width * workImg.height;
          if (area < imgArea * 0.08) continue;
          if (area > imgArea * 0.85) continue;
          if (!_isConvexQuad(corners)) continue;

          return corners
              .map((p) => Offset(
                    (p.dx / workImg.width).clamp(0.0, 1.0),
                    (p.dy / workImg.height).clamp(0.0, 1.0),
                  ))
              .toList();
        }
      }
    }
    return _defaultCorners();
  }

  Future<List<Offset>> _detectCornersFromYPlaneFallback(
    Uint8List yBytes, int srcWidth, int srcHeight, int bytesPerRow,
  ) async {
    final scales = [512, 384];
    for (final maxSize in scales) {
      final s = math.min(
        maxSize / srcWidth.toDouble(),
        maxSize / srcHeight.toDouble(),
      );
      final effectiveS = s < 1.0 ? s : 1.0;
      final workW = (srcWidth * effectiveS).round();
      final workH = (srcHeight * effectiveS).round();

      final gray = img.Image(width: workW, height: workH, numChannels: 1);
      for (int y = 0; y < workH; y++) {
        final srcY = (y / effectiveS).round().clamp(0, srcHeight - 1);
        for (int x = 0; x < workW; x++) {
          final srcX = (x / effectiveS).round().clamp(0, srcWidth - 1);
          final idx = srcY * bytesPerRow + srcX;
          final v = idx < yBytes.length ? yBytes[idx] : 0;
          gray.setPixelRgb(x, y, v, v, v);
        }
      }

      for (final blurRadius in [11, 7]) {
        final blurred = img.gaussianBlur(gray, radius: blurRadius);
        final edges = _detectEdgesDart(blurred);
        final corners = _findLargestQuadDart(edges, workW, workH);

        if (corners != null) {
          final area = _quadArea(corners);
          final areaRatio = area / (workW * workH);
          if (areaRatio < 0.08 || areaRatio > 0.85) continue;
          if (!_isConvexQuad(corners)) continue;

          return corners
              .map((p) => Offset(
                  (p.dx / workW).clamp(0.0, 1.0),
                  (p.dy / workH).clamp(0.0, 1.0),
              ))
              .toList();
        }
      }
    }
    return _defaultCorners();
  }

  /// Sobel + NMS 엣지 감지 (Phase 1: Canny NMS 추가)
  img.Image _detectEdgesDart(img.Image src) {
    final w = src.width;
    final h = src.height;
    final magnitude = List.filled(w * h, 0.0);
    final direction = List.filled(w * h, 0.0);

    // Sobel + 방향 계산
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final gx = -_lum(src, x - 1, y - 1) - 2 * _lum(src, x - 1, y) -
            _lum(src, x - 1, y + 1) + _lum(src, x + 1, y - 1) +
            2 * _lum(src, x + 1, y) + _lum(src, x + 1, y + 1);
        final gy = -_lum(src, x - 1, y - 1) - 2 * _lum(src, x, y - 1) -
            _lum(src, x + 1, y - 1) + _lum(src, x - 1, y + 1) +
            2 * _lum(src, x, y + 1) + _lum(src, x + 1, y + 1);

        magnitude[y * w + x] = math.sqrt(gx * gx + gy * gy);
        direction[y * w + x] = math.atan2(gy.toDouble(), gx.toDouble());
      }
    }

    // Non-Maximum Suppression (Phase 1 개선)
    final nms = List.filled(w * h, 0.0);
    for (int y = 2; y < h - 2; y++) {
      for (int x = 2; x < w - 2; x++) {
        final mag = magnitude[y * w + x];
        if (mag < 10) continue;

        final angle = direction[y * w + x];
        double n1 = 0, n2 = 0;

        // 4방향 이웃 비교
        if (angle.abs() < 0.3927 || angle.abs() > 2.7489) {
          n1 = magnitude[y * w + x - 1];
          n2 = magnitude[y * w + x + 1];
        } else if (angle > 0.3927 && angle < 1.1781) {
          n1 = magnitude[(y - 1) * w + x + 1];
          n2 = magnitude[(y + 1) * w + x - 1];
        } else if (angle > 1.1781 && angle < 1.9635) {
          n1 = magnitude[(y - 1) * w + x];
          n2 = magnitude[(y + 1) * w + x];
        } else {
          n1 = magnitude[(y - 1) * w + x - 1];
          n2 = magnitude[(y + 1) * w + x + 1];
        }

        nms[y * w + x] = (mag >= n1 && mag >= n2) ? mag : 0;
      }
    }

    // Hysteresis Thresholding
    final maxMag = nms.reduce(math.max);
    final highThresh = maxMag * 0.15;
    final lowThresh = highThresh * 0.4;

    final result = img.Image(width: w, height: h, numChannels: 1);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final val = nms[y * w + x];
        final v = val > highThresh ? 255 : (val > lowThresh ? 128 : 0);
        result.setPixelRgb(x, y, v, v, v);
      }
    }

    return result;
  }

  int _lum(img.Image src, int x, int y) => src.getPixel(x, y).r.toInt();

  /// Otsu 임계값 계산
  int _computeOtsuThreshold(img.Image edges) {
    final histogram = List.filled(256, 0);
    final totalPixels = edges.width * edges.height;
    for (int y = 0; y < edges.height; y++) {
      for (int x = 0; x < edges.width; x++) {
        histogram[edges.getPixel(x, y).r.toInt()]++;
      }
    }

    double sumAll = 0;
    for (int i = 0; i < 256; i++) sumAll += i * histogram[i];

    double sumB = 0;
    int wB = 0;
    double maxVariance = 0;
    int bestThreshold = 80;

    for (int t = 0; t < 256; t++) {
      wB += histogram[t];
      if (wB == 0) continue;
      final wF = totalPixels - wB;
      if (wF == 0) break;

      sumB += t * histogram[t];
      final meanB = sumB / wB;
      final meanF = (sumAll - sumB) / wF;
      final variance = wB.toDouble() * wF.toDouble() * (meanB - meanF) * (meanB - meanF);

      if (variance > maxVariance) {
        maxVariance = variance;
        bestThreshold = t;
      }
    }

    return bestThreshold.clamp(15, 200);
  }

  /// Fallback: 프로젝션 기반 사각형 찾기
  List<Offset>? _findLargestQuadDart(img.Image edges, int w, int h) {
    final threshold = _computeOtsuThreshold(edges);

    final rowProfile = List.filled(h, 0);
    final colProfile = List.filled(w, 0);

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final val = edges.getPixel(x, y).r.toInt();
        if (val > threshold) {
          rowProfile[y] += val;
          colProfile[x] += val;
        }
      }
    }

    final smoothedRow = _smoothProfile(rowProfile, 15);
    final smoothedCol = _smoothProfile(colProfile, 15);

    final marginY = (h * 0.08).round().clamp(5, 50);
    final marginX = (w * 0.08).round().clamp(5, 50);

    final topY = _findEdgeFromCenter(smoothedRow, h ~/ 2, marginY, h ~/ 2, true);
    final bottomY = _findEdgeFromCenter(smoothedRow, h ~/ 2, h ~/ 2, h - marginY, false);
    final leftX = _findEdgeFromCenter(smoothedCol, w ~/ 2, marginX, w ~/ 2, true);
    final rightX = _findEdgeFromCenter(smoothedCol, w ~/ 2, w ~/ 2, w - marginX, false);

    if (topY == null || bottomY == null || leftX == null || rightX == null) return null;

    final area = (rightX - leftX).abs() * (bottomY - topY).abs();
    if (area < w * h * 0.05) return null;

    return [
      Offset(leftX.toDouble(), topY.toDouble()),
      Offset(rightX.toDouble(), topY.toDouble()),
      Offset(rightX.toDouble(), bottomY.toDouble()),
      Offset(leftX.toDouble(), bottomY.toDouble()),
    ];
  }

  List<int> _smoothProfile(List<int> profile, int kernelSize) {
    final result = List.filled(profile.length, 0);
    final half = kernelSize ~/ 2;
    for (int i = 0; i < profile.length; i++) {
      int sum = 0, count = 0;
      for (int j = i - half; j <= i + half; j++) {
        if (j >= 0 && j < profile.length) { sum += profile[j]; count++; }
      }
      result[i] = count > 0 ? sum ~/ count : 0;
    }
    return result;
  }

  int? _findEdgeFromCenter(List<int> profile, int center, int start, int end, bool searchOutward) {
    if (start >= end || end - start < 5) return null;
    int maxVal = 0;
    for (int i = start; i < end; i++) {
      if (profile[i] > maxVal) maxVal = profile[i];
    }
    if (maxVal <= 0) return null;
    final minDrop = (maxVal * 0.05).round();
    const windowSize = 5;
    int bestPos = -1, bestDrop = 0;

    if (searchOutward) {
      for (int i = start; i < center - windowSize; i++) {
        final rise = profile[i + windowSize] - profile[i];
        if (rise > bestDrop && rise > minDrop) { bestDrop = rise; bestPos = i + windowSize ~/ 2; }
      }
    } else {
      for (int i = center; i < end - windowSize; i++) {
        final drop = profile[i] - profile[i + windowSize];
        if (drop > bestDrop && drop > minDrop) { bestDrop = drop; bestPos = i + windowSize ~/ 2; }
      }
    }
    return bestPos > 0 ? bestPos : null;
  }

  // ─── 다중 문서 감지 ───

  Future<List<List<Offset>>> detectMultipleDocuments(
    String imagePath, { int maxDocuments = 4 }
  ) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final original = img.decodeImage(bytes);
      if (original == null) return [];

      final maxSize = 512;
      final scale = math.min(
        maxSize / original.width.toDouble(),
        maxSize / original.height.toDouble(),
      );
      final workImg = scale < 1.0
          ? img.copyResize(original,
              width: (original.width * scale).round(),
              height: (original.height * scale).round())
          : original;

      final gray = img.grayscale(workImg);
      final blurred = img.gaussianBlur(gray, radius: 11);
      var edges = _detectEdgesDart(blurred);

      final results = <List<Offset>>[];

      for (int i = 0; i < maxDocuments; i++) {
        final quad = _findLargestQuadDart(edges, workImg.width, workImg.height);
        if (quad == null) break;

        results.add(quad
            .map((p) => Offset(p.dx / workImg.width, p.dy / workImg.height))
            .toList());

        edges = _maskQuadRegion(edges, quad);
      }

      return results;
    } catch (e) {
      debugPrint('다중 문서 감지 실패: $e');
      return [];
    }
  }

  img.Image _maskQuadRegion(img.Image edges, List<Offset> quad) {
    final result = img.Image.from(edges);
    final minX = quad.map((p) => p.dx).reduce(math.min).toInt();
    final maxX = quad.map((p) => p.dx).reduce(math.max).toInt();
    final minY = quad.map((p) => p.dy).reduce(math.min).toInt();
    final maxY = quad.map((p) => p.dy).reduce(math.max).toInt();

    for (int y = math.max(0, minY - 10); y <= math.min(result.height - 1, maxY + 10); y++) {
      for (int x = math.max(0, minX - 10); x <= math.min(result.width - 1, maxX + 10); x++) {
        result.setPixelRgb(x, y, 0, 0, 0);
      }
    }
    return result;
  }

  // ─── Phase 2: OpenCV 원근 보정 ───

  Future<String?> applyPerspectiveTransform({
    required String imagePath,
    required List<Offset> corners,
    int? outputWidth,
    int? outputHeight,
  }) async {
    try {
      if (_useOpenCV) {
        return await _warpPerspectiveOpenCV(
          imagePath, corners, outputWidth, outputHeight,
        );
      }
      return await _warpPerspectiveFallback(
        imagePath, corners, outputWidth, outputHeight,
      );
    } catch (e) {
      debugPrint('[OpenCV] 원근 보정 실패, fallback: $e');
      try {
        return await _warpPerspectiveFallback(
          imagePath, corners, outputWidth, outputHeight,
        );
      } catch (_) {
        return null;
      }
    }
  }

  /// 양면 펼침 감지 + 분할
  Future<DualPageSplitResult> detectAndSplitDualPage(String imagePath) async {
    try {
      final imageBytes = await File(imagePath).readAsBytes();
      final dualResult = await DualPageDetectorService.instance.detect(imageBytes);
      if (dualResult == null) {
        debugPrint('[양면분리] DualPageDetector 감지 실패 → 단면 처리');
        return DualPageSplitResult(pageCount: 1, paths: [imagePath]);
      }

      debugPrint('[양면분리] $dualResult');

      if (dualResult.pageCount != 2 || dualResult.confidence < 0.7) {
        debugPrint('[양면분리] 단면 판정 (pages=${dualResult.pageCount}, conf=${dualResult.confidence.toStringAsFixed(2)})');
        return DualPageSplitResult(pageCount: 1, paths: [imagePath]);
      }

      final paths = <String>[];

      if (dualResult.leftCorners.length == 4) {
        final leftPath = await applyPerspectiveTransform(
          imagePath: imagePath,
          corners: dualResult.leftCorners,
        );
        if (leftPath != null) {
          paths.add(leftPath);
          debugPrint('[양면분리] 왼쪽 페이지 보정 완료');
        }
      }

      if (dualResult.rightCorners.length == 4) {
        final rightPath = await applyPerspectiveTransform(
          imagePath: imagePath,
          corners: dualResult.rightCorners,
        );
        if (rightPath != null) {
          paths.add(rightPath);
          debugPrint('[양면분리] 오른쪽 페이지 보정 완료');
        }
      }

      if (paths.isEmpty) {
        debugPrint('[양면분리] 보정 실패 → 단순 분할 fallback');
        return await _splitBySpineX(imagePath, dualResult.spineX);
      }

      return DualPageSplitResult(
        pageCount: paths.length,
        paths: paths,
        spineX: dualResult.spineX,
        confidence: dualResult.confidence,
      );
    } catch (e) {
      debugPrint('[양면분리] 오류: $e');
      return DualPageSplitResult(pageCount: 1, paths: [imagePath]);
    }
  }

  /// spineX 기반 단순 좌/우 분할 (fallback)
  Future<DualPageSplitResult> _splitBySpineX(String imagePath, double spineX) async {
    try {
      final src = cv.imread(imagePath);
      if (src.isEmpty) return DualPageSplitResult(pageCount: 1, paths: [imagePath]);

      final w = src.cols;
      final h = src.rows;
      final splitX = (w * spineX).round().clamp(1, w - 1);
      final cacheDir = await scanCacheDirectory;
      final ts = DateTime.now().millisecondsSinceEpoch;
      final paths = <String>[];

      final leftRoi = cv.Mat.fromMat(src, roi: cv.Rect(0, 0, splitX, h));
      final leftPath = '$cacheDir${Platform.pathSeparator}dual_left_$ts.png';
      cv.imwrite(leftPath, leftRoi);
      leftRoi.dispose();
      paths.add(leftPath);

      final rightRoi = cv.Mat.fromMat(src, roi: cv.Rect(splitX, 0, w - splitX, h));
      final rightPath = '$cacheDir${Platform.pathSeparator}dual_right_$ts.png';
      cv.imwrite(rightPath, rightRoi);
      rightRoi.dispose();
      paths.add(rightPath);

      src.dispose();
      return DualPageSplitResult(pageCount: 2, paths: paths, spineX: spineX);
    } catch (e) {
      debugPrint('[양면분리] spine 분할 실패: $e');
      return DualPageSplitResult(pageCount: 1, paths: [imagePath]);
    }
  }

  /// OpenCV warpPerspective
  Future<String?> _warpPerspectiveOpenCV(
    String imagePath, List<Offset> corners,
    int? outputWidth, int? outputHeight,
  ) async {
    final src = cv.imread(imagePath);
    if (src.isEmpty) return null;

    try {
      final w = src.cols.toDouble();
      final h = src.rows.toDouble();

      // 정규화 좌표 → 픽셀 좌표
      final srcPts = corners.map((c) => Offset(c.dx * w, c.dy * h)).toList();

      // 출력 크기 결정 (최소 2000px 보장 — 필기 배경으로 충분한 해상도)
      final topWidth = (srcPts[1] - srcPts[0]).distance;
      final bottomWidth = (srcPts[2] - srcPts[3]).distance;
      final leftHeight = (srcPts[3] - srcPts[0]).distance;
      final rightHeight = (srcPts[2] - srcPts[1]).distance;
      var outW = outputWidth ?? math.max(topWidth, bottomWidth).round();
      var outH = outputHeight ?? math.max(leftHeight, rightHeight).round();
      // 최소 해상도 보장: 긴 변이 2000px 미만이면 비율 유지하며 스케일업
      const minLongSide = 2000;
      final longSide = math.max(outW, outH);
      if (longSide < minLongSide && outputWidth == null && outputHeight == null) {
        final scale = minLongSide / longSide;
        outW = (outW * scale).round();
        outH = (outH * scale).round();
      }

      // OpenCV Point 리스트
      final srcPoints = cv.VecPoint2f.fromList([
        cv.Point2f(srcPts[0].dx, srcPts[0].dy),
        cv.Point2f(srcPts[1].dx, srcPts[1].dy),
        cv.Point2f(srcPts[2].dx, srcPts[2].dy),
        cv.Point2f(srcPts[3].dx, srcPts[3].dy),
      ]);

      final dstPoints = cv.VecPoint2f.fromList([
        cv.Point2f(0, 0),
        cv.Point2f(outW.toDouble(), 0),
        cv.Point2f(outW.toDouble(), outH.toDouble()),
        cv.Point2f(0, outH.toDouble()),
      ]);

      final M = cv.getPerspectiveTransform2f(srcPoints, dstPoints);
      final warped = cv.warpPerspective(
        src, M, (outW, outH),
        flags: cv.INTER_CUBIC,
        borderMode: cv.BORDER_CONSTANT,
        borderValue: cv.Scalar(255, 255, 255, 255),
      );

      // 저장
      final cacheDir = await scanCacheDirectory;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outPath = '$cacheDir${Platform.pathSeparator}cropped_$timestamp.png';
      cv.imwrite(outPath, warped);

      M.dispose();
      warped.dispose();
      srcPoints.dispose();
      dstPoints.dispose();

      return outPath;
    } finally {
      src.dispose();
    }
  }

  /// Fallback 원근 보정 (순수 Dart)
  Future<String?> _warpPerspectiveFallback(
    String imagePath, List<Offset> corners,
    int? outputWidth, int? outputHeight,
  ) async {
    final bytes = await File(imagePath).readAsBytes();
    final src = img.decodeImage(bytes);
    if (src == null) return null;

    final w = src.width.toDouble();
    final h = src.height.toDouble();
    final srcPts = corners.map((c) => Offset(c.dx * w, c.dy * h)).toList();

    final topWidth = (srcPts[1] - srcPts[0]).distance;
    final bottomWidth = (srcPts[2] - srcPts[3]).distance;
    final leftHeight = (srcPts[3] - srcPts[0]).distance;
    final rightHeight = (srcPts[2] - srcPts[1]).distance;
    final outW = outputWidth ?? math.max(topWidth, bottomWidth).round();
    final outH = outputHeight ?? math.max(leftHeight, rightHeight).round();

    final dstPts = [
      Offset(0, 0), Offset(outW.toDouble(), 0),
      Offset(outW.toDouble(), outH.toDouble()), Offset(0, outH.toDouble()),
    ];

    final matrix = _computeHomography(dstPts, srcPts);
    if (matrix == null) return null;

    final result = img.Image(width: outW, height: outH);
    for (int y = 0; y < outH; y++) {
      for (int x = 0; x < outW; x++) {
        final srcPoint = _applyHomography(matrix, x.toDouble(), y.toDouble());
        final sx = srcPoint.dx;
        final sy = srcPoint.dy;
        if (sx >= 0 && sx < w - 1 && sy >= 0 && sy < h - 1) {
          final pixel = _bilinearInterpolate(src, sx, sy);
          result.setPixelRgba(x, y, pixel[0], pixel[1], pixel[2], pixel[3]);
        }
      }
    }

    final cacheDir = await scanCacheDirectory;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outPath = '$cacheDir${Platform.pathSeparator}cropped_$timestamp.png';
    await File(outPath).writeAsBytes(img.encodePng(result));
    return outPath;
  }

  List<double>? _computeHomography(List<Offset> src, List<Offset> dst) {
    final a = List<List<double>>.generate(8, (_) => List.filled(9, 0.0));
    for (int i = 0; i < 4; i++) {
      final sx = src[i].dx, sy = src[i].dy;
      final dx = dst[i].dx, dy = dst[i].dy;
      a[i * 2] = [sx, sy, 1, 0, 0, 0, -dx * sx, -dx * sy, dx];
      a[i * 2 + 1] = [0, 0, 0, sx, sy, 1, -dy * sx, -dy * sy, dy];
    }
    final n = 8;
    for (int col = 0; col < n; col++) {
      int maxRow = col;
      double maxVal = a[col][col].abs();
      for (int row = col + 1; row < n; row++) {
        if (a[row][col].abs() > maxVal) { maxVal = a[row][col].abs(); maxRow = row; }
      }
      if (maxVal < 1e-10) return null;
      final temp = a[col]; a[col] = a[maxRow]; a[maxRow] = temp;
      for (int row = col + 1; row < n; row++) {
        final factor = a[row][col] / a[col][col];
        for (int j = col; j <= n; j++) a[row][j] -= factor * a[col][j];
      }
    }
    final h = List.filled(9, 0.0);
    for (int i = n - 1; i >= 0; i--) {
      h[i] = a[i][n];
      for (int j = i + 1; j < n; j++) h[i] -= a[i][j] * h[j];
      h[i] /= a[i][i];
    }
    h[8] = 1.0;
    return h;
  }

  Offset _applyHomography(List<double> h, double x, double y) {
    final w = h[6] * x + h[7] * y + h[8];
    if (w.abs() < 1e-10) return Offset(x, y);
    return Offset((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w);
  }

  List<int> _bilinearInterpolate(img.Image src, double x, double y) {
    final x0 = x.floor(), y0 = y.floor();
    final x1 = x0 + 1, y1 = y0 + 1;
    final fx = x - x0, fy = y - y0;
    final p00 = src.getPixel(x0.clamp(0, src.width - 1), y0.clamp(0, src.height - 1));
    final p10 = src.getPixel(x1.clamp(0, src.width - 1), y0.clamp(0, src.height - 1));
    final p01 = src.getPixel(x0.clamp(0, src.width - 1), y1.clamp(0, src.height - 1));
    final p11 = src.getPixel(x1.clamp(0, src.width - 1), y1.clamp(0, src.height - 1));
    int lerp(int a, int b, int c, int d) =>
        ((a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy).round().clamp(0, 255);
    return [
      lerp(p00.r.toInt(), p10.r.toInt(), p01.r.toInt(), p11.r.toInt()),
      lerp(p00.g.toInt(), p10.g.toInt(), p01.g.toInt(), p11.g.toInt()),
      lerp(p00.b.toInt(), p10.b.toInt(), p01.b.toInt(), p11.b.toInt()),
      lerp(p00.a.toInt(), p10.a.toInt(), p01.a.toInt(), p11.a.toInt()),
    ];
  }

  // ─── Phase 2+3: 필터 (OpenCV 기반) ───

  Future<String?> applyFilter({
    required String imagePath,
    required ScanFilter filter,
  }) async {
    try {
      if (filter == ScanFilter.original) return imagePath;

      if (_useOpenCV) {
        return await _applyFilterOpenCV(imagePath, filter);
      }
      return await _applyFilterFallback(imagePath, filter);
    } catch (e) {
      debugPrint('[필터] 실패: $e');
      return imagePath;
    }
  }

  /// OpenCV 기반 필터
  Future<String?> _applyFilterOpenCV(String imagePath, ScanFilter filter) async {
    final src = cv.imread(imagePath);
    if (src.isEmpty) return imagePath;

    try {
      cv.Mat result;

      switch (filter) {
        case ScanFilter.document:
          final gray = src.channels > 1 ? cv.cvtColor(src, cv.COLOR_BGR2GRAY) : src.clone();
          final blockSize = math.max(11, (gray.cols ~/ 30) | 1);
          result = cv.adaptiveThreshold(
            gray, 255,
            cv.ADAPTIVE_THRESH_GAUSSIAN_C,
            cv.THRESH_BINARY,
            blockSize, 7.0,
          );
          gray.dispose();

        case ScanFilter.grayscale:
          result = src.channels > 1 ? cv.cvtColor(src, cv.COLOR_BGR2GRAY) : src.clone();

        case ScanFilter.bright:
          result = src.convertTo(cv.MatType.CV_8UC3, alpha: 1.3, beta: 40);

        case ScanFilter.highContrast:
          final gray = src.channels > 1 ? cv.cvtColor(src, cv.COLOR_BGR2GRAY) : src.clone();
          result = cv.equalizeHist(gray);
          gray.dispose();

        default:
          result = src.clone();
      }

      final cacheDir = await scanCacheDirectory;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outPath = '$cacheDir${Platform.pathSeparator}filtered_${filter.name}_$timestamp.png';
      cv.imwrite(outPath, result);
      result.dispose();

      return outPath;
    } finally {
      src.dispose();
    }
  }

  /// Fallback 필터
  Future<String?> _applyFilterFallback(String imagePath, ScanFilter filter) async {
    final bytes = await File(imagePath).readAsBytes();
    final src = img.decodeImage(bytes);
    if (src == null) return null;

    img.Image result;
    switch (filter) {
      case ScanFilter.document:
        result = img.grayscale(src);
        result = img.adjustColor(result, contrast: 1.5);
        result = _adaptiveThresholdDart(result);

      case ScanFilter.grayscale:
        result = img.grayscale(src);

      case ScanFilter.bright:
        result = img.adjustColor(src, brightness: 1.3, contrast: 1.2);

      case ScanFilter.highContrast:
        result = img.grayscale(src);
        result = img.adjustColor(result, contrast: 2.0);

      default:
        result = src;
    }

    final cacheDir = await scanCacheDirectory;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outPath = '$cacheDir${Platform.pathSeparator}filtered_${filter.name}_$timestamp.png';
    await File(outPath).writeAsBytes(img.encodePng(result));
    return outPath;
  }

  /// Phase 1: 적응형 blockSize 이진화 (Dart fallback)
  img.Image _adaptiveThresholdDart(img.Image src) {
    final w = src.width;
    final h = src.height;
    final result = img.Image(width: w, height: h);
    // Phase 1 개선: 이미지 크기 기반 동적 blockSize
    final blockSize = math.max(15, w ~/ 30);
    final c = 10;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        int sum = 0, count = 0;
        final x0 = math.max(0, x - blockSize ~/ 2);
        final y0 = math.max(0, y - blockSize ~/ 2);
        final x1 = math.min(w - 1, x + blockSize ~/ 2);
        final y1 = math.min(h - 1, y + blockSize ~/ 2);
        for (int by = y0; by <= y1; by += 2) {
          for (int bx = x0; bx <= x1; bx += 2) { sum += src.getPixel(bx, by).r.toInt(); count++; }
        }
        final mean = sum ~/ count;
        final pixel = src.getPixel(x, y).r.toInt();
        final v = pixel > mean - c ? 255 : 0;
        result.setPixelRgb(x, y, v, v, v);
      }
    }
    return result;
  }

  // ─── Phase 3: 고급 도구 (제거됨 — 곡률 보정, 손가락 제거, 2페이지 분리) ───
  // 향후 딥러닝 기반으로 재구현 예정

  // ─── 회전/저장/PDF/캐시 ───

  Future<String?> rotateImage(String imagePath, int degrees) async {
    try {
      if (_useOpenCV) {
        final src = cv.imread(imagePath);
        if (src.isEmpty) return null;

        cv.Mat result;
        switch (degrees) {
          case 90:
            result = cv.rotate(src, cv.ROTATE_90_CLOCKWISE);
          case 180:
            result = cv.rotate(src, cv.ROTATE_180);
          case 270:
            result = cv.rotate(src, cv.ROTATE_90_COUNTERCLOCKWISE);
          default:
            result = src.clone();
        }

        final cacheDir = await scanCacheDirectory;
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final outPath = '$cacheDir${Platform.pathSeparator}rotated_$timestamp.png';
        cv.imwrite(outPath, result);

        result.dispose();
        src.dispose();
        return outPath;
      }

      // Fallback
      final bytes = await File(imagePath).readAsBytes();
      final src = img.decodeImage(bytes);
      if (src == null) return null;
      final result = img.copyRotate(src, angle: degrees.toDouble());
      final cacheDir = await scanCacheDirectory;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outPath = '$cacheDir${Platform.pathSeparator}rotated_$timestamp.png';
      await File(outPath).writeAsBytes(img.encodePng(result));
      return outPath;
    } catch (e) {
      debugPrint('회전 실패: $e');
      return null;
    }
  }

  static const _mediaChannel = MethodChannel('com.wiscaner/media');

  /// 갤러리에 보이도록 MediaScanner 호출
  Future<void> _scanMediaFile(String filePath) async {
    if (!Platform.isAndroid) return;
    try {
      await _mediaChannel.invokeMethod('scanFile', {'path': filePath});
    } catch (e) {
      debugPrint('MediaScanner 호출 실패: $e');
    }
  }

  /// Android 공용 Pictures 폴더 경로
  Future<String> get _picturesDirectory async {
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        // getExternalStorageDirectory()는 /storage/.../Android/data/... 를 반환
        // 공용 Pictures 폴더로 변경: /storage/emulated/0/Pictures/WiScanner
        final parts = extDir.path.split('Android');
        final publicPath = '${parts[0]}Pictures${Platform.pathSeparator}WiScanner';
        final dir = Directory(publicPath);
        if (!await dir.exists()) await dir.create(recursive: true);
        return publicPath;
      }
    }
    return await scanSaveDirectory;
  }

  Future<String?> saveAsImage({
    required String imagePath,
    required String fileName,
    String format = 'png',
  }) async {
    try {
      final saveDir = await _picturesDirectory;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final sanitized = _sanitizeFileName(fileName);
      final outPath = '$saveDir${Platform.pathSeparator}${sanitized}_$timestamp.$format';
      final bytes = await File(imagePath).readAsBytes();
      if (format == 'jpg' || format == 'jpeg') {
        final src = img.decodeImage(bytes);
        if (src == null) return null;
        await File(outPath).writeAsBytes(img.encodeJpg(src, quality: 90));
      } else {
        await File(imagePath).copy(outPath);
      }
      await _scanMediaFile(outPath);
      return outPath;
    } catch (e) {
      debugPrint('이미지 저장 실패: $e');
      return null;
    }
  }

  Future<String?> saveAsPdf({
    required List<String> imagePaths,
    required String title,
  }) async {
    try {
      final document = PdfDocument();
      for (final imagePath in imagePaths) {
        final bytes = await File(imagePath).readAsBytes();
        final pdfImage = PdfBitmap(bytes);
        final page = document.pages.add();
        final pageW = page.getClientSize().width;
        final pageH = page.getClientSize().height;
        final imgScale = math.min(pageW / pdfImage.width, pageH / pdfImage.height);
        final imgW = pdfImage.width * imgScale;
        final imgH = pdfImage.height * imgScale;
        final offsetX = (pageW - imgW) / 2;
        final offsetY = (pageH - imgH) / 2;
        page.graphics.drawImage(pdfImage, Rect.fromLTWH(offsetX, offsetY, imgW, imgH));
      }
      final saveDir = await _picturesDirectory;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final sanitized = _sanitizeFileName(title);
      final outPath = '$saveDir${Platform.pathSeparator}${sanitized}_$timestamp.pdf';
      final file = File(outPath);
      await file.writeAsBytes(await document.save());
      document.dispose();
      await _scanMediaFile(outPath);
      return outPath;
    } catch (e) {
      debugPrint('PDF 저장 실패: $e');
      return null;
    }
  }

  Future<void> clearCache() async {
    try {
      final cacheDir = Directory(await scanCacheDirectory);
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
        await cacheDir.create(recursive: true);
      }
    } catch (e) {
      debugPrint('캐시 정리 실패: $e');
    }
  }

  String _sanitizeFileName(String name) =>
      name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').replaceAll(RegExp(r'\s+'), '_');

  // ─── 품질 평가 ───

  Future<Map<String, dynamic>> assessImageQuality(
    String imagePath, List<Offset> corners,
  ) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return {'isGood': false, 'score': 0.0, 'issues': ['이미지 로드 실패']};

      final issues = <String>[];
      double score = 100.0;

      final blurScore = await _assessBlur(image);
      if (blurScore < 50) { issues.add('흔들림 감지'); score -= 30; }

      final lightScore = _assessLighting(image);
      if (lightScore < 40) { issues.add('너무 어두움'); score -= 25; }
      else if (lightScore > 90) { issues.add('너무 밝음'); score -= 20; }

      final areaScore = _assessDocumentArea(corners, image.width, image.height);
      if (areaScore < 30) { issues.add('문서가 너무 작음'); score -= 25; }

      final angleScore = _assessDocumentAngle(corners);
      if (angleScore < 60) { issues.add('각도가 기울어짐'); score -= 20; }

      return {
        'isGood': score >= 70 && issues.isEmpty,
        'score': score.clamp(0.0, 100.0),
        'issues': issues,
      };
    } catch (e) {
      return {'isGood': false, 'score': 0.0, 'issues': ['평가 실패']};
    }
  }

  Future<double> _assessBlur(img.Image image) async {
    try {
      final small = img.copyResize(image, width: 256);
      final gray = img.grayscale(small);
      double variance = 0.0;
      int count = 0;
      for (int y = 1; y < gray.height - 1; y++) {
        for (int x = 1; x < gray.width - 1; x++) {
          final center = gray.getPixel(x, y).r.toDouble();
          final laplacian = -4 * center +
              gray.getPixel(x - 1, y).r + gray.getPixel(x + 1, y).r +
              gray.getPixel(x, y - 1).r + gray.getPixel(x, y + 1).r;
          variance += laplacian * laplacian;
          count++;
        }
      }
      variance /= count;
      return (variance / 100).clamp(0.0, 100.0);
    } catch (e) {
      return 50.0;
    }
  }

  double _assessLighting(img.Image image) {
    try {
      final small = img.copyResize(image, width: 128);
      final gray = img.grayscale(small);
      double sum = 0.0;
      int count = 0;
      for (final pixel in gray) { sum += pixel.r.toDouble(); count++; }
      return (sum / count / 255 * 100).clamp(0.0, 100.0);
    } catch (e) {
      return 50.0;
    }
  }

  double _assessDocumentArea(List<Offset> corners, int imgWidth, int imgHeight) {
    if (corners.length != 4) return 0.0;
    double area = 0.0;
    for (int i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      area += corners[i].dx * corners[j].dy;
      area -= corners[j].dx * corners[i].dy;
    }
    return (area.abs() / 2 * 100).clamp(0.0, 100.0);
  }

  double _assessDocumentAngle(List<Offset> corners) {
    if (corners.length != 4) return 0.0;
    final sides = <double>[];
    for (int i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      final dx = corners[j].dx - corners[i].dx;
      final dy = corners[j].dy - corners[i].dy;
      sides.add(math.sqrt(dx * dx + dy * dy));
    }
    final ratio1 = math.min(sides[0], sides[2]) / math.max(sides[0], sides[2]);
    final ratio2 = math.min(sides[1], sides[3]) / math.max(sides[1], sides[3]);
    return ((ratio1 + ratio2) / 2 * 100).clamp(0.0, 100.0);
  }

  // ─── 문서 크기 측정 ───

  DocumentSize estimateDocumentSize(
    List<Offset> corners, int imageWidth, int imageHeight,
    { double? cameraHeightCm }
  ) {
    if (corners.length != 4) {
      return DocumentSize(detectedSize: PaperSize.unknown, widthMm: 0, heightMm: 0, confidence: 0);
    }

    final pixels = corners.map((c) => Offset(c.dx * imageWidth, c.dy * imageHeight)).toList();
    final sides = <double>[];
    for (int i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      final dx = pixels[j].dx - pixels[i].dx;
      final dy = pixels[j].dy - pixels[i].dy;
      sides.add(math.sqrt(dx * dx + dy * dy));
    }

    final widthPx = (sides[0] + sides[2]) / 2;
    final heightPx = (sides[1] + sides[3]) / 2;
    final aspectRatio = widthPx / heightPx;

    PaperSize bestMatch = PaperSize.unknown;
    double bestConfidence = 0;
    double estimatedWidthMm = 0, estimatedHeightMm = 0;

    for (final size in PaperSize.values) {
      if (size == PaperSize.unknown) continue;
      final ratio1 = size.aspectRatio;
      final ratio2 = 1 / ratio1;
      final diff1 = (aspectRatio - ratio1).abs();
      final diff2 = (aspectRatio - ratio2).abs();
      final minDiff = math.min(diff1, diff2);
      final confidence = math.max(0.0, 1.0 - minDiff / 0.5);

      if (confidence > bestConfidence) {
        bestConfidence = confidence;
        bestMatch = size;
        if (diff1 < diff2) {
          estimatedWidthMm = size.widthMm;
          estimatedHeightMm = size.heightMm;
        } else {
          estimatedWidthMm = size.heightMm;
          estimatedHeightMm = size.widthMm;
        }
      }
    }

    if (bestConfidence < 0.7) {
      bestMatch = PaperSize.unknown;
      final a4WidthPx = imageWidth * 0.7;
      final mmPerPx = 210.0 / a4WidthPx;
      estimatedWidthMm = widthPx * mmPerPx;
      estimatedHeightMm = heightPx * mmPerPx;
    }

    return DocumentSize(
      detectedSize: bestMatch, widthMm: estimatedWidthMm,
      heightMm: estimatedHeightMm, confidence: bestConfidence,
    );
  }
}
