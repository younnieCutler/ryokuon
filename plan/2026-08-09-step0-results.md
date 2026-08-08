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

## 환경 정정 2건

앞선 조사에서 잘못 파악한 것:

1. **BlackHole 2ch가 설치돼 있다.** `command -v blackhole`로 확인했는데 이건 무의미했다 — 드라이버지 CLI가 아니다. 다만 우리 방식에는 여전히 불필요하다.
2. **eqMac이 기본 출력 장치다.** 모든 출력을 가로채는 가상 장치. 이번 테스트는 정상 동작했지만, 사용자가 eqMac을 끄거나 출력 장치를 바꿀 때 탭이 어떻게 반응하는지는 미확인.

현재 오디오 장치 구성:
- 기본 입력: MacBook Pro 마이크 (1채널, 48kHz)
- 기본 출력: MacBook Pro 스피커 (eqMac) — 가상 장치 경유
- 그 외: BlackHole 2ch

## 남은 확인 사항

- 마이크가 스테레오인 장치(외장 인터페이스 등)에서 채널 맵이 맞는지 — 코드는 런타임에 읽으므로 대응은 돼 있으나 실측 안 함
- 출력 장치 변경 시 탭 동작
- 탭 대상 앱이 녹음 중 종료·재시작할 때 동작
