# 3단계 검증 결과 (2026-08-09)

목표: `Transcriber.swift` — `SpeechAnalyzer`/`SpeechTranscriber`로 `call.wav`의 두 채널을
각각 전사해 `raw.json`(단어 단위, 화자·시간·신뢰도)을 생성.

테스트 대상: 사용자가 한국어로 실제 녹음한 `2026-08-09_1126` 세션(13.6초, Chrome 상대방
+ 내 마이크). Q7 기본 언어는 일본어지만, 사용자가 "일단 난 한국인이라서 한국어로
테스트함"이라고 해서 CLI에 `locale` 오버라이드 인자를 추가해 `ko-KR`로 검증(session.json에
저장된 기본 언어는 그대로 둠 — 세션마다 다른 언어로 전사 요청 가능해야 하므로 어차피
필요한 기능).

## 실제 발견한 버그 2건 (구현하며 바로 잡음)

### 1. CLI async 브리지가 완전히 데드락 — `DispatchSemaphore.wait()`가 메인 스레드를 막아서

`main.swift`의 다른 CLI 커맨드는 전부 동기 함수라 문제없었는데, `transcribe`만 async라서
`Task { ... }` 실행 후 `semaphore.wait()`로 완료를 기다리는 흔한 브리지 패턴을 그대로
썼다. 실행하면 CPU 0%, 스레드 1개인 채로 영원히 멈춤(`sample`로 확인 — 메인 스레드는
`semaphore_wait_trap`에 있고 Task 클로저는 아예 스케줄조차 안 됨).

원인: `Speech.framework`가 XPC 응답을 **메인 디스패치 큐**로 전달한다. `semaphore.wait()`는
스레드를 OS 레벨에서 그냥 멈춰버릴 뿐 메인 큐를 드레인하지 않으므로, XPC 콜백이 큐에
쌓인 채로 절대 실행되지 않는다 — 전형적인 "메인 스레드를 동기 대기로 막으면 안 되는"
데드락.

**수정**: `semaphore.wait()` → `dispatchMain()`. `Task` 안에서 작업 끝나면 `exit(0)`/`exit(1)`
직접 호출. `dispatchMain()`은 메인 큐를 계속 드레인하면서 블록하므로 XPC 콜백이 정상 도착.

### 2. `.timeIndexedTranscriptionWithAlternatives` 프리셋이 신뢰도를 안 채워줌

프리셋 이름과 달리 `run.transcriptionConfidence`가 항상 `nil`이었다. 처음엔 눈치 못 채고
`?? 1.0` 폴백을 넣어놨는데, 35개 단어 전부 confidence가 정확히 1로 나와서 의심 → 폴백을
`-1`로 바꿔 재실행 → 전부 `-1`로 나와서 **진짜로 nil이었다는 것 확정**.

**수정**: 프리셋 대신 `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`
생성자로 `attributeOptions: [.audioTimeRange, .transcriptionConfidence]`를 명시적으로 요청.
재실행하니 confidence가 0.459~0.995로 실제 분포가 나왔고, Q13 스펙대로 0.5 미만 단어
(`영업`, 0.459)에 `?`가 정확히 붙는 것까지 확인.

## 실제 전사 결과 (한국어, 채널 분리 확인)

```
0|R|도전하신다는
3600|R| 게
3780|R| 쉽지
4019|M|아
4260|R| 않은
...
8580|R|? 영업        ← confidence 0.459, Q13대로 ? 마킹됨
8820|R| 하다가
9120|R| 직장
9420|R| 생활
9540|M| 들립니까.
```

R(상대/Chrome)은 "도전하신다는 게 쉽지 않은 결정일 수 있고... 적응도 어려우시지
않았나요... 영업 하다가 직장 생활 한다는 게 쉽지는 않은데" — 문맥이 맞는 문장으로 정상
전사. M(나)은 "아", "말", "내", "들립니까" 등 마이크 테스트하며 짧게 말한 내용과 일치.
**채널 분리가 전사 단계까지 그대로 유지됨을 확인** — ME/REMOTE를 분리하는 화자 diarization
로직이 전혀 필요 없다는 원래 설계 그대로.

## raw.json 검증

- 35 단어, `speaker`(M/R) `text` `startMs` `durationMs` `confidence` 필드 전부 채워짐
- confidence 분포: 0.459 ~ 0.995 (0.5 미만 1건)
- 세션 디렉토리에 `raw.json` 정상 생성

## 성능 (13.6초 클립, 모델은 이미 설치돼 있던 상태 — ko_KR은 0단계부터 기본 설치돼 있었음)

```
0.39s real   0.02s user   0.01s sys
peak memory footprint: 9.2MB / maximum resident set size: 24.7MB
```

13.6초 오디오를 0.39초에 처리(약 35배속). 다만 이건 **13초짜리 클립**이라 계획에 적힌
"3분 통화" 규모 검증은 아직 안 했다 — CPU/메모리가 선형에 가깝다면 문제없겠지만, 실제
3분+ 세션으로 한 번 더 확인하는 게 안전하다(4단계 이전이든 이후든).

## 남은 것 / 확인 필요

- **일본어(ja-JP) 모델은 아직 미설치** — 0단계에서 확인한 대로, 이번 테스트는 ko-KR(이미
  설치됨)로만 검증했다. Q7 기본 언어인 일본어로 실제 다운로드 흐름(`AssetInstallationRequest`)까지
  타는 건 아직 실사용으로 검증 안 됨. 다운로드 진행률 로그(`downloading speech model (N%)`)는
  찍히게는 해놨지만 실제 다운로드가 도는 걸 본 적은 없음(ko-KR이 이미 있어서 스킵됨).
- **긴 녹음(3분+) CPU/메모리** — 위 참고
- **일본어 필러(えっと 등) 실제 출력 여부** — 계획에 적힌 대로 4단계 전에 일본어로도 한 번
  검증 필요 (원래 열어둔 질문)
