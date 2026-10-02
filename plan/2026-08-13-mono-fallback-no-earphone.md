# 이어폰 미착용 시 모노 다운믹스 (2026-08-13)

## 문제

사용자 리포트: "이어폰 안 끼고 통화할 때도 있는데 그럼 어차피 녹음이 되잖아?" — GUI 레벨미터를 보면 이어폰 없이 통화할 때 ME(마이크)와 REMOTE(process tap) 두 채널이 동시에 활동하는 게 보임.

조사 결과 버그 아님: 이어폰 없이 통화하면 상대방 목소리가 스피커로 나갔다가 내장 마이크로 다시 들어간다(음향 누설). 레벨미터는 `AudioCapture.decibels(of:)`가 링버퍼에서 뽑은 원본 샘플의 실제 RMS를 그대로 보여주는 것 — ME 채널이 실제로 REMOTE의 누설음을 담고 있다는 걸 정확히 반영한 것이었다. `call.wav`(L=me/R=remote 스테레오 1파일, 2026-08-09 결정)에 그 에코가 영구적으로 섞여 저장된다.

## 왜 진짜 AEC는 안 했나

`CaptureDevice.swift:4-8`에 이미 기록된 이유: AVAudioEngine의 input node는 어그리게잇 디바이스에서 채널을 1개로 캡핑한다. 지금 아키텍처(ME/REMOTE를 별도 채널로 동시 캡처)와 정면 충돌 — Voice Processing I/O 붙이려면 캡처 아키텍처를 갈아엎어야 해서 범위 밖으로 판단.

## 선택한 해법

이어폰(외부 헤드셋) 미착용 = 시스템 기본 입력이 내장 마이크 → 이 경우 처음부터 모노 1채널로 녹음한다. "섞인 소리를 스테레오인 척 저장"하는 상황 자체를 없애는 쪽.

감지: `CaptureDevice.isBuiltInMicActive()` — `kAudioDevicePropertyTransportType`으로 기본 입력 디바이스가 `kAudioDeviceTransportTypeBuiltIn`인지 확인. AirPods/Bluetooth/USB는 자동으로 스테레오 경로.

트레이드오프 (사용자 확인 완료): 모노 세션은 STT 화자분리(ME/REMOTE 구분)를 포기한다. ME 채널 자체가 이미 에코로 오염돼 있어서 분리 보관해봐야 의미가 없다는 판단.

## 변경 사항

- `CaptureDevice.swift`: `isBuiltInMicActive()` static 헬퍼 추가.
- `AudioCapture.swift`: `init(channels:)` 파라미터 추가, `isMono` 프로퍼티, `drainAndWrite()`에서 모노면 `downmix(_:_:)`(L/R 평균) 사용, 스테레오면 기존 `interleave` 유지. 레벨미터는 다운믹스 전 원본 값 그대로 (실시간 표시는 안 바뀜, 녹음 파일만 합쳐짐).
- `Session.swift`: `channels: Int = 2` 필드 추가. 구버전 `session.json`(이 키 없음) 호환 위해 `CodingKeys` + 커스텀 `init(from:)`으로 `decodeIfPresent(...) ?? 2`. `createSession`이 `channels` 파라미터를 받아 세션 생성 시점에 정확한 값을 박아넣음(나중에 고치는 레이스 없음). `recoverCrashedSessions()`의 하드코딩된 `channels: 2`를 `session.channels`로 교체.
- `AppState.swift`: `start(target:)` 맨 앞에서 `CaptureDevice.isBuiltInMicActive() ? 1 : 2`로 채널 수 결정, `createSession`/`AudioCapture` 양쪽에 전달.
- `Transcriber.swift`: `transcribe()`가 파일 채널 수를 먼저 확인. 1채널이면 새 `readMonoChannel()` 경로로 단일 트랜스크라이버 실행, `speaker: "U"`(unified)로 태깅. 2채널은 기존 M/R 분리 경로 그대로. `Views.swift`는 무수정 — 화자 색상 로직이 `"M"`이 아니면 전부 `.secondary`라 `"U"`도 자연스럽게 표시됨.
- `main.swift`: dev CLI(`record`/`crashDuring`)도 동일하게 `isBuiltInMicActive()`로 채널 수 결정하도록 맞춤 — 실기기에서 모노 경로도 CLI로 검증 가능.

## 손대지 않은 부분

- `WAVWriter.swift`: 이미 mono/stereo 범용 구조라 무수정.
- `Player.swift`: `channelCount == 2` 가드가 이미 mono 파일에서 안전하게 조기 리턴 — mono 세션에서 ME/REMOTE 게인 슬라이더는 그냥 안 먹는다. UI에서 슬라이더 자체를 숨기는 건 요청 없어서 안 함.

## 검증

- `swift build` 통과 확인 (2026-08-13).
- 실기기 검증(이어폰 유/무 각각 녹음 → 채널 수 확인, 모노 세션 STT → `raw.json`에 `speaker: "U"` 확인, 크래시 복구 경로)은 다음 실기기 세션에서 진행 예정.

## 후속: 입출력 장치 수동 선택 (2026-08-20)

이 문서의 감지 로직(`isBuiltInMicActive`)은 항상 시스템 기본 입력만 봤다 — 이어폰(AirPods) 마이크가 기본 입력이 되면 무조건 스테레오 경로로 갔고, "이어폰으로 듣되 입력은 노트북 내장 마이크로" 같은 조합은 선택할 수 없었다. Settings에 입력/출력 장치 Picker를 추가해 시스템 기본값을 오버라이드할 수 있게 함.

