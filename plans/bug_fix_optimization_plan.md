# WiScanner 앱 버그 수정 및 최적화 기획안

## 📋 개요
본 문서는 WiScanner 앱의 실제 코드 분석을 기반으로 발견된 버그, 보완 필요 사항, 성능 최적화 항목을 정리한 기획안입니다.

**작성일**: 2026-03-07  
**분석 대상 버전**: Phase 2 UX 개선 완료 버전  
**진행률**: 75%

---

## 🔴 1. 버그 (Bugs)

### 1.1 메모리 누수 위험 - OpenCV Mat 객체 해제

**심각도**: 높음  
**위치**: [`document_scanner_service.dart`](wiscaner_app/lib/core/services/document_scanner_service.dart)

**문제점**:
- OpenCV Mat 객체가 예외 발생 시 dispose되지 않을 수 있음
- `detectDocumentCorners()` 메서드에서 `src.dispose()` 호출 전 예외 발생 가능

**증상**:
- 장시간 사용 시 메모리 사용량 증가
- 앱 느려짐 및 크래시 가능성

**해결 방안**:
```dart
// Before (현재 코드)
final src = cv.imread(imagePath);
if (src.isEmpty) return _defaultCorners();
try {
  // 처리 로직
} finally {
  src.dispose();
}

// After (개선 코드)
final src = cv.imread(imagePath);
if (src.isEmpty) return _defaultCorners();
try {
  // 처리 로직
} catch (e) {
  debugPrint('[OpenCV] 오류: $e');
  rethrow;
} finally {
  src.dispose();
}
```

**영향 범위**:
- `_detectCornersOpenCV()`
- `applyPerspectiveTransform()`
- `_findDocumentCornersFromMat()`
- 모든 OpenCV Mat 사용 위치

---

### 1.2 DocAligner ONNX 세션 메모리 해제 누락

**심각도**: 중간  
**위치**: [`doc_aligner_service.dart`](wiscaner_app/lib/core/services/doc_aligner_service.dart:23-25)

**문제점**:
- `_session`과 `_sessionOptions`가 앱 수명 주기 동안 해제되지 않음
- dispose 메서드가 구현되지 않음

**증상**:
- ONNX 모델 메모리(~5MB)가 지속적으로 점유
- 앱 재시작 없이 메모리 회수 불가

**해결 방안**:
```dart
class DocAlignerService {
  // ... 기존 코드 ...
  
  /// 리소스 해제
  void dispose() {
    _session?.release();
    _sessionOptions?.release();
    _session = null;
    _sessionOptions = null;
    _initialized = false;
  }
}
```

---

### 1.3 카메라 스트림 중복 시작 방지 미흡

**심각도**: 중간  
**위치**: [`scanner_page.dart`](wiscaner_app/lib/presentation/pages/scanner/scanner_page.dart:120-129)

**문제점**:
- `_startAutoDetection()`에서 `isStreamingImages` 체크 후 시작하지만
- 경쟁 조건(race condition)으로 인해 중복 시작 가능

**증상**:
- "이미 스트리밍 중" 에러 로그
- 배터리 소모 증가

**해결 방안**:
```dart
bool _isStreamStarting = false;

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
```

---

### 1.4 음성 인식 권한 미처리

**심각도**: 낮음  
**위치**: [`scanner_page.dart`](wiscaner_app/lib/presentation/pages/scanner/scanner_page.dart:91-101)

**문제점**:
- 음성 인식 초기화 시 마이크 권한 요청 없음
- Android 12+에서 마이크 권한이 자동으로 요청되지 않을 수 있음

**증상**:
- 음성 명령 모드 활성화 시 무반응
- 사용자에게 권한 거부 사실 미전달

**해결 방안**:
```dart
Future<void> _initSpeech() async {
  // 마이크 권한 확인
  final micStatus = await Permission.microphone.status;
  if (!micStatus.isGranted) {
    final result = await Permission.microphone.request();
    if (!result.isGranted) {
      debugPrint('마이크 권한 거부됨');
      return;
    }
  }
  
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
```

---

### 1.5 파일 삭제 시 썸네일 캐시 미삭제

**심각도**: 낮음  
**위치**: [`home_page.dart`](wiscaner_app/lib/presentation/pages/home/home_page.dart)

**문제점**:
- 파일 삭제 시 Flutter 이미지 캐시는 유지됨
- 대용량 파일 삭제 후에도 캐시 메모리 점유

