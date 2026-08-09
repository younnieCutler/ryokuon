# GUI 조작 가능화 (2026-08-09, 5단계 이후 추가 작업)

3~5단계 로직(전사, 발화 병합, FLAC 변환, 게인)이 전부 CLI 개발용 커맨드로만 실행
가능했다 — 실제 앱을 더블클릭해서 쓰는 사용자는 녹음 이후 아무것도 할 방법이 없었다.
"gui로 조작 가능하게 만들어 설정이랑 말한것들" 요청으로 다음을 실제 화면에 연결:

## 추가된 것

- **전사하기 버튼** (`AppState.transcribeSession`) — 세션 상세 화면에서 클릭하면
  Transcriber(3단계) → TranscriptBuilder(4단계) → FLACConverter(5단계)를 순서대로 실행.
  진행 상황 텍스트 표시(`downloading speech model...`, `transcribing me track` 등, 기존
  `onProgress` 콜백 그대로 사용). 끝나면 전사본 미리보기 자동 갱신.
- **설정 시트** (`SettingsSheetView`, 세션 목록 툴바 "설정" 버튼)
  - 언어 선택 (Q7) — 일본어/한국어/영어 피커. 0단계에서 실제 검증된 세 로케일만 노출
    (검증 안 된 로케일을 고를 수 있게 하면 "일본어인 줄 알았는데 안 됨" 혼란만 생김).
    새 녹음부터 적용, 기존 세션 안 건드림.
  - 저장 폴더 변경 (Q9) — `NSOpenPanel`로 디렉토리 선택 → `SessionStore.setRootDirectory`.
    새 녹음부터 적용, 기존 세션은 원래 위치 그대로(원래 계약).
- **세션 이름 변경** (Q10) — 세션 상세 화면 제목이 편집 가능한 `TextField`. 폴더명(안정적
  ID)은 안 건드리고 `session.json`의 `displayName`만 바뀜.

## 실제 발견한 버그 1건

`Transcriber.transcribe`의 `onProgress` 콜백을 GUI에서 넘길 때 Swift 6 동시성 에러:
"sending value of non-Sendable type '(String) -> Void' risks causing data races". CLI에서는
안 걸렸는데(top-level 코드라 격리 추론이 다름) `@MainActor` 클래스(`AppState`) 메서드
안에서 만든 클로저를 nonisolated static 함수로 넘기니까 걸림. `onProgress` 파라미터
타입을 `(@Sendable (String) -> Void)?`로 바꿔서 해결(`ensureInstalled` 내부 헬퍼도 같이).

## 검증

- 25개 테스트 그대로 통과 (로직 자체는 안 건드림, 시그니처만 변경)
- 재빌드 후 재실행, 3초 후에도 살아있음, 새 크래시 리포트 없음

## 확인 못 한 것

이 에이전트는 클릭을 못 한다. 버튼 배치, 시트가 실제로 뜨는지, `NSOpenPanel`이 정상
동작하는지, 전사 진행 중 텍스트가 실제로 업데이트되는지는 전부 사용자가 직접 클릭해서
확인해야 한다. 로직(Transcriber/TranscriptBuilder/FLACConverter)은 이미 CLI로 검증됐고,
이번에 바뀐 건 그걸 호출하는 SwiftUI/AppState 배선뿐이다.