- `AudioIODevice.swift`(신규): `listInputDevices()`/`listOutputDevices()`/`deviceID(forUID:)` — `kAudioHardwarePropertyDevices` 순회, 채널 수 판별은 `CaptureDevice.channelCount(...)` 재사용.
- `CaptureDevice.swift`: `init(tapping:micDeviceUID:)`, `isBuiltInMicActive(deviceUID:)` — 둘 다 `micDeviceUID`/`deviceUID` 파라미터 기본값 nil로 추가. 넘기면 그 UID로 마이크 오버라이드(모노/스테레오 판단도 오버라이드된 마이크 기준), nil이거나 UID 해석 실패 시 기존처럼 시스템 기본 입력.
- `AudioCapture.swift`: `init(...micDeviceUID:)` 통과.
- `Player.swift`: `outputDeviceUID` 세팅 시 `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`로 재생 출력 강제 지정, 값 바뀔 때만 엔진 stop 후 재구성.
- `AppState.swift`: `selectedMicDeviceUID`/`selectedOutputDeviceUID`(UserDefaults, `""`=시스템 기본값), `availableInputDevices()`/`availableOutputDevices()`, `currentMicrophoneName`이 오버라이드 반영, `start(target:)`/`play(_:from:)`에서 선택값 전달.
- `Views.swift`: `SettingsSheetView`에 입력/출력 장치 Picker 2개 추가(시트 높이 380→480).
- `main.swift`/`Permissions.swift`(CLI 경로): 무수정 — 새 파라미터 전부 기본값 nil이라 기존 호출 그대로 컴파일.

검증: `swift build` 통과(2026-08-20). 실기기에서 마이크/출력 장치 전환 동작은 미검증 — 다음 실기기 세션 과제.

## 후속: 녹음 중 입력 장치 실시간 전환 (2026-08-20)

Settings/좌측 하단 마이크 메뉴는 녹음 시작 전에만 먹혔다 — 녹음 도중엔 못 바꿈. `CaptureDevice`/`AudioCapture`에 라이브 스위칭 추가.

- `CaptureDevice.swift`: 마이크·아그리게잇 생성 로직을 `resolveMic(uid:)`/`makeAggregateDevice(micUID:tapUID:)` static 헬퍼로 추출(init과 재사용). `switchMic(toUID:)` 추가 — tap은 그대로 두고 새 마이크로 아그리게잇 재생성, 끝나면 기존 아그리게잇 파괴. `micChannels`/`sampleRate`를 `let`→`private(set) var`로 변경(마이크 바뀌면 채널 수·샘플레이트도 바뀔 수 있어서).
- `AudioCapture.swift`: IOProc 생성 로직을 `startIOProc()`으로 추출(start()/switchMicDevice 공용). `switchMicDevice(uid:)` — 기존 IOProc 정지·파괴 → `device.switchMic(toUID:)` → `micRange`/`tapRange` 새 채널 수로 재계산 → `startIOProc()`. **세션의 모노/스테레오 채널 수(WAV 헤더)는 절대 안 바꿈** — 녹음 시작 시 고정된 값 유지, 마이크 전환은 그 채널을 채우는 물리 장치만 바꿈(안 그러면 파일 중간에 채널 레이아웃이 깨짐).
- `AppState.swift`: `selectedMicDeviceUID` setter가 `isRecording`이면 `capture.switchMicDevice(uid:)`를 바로 호출 — Settings/좌측 하단 메뉴 어느 쪽에서 바꾸든 녹음 중이면 즉시 라이브 전환. 실패 시 `errorMicSwitchFailed`로 에러 표시(장치 자체는 이전 것 유지).
- `Views.swift`: 좌측 하단 마이크 메뉴(`MicDeviceMenu`)를 녹음 중 화면(레벨미터 위)에도 추가 — 이제 녹음 전/중 둘 다 같은 컴포넌트로 마이크 바꿀 수 있음.
- 스위칭 순간 mic/tap 두 트랙 모두 짧은 무음 구간 발생(아그리게잇 파괴·재생성이 즉시 처리되진 않음) — 클릭음/크래시 대신 순간 무음으로 처리되게만 함, 매끄러운 크로스페이드는 범위 밖.

검증: `swift build` 통과(2026-08-20). 실기기에서 녹음 중 전환 시 무음 구간 길이·WAV 무결성은 미검증.

### 버그: 전환 후 피치 틀어짐 (실기기 리포트, 같은 날 수정)

`AudioCapture`의 `sourceFormat`/`meConverter`/`remoteConverter`가 최초 마이크의 샘플레이트로 고정된 채 재생성되지 않았음 — 아그리게잇 레이트는 메인 서브 디바이스(마이크)를 따라가므로(`CaptureDevice` 기존 주석 참고, 내장 48kHz vs AirPods 24kHz), 전환 후에도 옛 레이트를 가정한 컨버터가 새 레이트로 들어오는 샘플을 잘못된 비율로 리샘플 → 피치 시프트.

수정: `sourceFormat`/`meConverter`/`remoteConverter`를 `let`→`private var`로 바꾸고, `switchMicDevice(uid:)`에서 `device.sampleRate`가 바뀌었으면 셋 다 재생성. `convert()`가 오직 `drainQueue`에서만 도는 것과 동일한 큐에서 `drainQueue.sync { }`로 교체해 레이스 방지. `swift build` 통과(2026-08-20), 실기기 청음 검증은 다음 세션 과제.