**증상**:
- 많은 파일 스캔/삭제 반복 시 메모리 증가

**해결 방안**:
```dart
Future<void> _deleteFile(String filePath) async {
  try {
    final file = File(filePath);
    // 이미지 캐시에서 제거
    final fileUri = Uri.file(filePath).toString();
    await PaintingBinding.instance.imageCache.evict(fileUri);
    
    await file.delete();
    _loadScanFiles();
  } catch (e) {
    debugPrint('파일 삭제 실패: $e');
  }
}
```

---

## 🟡 2. 보완 사항 (Improvements)

### 2.1 예외 처리 강화 - 사용자 친화적 에러 메시지

**우선순위**: 높음  
**위치**: 전체 서비스 레이어

**현재 상태**:
- `debugPrint()`로 로그만 출력
- 사용자에게 에러 내용 미전달

**개선 방안**:
```dart
/// 에러 타입 정의
enum ScannerError {
  cameraPermission,
  storagePermission,
  cameraInit,
  imageProcess,
  saveFailed,
  unknown,
}

/// 에러 결과 클래스
class ScannerResult<T> {
  final T? data;
  final ScannerError? error;
  final String message;
  final bool success;
  
  const ScannerResult.success(this.data)
      : error = null, message = '', success = true;
  const ScannerResult.error(this.error, this.message)
      : data = null, success = false;
}

/// 사용자 친화적 메시지 매핑
String getErrorMessage(ScannerError error) {
  switch (error) {
    case ScannerError.cameraPermission:
      return '카메라 권한이 필요합니다. 설정에서 권한을 허용해주세요.';
    case ScannerError.storagePermission:
      return '저장소 권한이 필요합니다.';
    case ScannerError.cameraInit:
      return '카메라를 초기화할 수 없습니다. 앱을 재시작해주세요.';
    case ScannerError.imageProcess:
      return '이미지 처리 중 오류가 발생했습니다.';
    case ScannerError.saveFailed:
      return '파일 저장에 실패했습니다. 저장 공간을 확인해주세요.';
    case ScannerError.unknown:
      return '알 수 없는 오류가 발생했습니다.';
  }
}
```

---

### 2.2 배치 모드 진행 상태 표시 개선

**우선순위**: 중간  
**위치**: [`crop_page.dart`](wiscaner_app/lib/presentation/pages/scanner/crop_page.dart)

**현재 상태**:
- "영역 조정 (1/5)" 형태의 단순 텍스트
- 전체 진행률 시각화 부족

**개선 방안**:
```dart
Widget _buildBatchProgressBar() {
  return LinearProgressIndicator(
    value: (_currentBatchIndex + 1) / widget.batchImages!.length,
    backgroundColor: Colors.grey[700],
    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
  );
}

// AppBar bottom에 추가
appBar: AppBar(
  title: Text('영역 조정'),
  bottom: _isBatchMode 
      ? PreferredSize(
          preferredSize: Size.fromHeight(4),
          child: _buildBatchProgressBar(),
        )
      : null,
),
```

---

### 2.3 크롭 페이지 UX 개선

**우선순위**: 중간  
**위치**: [`crop_page.dart`](wiscaner_app/lib/presentation/pages/scanner/crop_page.dart)

**현재 문제점**:
1. 꼭짓점 드래그 시 미세 조정 어려움
2. 확대/축소 기능 없음
3. 초기 감지 실패 시 사용자 가이드 부족

**개선 방안**:

#### 2.3.1 핀치 줌 기능 추가
```dart
class _CropPageState extends State<CropPage> {
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  
  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      _scale = (_scale * details.scale).clamp(1.0, 4.0);
      // 오프셋 계산...
    });
  }
}
```

#### 2.3.2 미세 조정 모드
```dart
bool _fineTuneMode = false;

// 미세 조정 시 이동 범위 제한
void _updateCorner(int index, Offset position) {
  final delta = _fineTuneMode ? 0.002 : 0.01;
  setState(() {
    _corners[index] = Offset(
      (position.dx - _corners[index].dx).abs() < delta 
          ? position.dx 
          : _corners[index].dx + (position.dx > _corners[index].dx ? delta : -delta),
      // y축도 동일하게 처리
    );
  });
}
```

