# 4단계 검증 결과 (2026-08-09)

목표: `TranscriptBuilder`(단어 → 발화 병합, Q12/Q13) + `bin/ryokuon`(list/show/search/range, Q8).

## 자동 테스트 — 25개 전부 통과 (9개 신규)

```
✔ TranscriptBuilderTests × 9
  mergesWordsUnderTwoSecondGap / splitsOnTwoSecondOrLongerGap  (2초 경계 정확히 검증 — 1900ms/2000ms)
  speakerCrossingDoesNotBreakSameSpeakerMerge                  (상대가 중간에 끼어들어도 내 발화 안 끊김)
  marksLowAverageConfidenceUtterance / doesNotMarkHighAverageConfidenceUtterance
  averagesConfidenceAcrossMergedWords                          (병합된 단어들의 신뢰도 평균)
  emptyInputProducesNoUtterances / emptyTrackForOneSpeakerIsFine
  sortsFinalUtterancesAcrossSpeakersByStartTime
✔ SilenceWatchdog × 5, WAVWriter × 6, SessionStore × 5 (기존, 계속 통과)
```

## 병합 로직 설계 노트

같은 화자의 단어를 먼저 화자별로 묶어서 자기 트랙 안에서만 2초 기준으로 병합한 뒤, 두
화자의 발화를 시작 시각으로 합쳐서 정렬한다. 상대가 중간에 끼어들어도(겹치는 발화) 내
발화의 침묵 판정에 영향을 주지 않는다 — `speakerCrossingDoesNotBreakSameSpeakerMerge`
테스트로 이 부분을 명시적으로 검증했다.

## 실제 세션으로 검증 (2026-08-09_1126, raw.json → transcript.txt)

```
$ ryokuon build /Users/macbook/Documents/ryokuon/2026-08-09_1126
2 utterances -> .../transcript.txt
0|R|도전하신다는 게 쉽지 않은 결정일 수 같고 적응도 좀 어려우시지 않았나요 당시에 어렵죠 사실은 자 영업 하다가 직장 생활 한다는 게 쉽지는 않은데
4019|M|아 아 아 아 내 말 들려 내 말 들립니까 들립니까 들립니까.
```

13.6초 클립 안에서는 화자별로 2초 이상 끊긴 구간이 없어서 발화가 각각 하나로 합쳐졌다
(예상대로 — 3단계에서 본 "영업"의 confidence 0.459는 발화 전체 평균에 희석돼 `?`가 안
붙음. Q13은 "발화별 평균"이라고 명시했으므로 스펙대로).

## `bin/ryokuon` — 실제 세션 파일로 4개 커맨드 전부 확인

```
$ ryokuon list
2026-08-09_1126
2026-08-09_1111
2026-08-09_1109_1
2026-08-09_1109

$ ryokuon search 2026-08-09_1126 "영업"
1:0|R|...영업 하다가...
2-4019|M|아 아 아...

$ ryokuon range 2026-08-09_1126 0 5000
0|R|...
4019|M|...
```

`show`/`search`/`range` 전부 정상. `RYOKUON_ROOT` 환경변수로 저장 경로 오버라이드
가능(기본값 `~/Documents/ryokuon`) — 앱의 저장 폴더 변경 설정(UserDefaults, Q9)과는
아직 안 이어져 있음(ponytail 주석으로 코드에 남겨둠, 실사용에서 문제되면 그때 `defaults`
셸아웃 추가).

## 남은 것

- 3단계에서 남겨둔 것과 동일: 3분+ 긴 녹음, 일본어 모델 다운로드 흐름, 일본어 필러 — 아직
  실사용 스케일로 검증 안 됨. 5단계 이후에 한 번 몰아서 확인 권장.
