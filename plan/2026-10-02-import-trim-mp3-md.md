# M4A-to-MP3.html 기능을 ryokuon에 통합

## Context
`~/Desktop/M4A-to-MP3.html`(브라우저 변환기: 파일 불러오기 · 구간 자르기 · MP3 변환 · 분석용 MD)을 따로 쓰지 않고
ryokuon 안에서 **한 흐름**으로 처리하고 싶음:

```
[녹음]  or  [M4A·MP3 불러오기] → 세션 생성 → (자동) 전사 → 구간 선택 → MP3 + MD 내보내기
```

결정 사항 (사용자 답변):
- 4개 기능 모두: 외부 파일 불러오기, 구간 자르기, MP3 내보내기, 분석용 MD
- MP3 인코딩: 이미 설치된 `/opt/homebrew/bin/lame` 호출 (CoreAudio는 MP3 인코딩 불가, 디코딩만 가능)
- 앱은 sandbox 아님 (`Resources/Ryokuon.entitlements`) → `Process`로 lame 실행 가능

## 구현

### 0. 기록 (CLAUDE.md 플랜 종료 규칙 — 플랜 모드에선 파일 쓰기 불가라 구현 첫 단계로)
- memory: `project_ryokuon_mp3_workflow.md` (lame 외부 의존, 16kHz 소스라 192k 프리셋 제외 결정) + MEMORY.md 한 줄
- `plan/2026-10-02-import-trim-mp3-md.md` 에 이 계획 복사

### 1. 외부 파일 불러오기 — `AudioImporter.swift` (신규, ~50줄)
- `AudioImporter.importFile(_ url: URL, store: SessionStore, language: String) throws -> Session`
  - `AVAudioFile(forReading:)`로 m4a/mp3/wav 디코딩 → `AVAudioConverter`로 **16kHz 모노 Int16** 변환 → 세션 폴더에 `call.wav` 작성
    (녹음 세션과 같은 포맷이라 Transcriber/Player/FLACConverter가 그대로 동작. 모노 → speaker `"U"` 경로 재사용)
  - 청크 스트리밍은 `FLACConverter.write`와 같은 패턴 재사용
  - `Session`: `channels: 1`, `state: .finished`, `targetDisplayName` = 원본 파일명, `displayName` = 확장자 뺀 파일명, `durationSeconds` = 변환 결과 길이
- `SessionStore.createSession(language:target:channels:)` → 인자를 `targetBundleID: String?, targetDisplayName: String`로 바꿔 녹음/불러오기 공용 (`AppState.start` 호출부 1곳 수정)
- `AppState.importAudio()`: `NSOpenPanel`(m4a/mp3/wav, 다중 선택) → 파일별 import → `reloadSessions()` → **각 세션 `transcribeSession` 자동 실행** (현재 `transcribeSession`은 동시 1개만 허용 → 간단한 대기열 배열로 순차 처리)
- UI: `RyokuonSplitView` 툴바에 `＋ 불러오기` 버튼, 사이드바 `List`에 `.dropDestination(for: URL.self)` 동일 동작

### 2. 구간 선택 + 내보내기 시트 — `ExportSheet` (Views.swift 내)
`SessionDetailPane` 툴바에 `내보내기` 버튼 → 시트:
- **구간**: 시작/끝 `Slider` 2개 (기본 = 전체), 각 옆에 「현재 재생 위치로」 버튼, 「▶ 구간 듣기」(`appState.play(session, from: start)` 재사용)
- **음질**: 음성 64k 모노 / 절약 96k 모노 / 일반 128k (스테레오 세션이면 스테레오)
- **출력**: MP3만 / MP3 + MD / MD만 (HTML과 동일 3택)
- 내보내기 → 세션 폴더에 `<displayName>[_mmss-mmss].mp3/.md` 작성 후 Finder에서 표시 (`NSWorkspace.activateFileViewerSelecting`)
- lame 없으면 MP3 옵션 비활성 + 「`brew install lame` 필요」 안내

### 3. MP3 인코딩 — `MP3Exporter.swift` (신규, ~60줄)
- `AudioCapture.audioFileURL(in:)`로 wav/flac 찾기 → `framePosition`을 구간 시작으로 이동해 구간만 임시 WAV로 기록 (세션 게인 `session.gains` 적용 — `Player.applyGain` 로직 재사용/공용화)
- `Process`: `lame --quiet -b <kbps> [-m m] tmp.wav out.mp3`, exit code ≠ 0이면 throw, 임시 파일 삭제
- lame 경로: `/opt/homebrew/bin/lame`, `/usr/local/bin/lame` 순서로 확인 (`static var lameURL: URL?`)

### 4. 분석용 MD — `TranscriptBuilder`에 함수 추가
- `static func markdown(_ utterances: [Utterance], title: String, session: Session, range: ClosedRange<Int>?) -> String`
  - 헤더: 제목 · 날짜 · 길이 · 언어, 본문: `- [mm:ss] **M** 텍스트` (구간이면 범위 내 발화만, 시각은 원본 기준 유지)
  - transcript.txt 파싱(`SessionDetailPane.loadTranscript`와 동일)을 `TranscriptBuilder.parse(_:)`로 옮겨 공용화
- 전사 전이면 MD 옵션 비활성

### 5. Localization
새 키(불러오기, 내보내기, 구간, 음질 3종, 출력 3종, lame 안내, 에러)를 ko/ja/en에 추가 — 기존 `L10nKey` 패턴 그대로.

## 하지 않는 것 (ponytail)
- 파형 표시 · 무음 기반 구간 자동 추천: 전사 타임스탬프가 이미 구간 기준 역할. 필요하면 추가
- 여러 구간 동시 추출: 한 번에 1구간. 필요하면 추가
- 음악 192k 프리셋: 세션 오디오가 16kHz라 의미 없음 (불러온 음악도 16kHz로 낮춰짐 — 통화·음성 전용 앱 전제)
- Whisper 엔진: 기존 Apple SpeechTranscriber 유지

## 검증
1. `swift build` 통과
2. 테스트 추가 (`Tests/RyokuonTests/`):
   - `AudioImporterTests`: AAC로 1초 사인파 m4a 생성 → import → `call.wav`가 16kHz 모노, 길이 ≈1s, session.json channels=1
   - `TranscriptBuilderTests`에 `markdown`/`parse` 케이스 (구간 필터 포함)
   - `MP3ExporterTests`: lame 없으면 skip, 있으면 2초 WAV의 0.5–1.5s 구간 → mp3 생성, `AVAudioFile`로 다시 읽어 길이 ≈1s
   - `swift test` 전체 통과
3. 실제 앱: `Scripts/bundle.sh`로 빌드·실행 → 아이폰 음성메모 m4a 드래그 → 세션 생성·자동 전사 확인 → 내보내기에서 구간 지정 + MP3+MD → Finder에 두 파일, MP3 재생 확인