#### 2.3.3 감지 실패 시 가이드
```dart
Widget _buildDetectionFailedGuide() {
  return Container(
    padding: EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.orange.withOpacity(0.9),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.info_outline, color: Colors.white),
        SizedBox(height: 8),
        Text('문서를 자동으로 감지하지 못했습니다.', 
              style: TextStyle(color: Colors.white)),
        Text('파란 점을 드래그하여 영역을 직접 선택해주세요.',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    ),
  );
}
```

---

### 2.4 설정 저장 및 복원

**우선순위**: 중간  
**위치**: [`settings_page.dart`](wiscaner_app/lib/presentation/pages/settings/settings_page.dart)

**현재 상태**:
- 일부 설정만 SharedPreferences에 저장
- 자동 스캔 민감도, 기본 필터 등 미저장

**개선 방안**:
```dart
class SettingsService {
  static const _keys = {
    'autoScanEnabled',
    'autoScanSensitivity',
    'defaultFilter',
    'imageQuality',
    'saveFormat',
    'tapToCapture',
    'voiceEnabled',
    'showGridLines',
  };
  
  Future<void> saveAll(Map<String, dynamic> settings) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in settings.entries) {
      if (entry.value is bool) {
        await prefs.setBool(entry.key, entry.value);
      } else if (entry.value is int) {
        await prefs.setInt(entry.key, entry.value);
      } else if (entry.value is String) {
        await prefs.setString(entry.key, entry.value);
      }
    }
  }
  
  Future<Map<String, dynamic>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final key in _keys) 
        key: prefs.get(key),
    };
  }
}
```

---

### 2.5 홈 화면 빈 상태 개선

**우선순위**: 낮음  
**위치**: [`home_page.dart`](wiscaner_app/lib/presentation/pages/home/home_page.dart)

**현재 상태**:
- 단순 텍스트 + 아이콘
- 첫 사용자 가이드 부족

**개선 방안**:
```dart
Widget _buildEmptyState() {
  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 애니메이션 아이콘
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.8, end: 1.0),
          duration: Duration(milliseconds: 500),
          builder: (context, value, child) {
            return Transform.scale(
              scale: value,
              child: Icon(
                Icons.document_scanner,
                size: 80,
                color: Colors.grey[400],
              ),
            );
          },
        ),
        SizedBox(height: 24),
        Text(
          '스캔된 문서가 없습니다',
          style: TextStyle(fontSize: 18, color: Colors.grey[600]),
        ),
        SizedBox(height: 12),
        Text(
          '아래 버튼을 눌러 첫 문서를 스캔해보세요',
          style: TextStyle(fontSize: 14, color: Colors.grey[500]),
        ),
        SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: _openScanner,
          icon: Icon(Icons.camera_alt),
          label: Text('스캔 시작하기'),
          style: ElevatedButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
      ],
    ),
  );
}
```

---

## 🟢 3. 최적화 (Optimizations)

### 3.1 이미지 처리 Isolate 분리

**우선순위**: 높음  
**위치**: [`document_scanner_service.dart`](wiscaner_app/lib/core/services/document_scanner_service.dart)

**현재 문제점**:
- 고해상도 이미지 처리 시 UI 스레드 블로킹
- 원근 변환, 필터 적용 등이 메인 스레드에서 실행

**개선 방안**:
```dart
import 'dart:isolate';

/// Isolate에서 실행할 이미지 처리 함수
Future<String> _processImageInIsolate(IsolateParams params) async {
  // 이미지 처리 로직
  final result = await _applyPerspectiveTransformInternal(
    params.imagePath,
    params.corners,
    params.filter,
  );
  return result;
}

/// 공개 API
Future<String?> applyPerspectiveTransform({
  required String imagePath,
  required List<Offset> corners,
  ScanFilter filter = ScanFilter.original,
}) async {
  if (await _shouldUseIsolate(imagePath)) {
    return await compute(_processImageInIsolate, IsolateParams(
      imagePath: imagePath,
      corners: corners,
      filter: filter,
    ));
  }
  // 작은 이미지는 직접 처리
  return _applyPerspectiveTransformInternal(imagePath, corners, filter);
}

Future<bool> _shouldUseIsolate(String imagePath) async {
  final file = File(imagePath);
  final size = await file.length();
  return size > 1024 * 1024; // 1MB 이상
}
```

---

### 3.2 ONNX 추론 최적화

**우선순위**: 중간  
**위치**: [`doc_aligner_service.dart`](wiscaner_app/lib/core/services/doc_aligner_service.dart)

