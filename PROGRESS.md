# PROGRESS.md (현재 진행: 얇게 유지)

## Dashboard
- Progress: 75%
- Phase: UX 개선 완료, 실기기 설치 완료
- Risk: 낮음 (기본 기능 + UX 개선 완료)

## Today Goal
- improvement_plan.md 기반 UX 개선 구현 + 실기기 설치

## What changed (Phase 2 - UX 개선)
- 카메라 권한 처리 개선: permission_handler 추가, 거부 시 설정 이동 안내
- 설정 화면 신규: 자동 스캔/저장 형식/이미지 품질/권한 상태/앱 정보
- 필터 5종 확장: 원본/문서/흑백/밝게/고대비 (OpenCV + Dart fallback)
- 홈 화면 개선: 다중 선택/파일 정보(날짜+크기)/이름 편집/이미지 뷰어(핀치줌)/빈 상태 UX
- 스캔 UX: 촬영 플래시 효과(AnimatedOpacity), 품질 지표 위젯
- 컴파일 에러 수정: convertTo API 수정, unused import 제거

## Previous (Phase 1 - 핵심 기능 이식)
- Winote 스캐너 7개 파일 이식
- Android APK 빌드 + 무선 ADB 설치
- 카메라 전체화면/감지선 사각형 유지/갤러리 저장

## Commands & Results
- `flutter analyze`: error 0, info 11
- `flutter build apk --debug`: 성공 (33초)
- `adb install -r`: 핸드폰 설치 성공

## Open issues
- 실기기에서 새 기능(필터/설정/홈 화면) 동작 확인 필요
- 크롭 페이지 개선 (Phase 2 잔여)
- OCR/클라우드/폴더 관리 (Phase 3 이후)

## Next
1) 실기기에서 필터/설정/홈 화면 기능 테스트
2) 크롭 페이지 UX 개선
3) 안정화 및 에지케이스 처리
