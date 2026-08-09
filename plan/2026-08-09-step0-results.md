# 0단계 검증 결과 (2026-08-09)

계획의 두 전제를 실제 코드로 확인했다. 둘 다 통과. 검증 코드는 `scratch/`에 있다.

## 1. 음성인식 언어 지원 — 통과

`scratch/check-locales.swift` 실행 결과:

```
isAvailable: true
supported count: 30
installed count: 1

ja_JP  ✅ 지원
ko_KR  ✅ 지원 (이미 설치됨)
en_US  ✅ 지원
```

ja-JP와 en-US 모델은 미설치 상태 → `AssetInventory`로 다운로드하는 흐름이 필요하다(계획대로).

전체 지원 목록: de(AT/CH/DE), en(AU/CA/GB/IE/IN/NZ/SG/US/ZA), es(CL/ES/MX/US), fr(BE/CA/CH/FR), it(CH/IT), ja_JP, ko_KR, pt(BR/PT), yue_CN, zh(CN/HK/TW)

## 2. 두 트랙 분리 캡처 — 통과

`scratch/capture-test.swift`로 afplay가 재생하는 테스트 톤 + 내장 마이크를 6초 녹음.

```
tap format: 48000Hz 1ch Float32
aggregate: 2ch @ 48000Hz
channel map: mic=0..<1  tap=1..<2
IOProc buffer list: 2 buffer(s) — 1ch + 1ch

me      288256 frames  peak -40.5 dB   (마이크, 무발화 실내 소음)
remote  288256 frames  peak  -8.7 dB   (테스트 톤)
```

**프레임 수 정확히 일치** → 샘플 정렬 확인.

주파수 분석으로 분리 정도 검증:

| 시점 | 트랙 | 440Hz | 880Hz | 1320Hz |
|---|---|---|---|---|
| t=1s | remote | 0.1 | **5999.5** | 0.15 |
| t=1s | me | 1.19 | 0.19 | 0.18 |
| t=3s | remote | 0.1 | **5999.5** | 0.16 |
| t=3s | me | 0.29 | 0.12 | 0.03 |

remote의 880Hz 대비 me의 880Hz가 약 1/30000 → 크로스토크 없음. 완전 분리.

## 계획 변경 1건 — AVAudioEngine 제거

**계획**: Aggregate 장치를 `AVAudioEngine`에 물리고 `installTap`으로 버퍼 받기
**실제**: 동작 안 함. raw IOProc으로 변경.

`kAudioOutputUnitProperty_CurrentDevice`로 aggregate 장치(ID 155) 바인딩까지는 성공하지만, `inputNode`가 계속 1채널만 보고한다:

```
audio unit current device: 155 (wanted 155)   ← 바인딩 성공
engine inputFormat:  48000.0Hz 1ch            ← 그런데 1채널
engine outputFormat: 48000.0Hz 1ch
aggregate input channels=2                     ← 장치 자체는 2채널
```

`AVAudioEngine`이 다채널 aggregate 입력을 열어주지 않는다. `AudioDeviceCreateIOProcIDWithBlock`으로 직접 받으면 실제 버퍼 리스트가 그대로 온다. 프로세스 탭에는 이쪽이 정공법이다(Apple 샘플 코드도 IOProc 사용).

계획에 적어둔 `// ponytail: 부하 상황에서 끊기면 raw IOProc으로 내려갈 것` 조건에 부하가 아니라 시작부터 걸린 셈.

**영향**: 버퍼를 직접 다루므로 실시간 스레드 규칙을 지켜야 한다. IOProc 블록에서는 복사만 하고, 변환·디스크 쓰기는 별도 큐로 넘긴다. 현재 검증 코드는 메모리에 쌓아두는 방식이라 1단계에서 제대로 만들어야 한다.

## 3. 출력 장치 독립성 (0.5단계) — 통과

프로젝트 전제는 **가상 오디오 장치가 없는 깨끗한 맥**이다. eqMac·BlackHole을 감지하거나
우회하는 코드는 만들지 않는다. 그런데 이 개발 맥에는 둘 다 설치돼 있어서, 검증 환경이
목표 환경과 다를 수 있다는 우려가 있었다.

**먼저 정정**: 처음에 "eqMac이 기본 출력 장치"라고 판단한 건 틀렸다. `system_profiler`
출력을 잘못 읽었다. CoreAudio에 직접 물으면 기본 출력은 물리 장치다.