**현재 상태**:
- 매 프레임마다 256x256 리사이즈 수행
- Y plane만 사용하여 그레이스케일로 추론

**최적화 방안**:

#### 3.2.1 스레드 수 최적화
```dart
Future<void> init() async {
  if (_initialized) return;
  _initialized = true;
  
  // 디바이스 코어 수에 따른 스레드 설정
  final cores = Platform.numberOfProcessors;
  final threads = (cores / 2).clamp(1, 4).toInt();
  
  _sessionOptions = OrtSessionOptions()
    ..setInterOpNumThreads(threads)
    ..setIntraOpNumThreads(threads)
    ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
}
```

#### 3.2.2 프레임 스킵 최적화
```dart
// scanner_page.dart
int _lastDetectionMs = 0;
int _frameSkipCounter = 0;
static const int _frameSkipInterval = 2; // 3프레임마다 1회 감지

void _onCameraFrame(CameraImage image) {
  _frameSkipCounter++;
  if (_frameSkipCounter % _frameSkipInterval != 0) return;
  
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - _lastDetectionMs < 350) return;
  // ... 기존 로직
}
```

---

### 3.3 이미지 캐싱 최적화

**우선숀위**: 중간  
**위치**: [`home_page.dart`](wiscaner_app/lib/presentation/pages/home/home_page.dart)

**현재 문제점**:
- `Image.file()` 사용 시 매번 파일 읽기
- 스크롤 시 끊김 현상

**개선 방안**:
```dart
import 'package:cached_network_image/cached_network_image.dart';

// 커스텀 썸네일 캐시 구현
class ThumbnailCache {
  static final _cache = <String, Uint8List>{};
  static const _maxCacheSize = 100;
  
  static Future<Uint8List> getThumbnail(String path, {int size = 200}) async {
    if (_cache.containsKey(path)) {
      return _cache[path]!;
    }
    
    final bytes = await _generateThumbnail(path, size);
    
    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[path] = bytes;
    
    return bytes;
  }
  
  static Future<Uint8List> _generateThumbnail(String path, int size) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: size,
      targetHeight: size,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
}
```

---

### 3.4 파일 시스템 접근 최적화

**우선숀위**: 중간  
**위치**: [`home_page.dart`](wiscaner_app/lib/presentation/pages/home/home_page.dart)

**현재 문제점**:
- `_loadScanFiles()` 호출 시마다 전체 디렉토리 스캔
- 파일 수가 많을 경우 지연

**개선 방안**:
```dart
class FileListCache {
  List<FileSystemEntity>? _cachedFiles;
  DateTime? _lastUpdate;
  static const _cacheDuration = Duration(seconds: 5);
  
  Future<List<FileSystemEntity>> getFiles(String directory, {bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedFiles != null && _lastUpdate != null) {
      final elapsed = DateTime.now().difference(_lastUpdate!);
      if (elapsed < _cacheDuration) {
        return _cachedFiles!;
      }
    }
    
    final dir = Directory(directory);
    if (!await dir.exists()) return [];
    
    _cachedFiles = await dir.list().toList();
    _lastUpdate = DateTime.now();
    return _cachedFiles!;
  }
  
  void invalidate() {
    _cachedFiles = null;
    _lastUpdate = null;
  }
}
```

---

### 3.5 배치 처리 파이프라인 최적화

**우선숀위**: 낮음  
**위치**: [`document_scanner_service.dart`](wiscaner_app/lib/core/services/document_scanner_service.dart)

**현재 문제점**:
- 배치 모드에서 이미지 순차 처리
- 전체 처리 시간 = N × 단일 처리 시간

**개선 방안**:
```dart
Future<List<String>> processBatchImages(
  List<String> imagePaths, {
  int parallelCount = 2,
}) async {
  final results = <String>[];
  final queue = Queue<String>.from(imagePaths);
  final active = <Future<String?>>[];
  
  while (queue.isNotEmpty || active.isNotEmpty) {
    // 병렬 처리 슬롯 채우기
    while (active.length < parallelCount && queue.isNotEmpty) {
      final path = queue.removeFirst();
      active.add(applyPerspectiveTransform(
        imagePath: path,
        corners: await detectDocumentCorners(path),
      ));
    }
    
    if (active.isNotEmpty) {
      // 하나 완료될 때까지 대기
      final completed = await Future.any(active.map((f) => f.then((_) => f)));
      active.remove(completed);
      if (completed != null) {
        results.add(completed);
      }
    }
  }
  
  return results;
}
```

