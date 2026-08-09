# 1단계 검증 결과 (2026-08-09)

목표: 앱 선택 → 녹음 → 16kHz WAV 2개. `AudioProcessList` + `AudioCapture` + `WAVWriter`.

## 빌드 전환

`.xcodeproj` 대신 SwiftPM (계획대로). `swift-tools-version:6.2`로 올려야
`platforms: [.macOS(.v26)]`가 컴파일된다(6.0에서는 `.v26`이 없음).

Info.plist는 `Package.swift`의 `linkerSettings.unsafeFlags`로 `__TEXT,__info_plist` 섹션에
직접 심는다 — `.xcodeproj` 없이도 TCC가 번들 ID·권한 설명 문구를 읽을 수 있다.

## 코드 구조

- `AudioProcessList.swift` — CoreAudio 프로세스 열거. `bundleID`는 신뢰하지 말 것(0단계에서
  번들 없는 프로세스에 엉뚱한 값이 나오는 걸 확인함) — `pid`가 진짜 식별자
- `CaptureDevice.swift` — 탭 + Aggregate. `sampleRate`를 런타임에 읽음(하드코딩 금지, 0단계에서
  확인한 대로)
- `RingBuffer.swift` — IOProc(실시간 스레드)에서 쓰고 별도 큐가 읽는 고정 크기 링버퍼.
  `os_unfair_lock` + 사전 할당 배열. 오버플로 시 오래된 샘플 버림(멈추는 것보다 나음)
- `AudioCapture.swift` — IOProc은 복사만, 200ms 타이머가 링버퍼를 비워 `AVAudioConverter`로
  16kHz Int16 변환 후 `WAVWriter`에 append. dB 레벨도 이 타이밍에 공짜로 계산(Q18에서 씀)
- `WAVWriter.swift` — 크래시 세이프 헤더(Q11). `finish()` 전까지 헤더는 0바이트로 남아있고,
  `repairHeader(at:)`가 파일 실제 크기로 재계산. 테스트 4개로 검증(아래)

## 자동 테스트 — 통과

```
✔ normalFinishProducesCorrectHeader
✔ crashedRecordingIsRecoveredByRepairHeader   ← finish() 안 부르고 크래시 시뮬레이션 → 복구 확인
✔ repairOnEmptyFileDoesNothing                ← 헤더조차 없는 파일에서 안 죽는지
✔ packageBuilds
```

## 3분 녹음 검증 — 통과 (재시도 끝에)

### 첫 시도 실패 — 원인은 테스트 도구, 레코더 아님

`scratch/play-to-device`(AVAudioEngine 기반 테스트용 재생기)로 첫 시도했다가 중간에
`remote` 트랙이 통째로 무음이 됐다. 조사 결과:

- 녹음 도중 AirPods가 기본 출력/입력으로 라우팅되면서 CoreAudio가 재구성 이벤트를 발생시킴
- `play-to-device`는 AVAudioEngine으로 짠 도구라 이 이벤트에 대응하는 코드가 없었고,
  얼마 지나지 않아 프로세스가 통째로 죽음(크래시 리포트 없음, unified log에 marker만 남음)
- **정작 검증 대상인 Ryokuon 레코더(IOProc 기반)는 안 죽고 180초 끝까지 버텼다** —
  탭 대상 프로세스가 죽어도 레코더 자체는 계속 돌고, 그 트랙만 무음으로 기록됐을 뿐

AVAudioEngine을 0단계에서 폐기한 이유(다채널 aggregate 입력 처리 실패)와는 다른 문제지만,
같은 API가 또 한 번 문제를 일으켰다 — 장치/라우트 변경에 약하다는 패턴이 반복 확인된 셈이다.
실제 캡처 코드가 IOProc으로 간 게 다시 한번 정당화됐다.

### 재시도 — `afplay`로 교체, 통과

단순한 `afplay`(장치 재구성 이벤트에 흔들리지 않는 재생 경로)로 200초 톤을 재생하고
Ryokuon으로 180초 녹음.

```
me:     2880165 frames  (16kHz mono, 180.010초)
remote: 2880165 frames  (16kHz mono, 180.010초)   ← 프레임 수 정확히 일치

remote  -11.7 dB  3분 내내 일관
me      -38~-42 dB  AirPods 마이크의 실내 소음
```

시작(5s)·중간(90s)·끝(175s) 세 지점에서 주파수 분석으로 신호가 끊기거나 변질되지 않았음을
추가 확인.

**결론**: 3분 동안 드리프트 없이 두 트랙이 샘플 단위로 정렬 유지됨. 크래시 안전성도
자동 테스트로 확인됨.

## 남은 확인 사항 (다음 단계로 이월)

- 스테레오 마이크(외장 인터페이스)에서 다채널 de-interleave 경로 — 코드는 있으나 실측 안 함
- 링버퍼 오버플로가 실제로 발생하는 부하 조건 — 아직 못 만들어봄(정상 조건에서는 200ms
  드레인 주기가 충분히 여유 있음)
- 탭 대상 앱이 녹음 중 종료될 때 UI에 어떻게 알릴지 — Q18(무음 경고)이 2단계에서 이 역할을
  겸함
