# 2단계 검증 결과 (2026-08-09)

목표: `Session` + 크래시 복구 + `RyokuonApp` + `Permissions`. 원클릭 시작/종료, 레벨 미터, 무음 경고.

## 코드 구조

- `Session.swift` — 세션 모델 + `SessionStore`(저장 경로 Q9, 세션 생성/조회/크래시 복구 Q11)
- `SilenceWatchdog.swift` — Q18 로직. CoreAudio 의존성 없는 순수 클래스라 실제 오디오 없이 유닛테스트 가능
- `Permissions.swift` — 3단계 순차 온보딩(Q14). 마이크는 `AVCaptureDevice`로 상태 조회 가능하지만, 오디오 캡처·저장폴더 접근은 조회 API가 없어서 "이번 실행에서 시도해서 성공했는지"로 추적
- `AppState.swift` — 녹음 상태, 레벨, 무음 경고, 세션 목록을 묶는 단일 소스
- `RyokuonApp.swift` — 메뉴바 + 창(자세한 내용은 아래 "발견한 문제" 참고)
- `Views.swift` — 온보딩 화면 + 세션 목록 + 레벨 미터(막대)

## 자동 테스트 — 14개 전부 통과

```
✔ SilenceWatchdog × 5   (마이크만 무음 / 임계값 전 미발동 / 양쪽 신호 있음 / 대화중 침묵은 무시 / 1회만 발동)
✔ WAVWriter × 4         (1단계에서 작성)
✔ SessionStore × 5      (JSON 저장/로드, 같은 분 충돌 처리, 크래시 복구 e2e, 종료된 세션 무시, 최신순 정렬)
```

`SessionStore` 테스트 작성 중 실제 버그 하나 발견: `JSONEncoder`의 `.iso8601` 전략이 밀리초를
버려서, 같은 초에 생성된 두 세션이 `createdAt`이 동일해지고 정렬이 파일시스템 열거 순서에
의존하게 됨(`listSessionsSortsNewestFirst` 테스트가 실제로 이 버그를 잡아냄 — 재현성 있게
실패했음). `ISO8601DateFormatter` + `.withFractionalSeconds`로 교체해 해결.

## e2e 크래시 복구 검증 — 실제 kill -9로 통과

CLI에 `crash-during`(정상 종료 없이 녹음하다 죽는 걸 재현) + `recover`(복구 명령) 추가.

```
1. afplay로 톤 재생 시작
2. Ryokuon crash-during으로 3초간 녹음 시작
3. kill -9로 강제종료 (session.json은 "recording" 상태로 남음, WAV 헤더는 0바이트)
4. Ryokuon recover 실행
   → "recovered 1 session(s), 2026-08-09_1048: 2.207625s, state=recovered"
5. afinfo로 재생 가능 확인, 톤 신호 정상 재생됨
```

크래시 직후 상태 확인:
```
declared data bytes: 0        (헤더 안 패치됨)
actual file size: 70688       (PCM은 디스크에 살아있음)
```
복구 후:
```
declared data bytes: 70644    (70688 - 44바이트 헤더 = 정확히 일치)
```

## 발견한 문제 — MenuBarExtra가 렌더링되지 않음, AppKit NSStatusItem으로 교체

SwiftUI `MenuBarExtra`로 처음 만들었을 때, 앱은 정상 실행되고 상태 아이템이
**Accessibility 트리에는 정확한 위치·크기로 등록**됐지만(`System Events`로 확인),
**화면에는 픽셀이 전혀 그려지지 않았다**. `Text` 라벨과 `Image(systemName:)` 라벨 둘 다
같은 증상. 스크린샷을 대비 3배·밝기 2배로 보정해도 흔적 없음. 껐다 켜서 재현 확인(우연한
타이밍 문제 아님).

같은 화면 안의 다른 앱(블루투스 아이콘 등)은 정상적으로 캡처됐으므로 스크린샷 도구 자체
문제는 아니다.

**조치**: `MenuBarExtra` Scene을 걷어내고 전통적인 `NSStatusItem`(`NSApplicationDelegateAdaptor`
경유)으로 교체. `NSApp.setActivationPolicy(.accessory)`도 추가— 원래는 창이 있는 일반 앱처럼
Dock 아이콘과 "Ryokuon/Edit/View/Window/Help" 앱 메뉴가 떠 있었는데, 메뉴바 유틸리티(Q1
취지)에는 안 맞아서 같이 고쳤다.

**교체 후에도 내 스크린샷 파이프라인에서는 여전히 아이콘이 안 보임.** Accessibility로는
프레임이 잡히는데(24×24, 텍스트일 때와 다른 크기로 정확히 갱신됨 — 실제로 다시 그려지고
있다는 증거) 픽셀은 안 보임. AppKit 표준 API로 바꿨는데도 같은 증상이라는 게 중요한
단서다 — SwiftUI만의 문제가 아니라, **이 자동화 환경의 스크린샷 경로가 새로 만든/서명된
GUI 앱의 특정 레이어를 못 잡는 문제일 가능성**이 있다(다른 기존 앱들은 같은 스크린샷에서
멀쩡히 나옴). 이건 제가 화면을 못 봐서 생기는 한계지, 사용자 화면에서도 같은 문제라는
보장은 없다.

**확인 필요**: 지금 `Ryokuon.app`이 실행 중임(pid는 세션마다 바뀜). 메뉴바 오른쪽,
블루투스·배터리 아이콘 근처에서 파형 모양(waveform) 아이콘이 보이는지 사용자가 직접
확인해줘야 함. 안 보이면 진짜 렌더링 버그이고, 보이면 제 스크린샷 파이프라인만의
한계였던 것.

## CLI 확장 (개발/검증용, 배포용 `bin/ryokuon`과는 다름)

- `ryokuon crash-during <bundleID|pid:N> <seconds> <storageRoot>` — 크래시 재현
- `ryokuon recover <storageRoot>` — 크래시 복구 실행

이 CLI 훅은 `main.swift`에 계속 남겨둠 — GUI 메뉴/버튼 클릭은 제가 직접 할 수 없어서,
캡처·세션·크래시 복구를 실제로 검증하는 유일한 경로이기 때문. `RyokuonApp.main()`을
인자 없을 때 수동 호출하는 방식으로 GUI와 공존.

## 남은 확인 사항 (사용자 확인 필요)

- **메뉴바 아이콘이 실제로 보이는지** (위 "발견한 문제" 참고)
- 3단계 권한 온보딩 화면 UI가 실제로 잘 뜨는지, "허용 요청" 눌렀을 때 시스템 권한
  다이얼로그가 정상적으로 뜨는지 — 네이티브 다이얼로그라 제가 클릭할 수 없음
- 세션 목록 창이 "세션 목록 열기" 메뉴 클릭으로 정상적으로 뜨는지
