# MEMORY.md (SSOT: 규칙/기술 스택/제약)

## 1) Goal / Scope (정적)
- 목표: Winote 노트앱의 스캐너 기능을 분리하여 독립 스캐너 앱 개발
- 범위: 카메라 촬영 → 문서 감지 → 꼭짓점 조정 → 원근 보정 → 저장/공유/PDF
- Non-goals: 노트/필기 기능, OCR 텍스트 추출 (v1)

## 2) Tech Stack (정적, 캐시 최적화)
- Framework: Flutter (Dart SDK >=3.2.0)
- Language: Dart
- State/Networking: Provider (최소 상태 관리)
- Backend/DB: 로컬 파일시스템 (SQLite는 필요 시)
- Build/CI: flutter build (C:\flutter\bin\flutter.bat)
- Target platforms: Android (메인), Windows (보조)

## 3) Constraints (가끔 변함)
- Flutter 경로: C:\flutter\bin\flutter.bat
- 핵심 의존성: onnxruntime ^1.4.1, opencv_dart ^1.4.3, camera ^0.11.0
- AI 모델: doc_aligner_book_v2.onnx (4.95MB, FP32)
- 원본 소스: H:\Claude_work\Winote\ (스캐너 파일 7개 기반)
- 금지사항: 노트 앱 기능 포함 금지, GoRouter editor 경로 의존 금지

## 4) Coding Rules (정적)
- 최소 diff 원칙
- 테스트/수정 루프(최대 3회): lint/typecheck/test 우선
- 비밀정보 금지: 값 금지(변수명/위치만)
- 큰 변경(프레임워크/DB/상태관리 교체)은 사용자 1회 확인 후 진행

## 5) Architecture Notes (가끔 변함)
- 폴더 구조 요약:
  ```
  lib/
  ├── main.dart
  ├── app.dart
  ├── core/services/        ← DocAlignerService, DocumentScannerService
  ├── presentation/
  │   ├── pages/
  │   │   ├── home/         ← 스캔 이력 갤러리
  │   │   ├── scanner/      ← ScannerPage, CropPage, ResultPage
  │   └── widgets/scanner/  ← DocumentOverlay
  └── models/               ← 데이터 모델
  ```
- 주요 모듈 책임:
  - DocAlignerService: ONNX 딥러닝 문서 감지
  - DocumentScannerService: OpenCV 이미지 처리 + Dart 폴백
  - ScannerPage: 카메라 실시간 감지 UI
  - CropPage: 꼭짓점 수동 조정
  - ResultPage: 필터/저장/공유/PDF (FilterPage에서 재설계)
  - HomePage: 스캔 이력 목록
- 데이터 흐름: 카메라 → ONNX 감지 → 크롭 조정 → warpPerspective → 필터 → 저장

## 6) Testing / Release Rules (정적)
- 통과 기준: flutter analyze, flutter build
- 배포 경로: (추후 설정)