```
default output: [112] MacBook Pro 스피커
output devices: [53] BlackHole 2ch / [112] MacBook Pro 스피커 / [93] Microsoft Teams Audio
```

eqMac의 가상 장치는 CoreAudio 장치 목록에 아예 없다. 1·2번 검증은 이미 깨끗한 출력
경로에서 돌았던 셈이다.

확실히 하기 위해 `scratch/play-to-device.swift`를 만들어 시스템 기본 출력은 그대로 두고
**물리 장치 [112]로만 재생하는 프로세스**를 탭해봤다.

```
remote  440Hz = 5687.9    ← 톤 정상 캡처
me      440Hz =  820.9    ← 스피커 소리를 마이크가 주워담음
```

프로세스 탭은 출력 장치와 무관하게 동작한다. 확인 완료.

## 4. 이어폰 착용 시 누출 + 혼합 샘플레이트 — 통과

블루투스 이어폰(AirPods)을 입력·출력 모두로 연결하고 같은 테스트를 반복했다.

### 누출 측정

| 상황 | remote 440Hz | me 440Hz | 누출 비율 |
|---|---|---|---|
| 스피커 | 5687.9 | 820.9 | **7:1** (약 -17 dB) |
| AirPods | 4949.6 | 1.2 ~ 1.5 | **3278:1 ~ 4304:1** (약 -70 dB) |

스피커로 녹음하면 상대 목소리가 내 트랙에 -17 dB로 들어온다. 그대로 전사될 수준이다.
Q17에서 고른 "앱 골라서 녹음"은 알림음·음악 섞임은 막지만 **이 누출은 못 막는다.**

이어폰을 끼면 누출이 사실상 사라진다. **이어폰 착용이 전제**이고, 블루투스로도 충분하다.

블루투스여도 상대방 트랙 음질은 영향받지 않는다. 탭은 앱이 렌더링하는 지점에서 잡으므로
블루투스 코덱을 거치기 전 신호다(remote 440Hz가 4949로 스피커 때 5687과 같은 수준).

### 혼합 샘플레이트 — 중요

AirPods 마이크는 **1채널 24000 Hz**다. 내장 마이크(48000 Hz)와 다르고, 탭은 48000 Hz다.

```
aggregate: 2ch @ 24000.0Hz          ← 메인 서브장치(마이크) 레이트를 따라감
channel map: mic=0..<1 tap=1..<2
me     143520 frames  peak -37.6 dB
remote 143520 frames  peak  -8.7 dB
```

양쪽 143520 프레임으로 정렬됐다. CoreAudio가 48kHz 탭을 24kHz로 변환해서 넣어준다.

**설계 반영 사항**: aggregate의 샘플레이트는 48000 고정이 아니다. 메인 서브장치를 따라가므로
반드시 런타임에 `kAudioDevicePropertyNominalSampleRate`로 읽어야 한다. 목표 저장 포맷은
16 kHz 고정이므로 24k→16k(3:2), 48k→16k(3:1) 양쪽 변환이 필요하다.

아직 확인 안 된 것: AirPods 마이크의 **음질**이 STT에 충분한지. 톤으로는 측정 불가,
3단계에서 실제 발화로 확인한다.

## 발견: CoreAudio가 번들 없는 프로세스의 bundleID를 잘못 보고

`play-to-device`는 Info.plist가 없는데도 CoreAudio가 `dev.ryokuon.capture-test`를
bundleID로 보고한다(같은 디렉토리의 다른 바이너리 것). PID는 정확하다.

실제 앱에는 영향 없다 — 앱 선택 목록에는 정식 번들 앱만 뜨고, 그것들은 정확히 나온다
(`com.google.Chrome`, `com.apple.controlcenter` 등 확인). 다만 **앱 열거 시 bundleID를
신뢰의 근거로 쓰지 말고 PID와 함께 다룰 것**.

## 남은 확인 사항

- 마이크가 스테레오인 장치(외장 인터페이스 등)에서 채널 맵이 맞는지 — 코드는 런타임에 읽으므로 대응은 돼 있으나 실측 안 함
- 탭 대상 앱이 녹음 중 종료·재시작할 때 동작

## 코드 이식 시 주의

`scratch/capture-test.swift`의 CoreAudio 속성 읽기 헬퍼는 Swift 6에서 경고가 뜬다
(`forming UnsafeMutableRawPointer to Optional<CFString>`). CoreAudio Swift 바인딩의
알려진 잡음이고 동작에는 문제없다. 앱으로 옮길 때 그대로 따라오므로 감안할 것.