---

## 📊 4. 우선순위 매트릭스

| 항목 | 심각도 | 난이도 | 우선순위 | 예상 소요 |
|------|--------|--------|----------|----------|
| 1.1 Mat 객체 해제 | 높음 | 낮음 | P0 | 2시간 |
| 1.2 ONNX 세션 해제 | 중간 | 낮음 | P1 | 1시간 |
| 1.3 스트림 중복 시작 | 중간 | 낮음 | P1 | 1시간 |
| 1.4 음성 권한 처리 | 낮음 | 낮음 | P2 | 1시간 |
| 1.5 썸네일 캐시 삭제 | 낮음 | 낮음 | P2 | 1시간 |
| 2.1 예외 처리 강화 | 높음 | 중간 | P0 | 4시간 |
| 2.2 배치 진행 표시 | 중간 | 낮음 | P1 | 2시간 |
| 2.3 크롭 UX 개선 | 중간 | 중간 | P1 | 4시간 |
| 2.4 설정 저장/복원 | 중간 | 낮음 | P1 | 2시간 |
| 2.5 빈 상태 개선 | 낮음 | 낮음 | P2 | 1시간 |
| 3.1 Isolate 분리 | 높음 | 높음 | P0 | 6시간 |
| 3.2 ONNX 최적화 | 중간 | 중간 | P1 | 3시간 |
| 3.3 이미지 캐싱 | 중간 | 중간 | P1 | 3시간 |
| 3.4 파일 시스템 | 중간 | 낮음 | P2 | 2시간 |
| 3.5 배치 파이프라인 | 낮음 | 높음 | P3 | 4시간 |

---

## 🗓️ 5. 실행 로드맵

### Sprint 1 (1주차) - 안정성 확보
- [x] 1.1 Mat 객체 dispose 보장 (2026-03-07 완료: try-finally 강화)
- [x] 1.2 ONNX 세션 dispose 구현 (기존에 이미 구현됨: doc_aligner_service.dart:227-234)
- [x] 1.3 카메라 스트림 동기화 (2026-03-07 완료: _isStreamStarting 플래그)
- [ ] 2.1 예외 처리 및 에러 메시지 시스템 (후순위: 현재 SnackBar로 충분)

### Sprint 2 (2주차) - UX 개선
- [x] 2.2 배치 모드 진행 표시 (2026-03-07 완료: LinearProgressIndicator)
- [ ] 2.3 크롭 페이지 UX 개선 (확대/미세조정)
- [ ] 2.4 설정 저장/복원
- [x] 1.4 음성 권한 처리 (2026-03-07 완료: Permission.microphone 추가)

### Sprint 3 (3주차) - 성능 최적화
- [x] 3.1 이미지 처리 Isolate 분리 (제외: OpenCV 네이티브 바인딩은 Isolate 불가)
- [x] 3.2 ONNX 추론 최적화 (2026-03-07 완료: 동적 스레드 설정)
- [ ] 3.3 이미지 캐싱 구현

### Sprint 4 (4주차) - 추가 개선
- [x] 1.5 썸네일 캐시 삭제 (2026-03-07 완료: imageCache.clear() 추가)
- [ ] 2.5 빈 상태 개선
- [ ] 3.4 파일 시스템 최적화
- [ ] 3.5 배치 파이프라인 (선택)

---

## 📝 6. 테스트 체크리스트

### 기능 테스트
- [ ] 카메라 권한 거부/허용 시나리오
- [ ] 마이크 권한 거부/허용 시나리오
- [ ] 대용량 이미지(10MB+) 처리
- [ ] 배치 모드 10장 이상 연속 촬영
- [ ] 앱 백그라운드 전환/복귀
- [ ] 메모리 부족 상황
- [ ] 저장 공간 부족 상황

### 성능 테스트
- [ ] 메모리 사용량 모니터링 (30분 사용)
- [ ] 프레임 드롭 측정 (스캔 중)
- [ ] 배터리 소모 측정
- [ ] 썸네일 로딩 속도 (100개 파일)

### 호환성 테스트
- [ ] Android 10 이하
- [ ] Android 11-12
- [ ] Android 13+
- [ ] 다양한 화면 크기
- [ ] 가로/세로 모드

---

*작성일: 2026-03-07*  
*버전: 1.0*
