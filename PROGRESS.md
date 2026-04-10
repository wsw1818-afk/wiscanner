# PROGRESS.md (현재 진행: 얇게 유지)

## Dashboard
- Progress: 80%
- Phase: 버그 수정 및 최적화 (bug_fix_optimization_plan.md 기반)
- Risk: 낮음 (안정성 개선 완료)

## Today Goal
- bug_fix_optimization_plan.md 기반 Sprint 1~2 적용

## What changed (Phase 3 - 버그 수정/최적화)
- 카메라 전체화면 Cover 방식 + 가로/세로 회전 대응 (사이드바 컨트롤)
- 투명 AppBar (extendBodyBehindAppBar)
- 1.1 Mat 객체 dispose 보장: detectDocumentCorners, warpPerspective try-finally 강화
- 1.3 카메라 스트림 중복 시작 방지: _isStreamStarting 플래그
- 1.4 음성 인식 마이크 권한 처리: Permission.microphone 요청 추가
- 1.5 파일 삭제 시 이미지 캐시 정리: imageCache.clear() 호출
- 2.2 배치 모드 진행 표시: CropPage AppBar bottom에 LinearProgressIndicator
- 3.2 ONNX 스레드 최적화: Platform.numberOfProcessors 기반 동적 설정

## Previous (Phase 2 - UX 개선)
- 카메라 권한 처리/설정 화면/필터 5종/홈 화면 개선/스캔 UX

## Previous (Phase 1 - 핵심 기능 이식)
- Winote 스캐너 7개 파일 이식/Android APK 빌드/카메라 전체화면

## Commands & Results
- `flutter analyze`: error 0 (test 제외), warning 3, info 16
- `flutter build apk --debug`: 성공 (32초)
- `adb install -r`: 핸드폰 설치 성공

## Open issues
- 2.3 크롭 페이지 UX (핀치줌/미세조정) - 후순위
- 2.4 설정 저장/복원 확장 - 후순위
- 3.3 이미지 캐싱 최적화 - 파일 많아지면 적용
- OCR/클라우드/폴더 관리 (Phase 4 이후)

## Next
1) 실기기에서 전체화면/가로모드/배치 진행바 테스트
2) 크롭 페이지 UX 개선 (핀치줌)
3) 설정 저장/복원 확장
