# 5단계 검증 결과 (2026-08-09)

목표: `Player`(재생 + 트랙별 게인) + `Views` 슬라이더 + FLAC 변환(CoreAudio 내장 인코더).

## 구현

- `Player.swift` — `AVAudioEngine` + `AVAudioPlayerNode`. 재생 직전 파일 전체를 메모리로
  읽어 L(me)/R(remote) 채널에 각각 게인을 곱한 뒤(`vDSP_vsmul`) 스케줄. 원본 파일은
  `AVAudioFile(forReading:)`로만 열어서 구조적으로 쓰기 경로 자체가 없음 — 비파괴가
  코드 설계로 보장됨(런타임에 슬라이더로 검증할 필요 없이, 애초에 쓰기 API를 안 씀).
- `Session.swift`에 `SessionStore.directory(for:)` 추가 — 세션 ID→경로 변환을 한 곳에 모음.
- `AudioCapture.swift`에 `audioFileURL(in:)` 추가 — call.wav 있으면 그거, 없으면 call.flac.
  Transcriber/Player 둘 다 이걸 통해서만 오디오 파일을 찾음.
- `Views.swift` — 세션 목록에 `NavigationStack`/`NavigationLink` 추가, `SessionDetailView`에
  재생 버튼 + 게인 슬라이더 2개(나/상대, 0.25x~3.0x) + 전사본 미리보기.
- `Transcriber.swift` — Q4가 "재생 **+ STT** 시점에 게인 적용"이라고 명시했는데 원래
  구현은 재생에만 게인을 쓰고 있었다. 발견하고 STT 채널 읽은 직후 `vDSP_vsmul`로 게인
  적용 추가.
- `FLACConverter.swift` — call.wav → call.flac, 검증 후 원본 삭제.

## 실제 발견한 버그 2건 (FLAC 변환)

1. **`write(from:)`가 paramErr(-50)** — `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`의
   `commonFormat`/`interleaved`는 "이 파일에 쓸 버퍼의 포맷"을 뜻하는데, 처음엔
   `.pcmFormatInt16, interleaved: true`로 만들어놓고 실제로는 `source.processingFormat`
   (float32, non-interleaved) 버퍼를 넘겨서 불일치로 실패. destination 생성 시
   `commonFormat`/`interleaved`를 `source.processingFormat`에서 그대로 가져오도록 수정.
2. **변환 직후 검증하려고 같은 경로를 또 열면 'fmt?' 에러** — 쓰기용 `AVAudioFile`
   (`destination`)이 아직 스코프 안에 살아있는 상태에서 같은 파일을 읽기용으로 다시 열면
   컨테이너가 아직 finalize 안 돼서 열기 자체가 실패(`kAudioFileUnsupportedDataFormatError`).
   신기하게도 `afinfo`(별도 프로세스)는 디스크에 있는 그대로를 문제없이 읽음 — 파일은
   멀쩡한데 "같은 프로세스 안에서 쓰기 핸들이 살아있는 채로 읽기 핸들을 또 여는 것"만
   문제. 쓰기 로직을 별도 함수로 빼서 `destination`이 함수 리턴과 함께 스코프를 벗어나게
   (= deinit되면서 파일이 닫히게) 고쳐서 해결.

## 실제 세션으로 검증 (2026-08-09_1126)

```
$ md5 call.wav (변환 전)   = 95a2ac23b1f00345475df4f25cdbb02d
$ ryokuon transcribe ... (raw.json 재생성 + FLAC 자동 변환)
converted -> .../call.flac

$ afinfo call.flac
Data format: 2 ch, 16000 Hz, flac, ...
estimated duration: 13.558500 sec   ← call.wav와 정확히 일치

call.wav: 867788 bytes → call.flac: 317333 bytes  (약 63% 감소, Q3 "절반" 목표 이상)
call.wav는 검증 성공 후 정상적으로 삭제됨
```

## 게인이 STT 결과에 실제로 영향 주는지 검증

`/tmp`에 세션을 복사해서 `remote` 게인을 0.03(거의 무음 수준)으로 바꾸고 재전사:

```
gain=1.0  R평균 confidence 0.869, "결정일 수 같고..."
gain=0.03 R평균 confidence 0.873, "결정일 것 같고..." (단어 2곳 다르게 인식, "않은데."로 종결부호도 달라짐)
```

단어 인식 결과가 실제로 달라짐 — 게인이 겉보기만이 아니라 STT 입력 자체에 반영되는 것
확인. (0.03까지 낮췄는데도 confidence가 거의 안 떨어진 건 Apple 온디바이스 모델이 입력
레벨을 내부적으로 정규화하는 것으로 보임 — 예상보다 강건하다는 뜻이지 게인이 안 먹힌다는
뜻은 아님. 텍스트가 실제로 바뀐 게 그 증거.)

## 확인 못 한 것 (정직하게 남김)

- **GUI 슬라이더/재생 버튼을 실제로 클릭해서 눈으로 본 적 없음.** 이 에이전트는 클릭을
  할 수 없다. 앱이 새 코드로 크래시 없이 뜨는 것(재빌드 후 재실행, 3초 후에도 살아있음,
  새 크래시 리포트 없음)까지는 확인했지만, `NavigationStack`/슬라이더 UI가 화면에 정상
  렌더링되는지는 사용자가 직접 봐야 함.
- 비파괴성은 런타임 체크섬 비교 대신 **코드 구조**로 증명함(`Player`가 파일을 읽기
  전용으로만 엶 — 쓰기 API 호출 자체가 없음). 슬라이더를 실제로 조작한 뒤 체크섬을 다시
  찍어보는 런타임 검증은 GUI 클릭이 필요해서 못 했음.
- 3분+ 긴 녹음 FLAC 변환 성능/메모리, 일본어 모델 다운로드, 일본어 필러 — 3·4단계 때부터
  계속 열려있던 항목, 아직 그대로.
