# Ryokuon 사내(팀) 배포

## Context
팀 몇 명에게 Ryokuon을 배포하고 싶다. 답변 기준 환경:
- 회사 Mac은 각자 관리(MDM 없음), 대부분 Apple 칩 + macOS 26
- 코드·설치 파일은 지금 공개 레포(github.com/younnieCutler/ryokuon) 그대로

→ 이미 만든 `curl … install.sh | bash` 한 줄 설치가 그대로 사내 배포 수단이 된다.
curl로 받은 파일은 격리 표시(quarantine)가 없어 공증 없이도 경고 없이 열리므로,
Developer ID·DMG·MDM 패키지는 이 규모에선 불필요. 남은 건 (1) 머지된 PR #1 수정을
릴리스로 내보내기, (2) 동료용 안내뿐.

## 구현

### 0. 기록 (CLAUDE.md 플랜 종료 규칙 — 플랜 모드에선 쓰기 불가라 첫 단계로)
- memory: `project_ryokuon_team_distribution.md` — 팀 배포는 curl 설치(공개 레포, MDM 없음), 0.1.2부터 + MEMORY.md 한 줄
- `plan/2026-10-03-team-distribution.md`에 이 계획 복사

### 1. v0.1.2 릴리스
- `Resources/Info.plist`: `CFBundleShortVersionString` 0.1.2, `CFBundleVersion` 3 (PlistBuddy)
- `swift test` 통과 확인 → 커밋·main 푸시
- `RYOKUON_SIGN_IDENTITY=<Apple Development> bash Scripts/make_release.sh --publish` (기존 스크립트 그대로)

### 2. 동료 안내 (코드 변경 없음)
README(일본어)에 이미 설치·업데이트·삭제·첫 실행 권한이 있으므로 새 문서는 만들지 않는다.
팀 채널에 붙여 넣을 짧은 안내문(일본어/한국어)만 응답으로 제공:
- 설치 한 줄, 요구 사양(Apple 칩·macOS 26), 첫 실행 권한 3개, 업데이트 = 같은 명령 재실행
- 첫 텍스트 변환 시 음성 모델 다운로드(인터넷 필요)
- 녹음 전 상대 동의 등 회사 녹음 정책 확인 권고(앱이 아니라 사용 규칙 문제)

## 하지 않는 것
- Developer ID 서명·공증·DMG·pkg: 팀 소규모 + curl 설치라 불필요. 외부 배포/MDM 도입 시 재검토 (make_release.sh 헤더 주석에 경로 있음)
- 앱 내 업데이트 알림: 몇 명이면 "같은 명령 재실행"으로 충분
- 회사 비공개 레포 이전: 현재 공개 레포 유지 결정

## 알려둘 위험
- 개인 Apple Development 인증서로 서명 → 인증서 만료(1년) 후 새 릴리스는 새 인증서로 빌드해야 함. 이미 설치된 앱은 curl 설치라 계속 실행됨
- Intel Mac·macOS 25 이하는 install.sh가 설치 전에 안내 후 중단(이미 구현)

## 검증
1. `swift test` 전체 통과
2. 릴리스 후: `curl -sIL …/releases/latest/download/Ryokuon.zip` 200, 내려받은 zip 풀어서 `codesign --verify --deep --strict` 통과, `Info.plist` 버전 0.1.2, `Contents/Helpers/lame` 포함, quarantine 속성 없음
3. 이 Mac에서 `curl … install.sh | bash`로 업데이트 → 설치 버전 0.1.2, 앱 실행 확인(녹음 중이면 스크립트가 중단)
