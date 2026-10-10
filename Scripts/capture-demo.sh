#!/usr/bin/env bash
# CI-only visual evidence from the actual app, with fictional data. This script
# intentionally refuses to run on a user's Mac or write to real Documents.
set -euo pipefail
[[ "${CI:-}" == true && "${GITHUB_ACTIONS:-}" == true ]] || { echo 'run only on an isolated GitHub Actions runner' >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'pkill -x Ryokuon 2>/dev/null || true; rm -rf "$fixture"' EXIT
python3 - "$fixture" <<'PY'
import json,sys,wave,struct,math
from pathlib import Path
root=Path(sys.argv[1]); session=root/'Launch planning'/'2026-10-10_0930'; session.mkdir(parents=True)
metadata={'id':session.name,'displayName':'Release planning — next steps','language':'en-US','targetDisplayName':'Zoom','createdAt':'2026-10-10T09:30:00.000Z','state':'finished','durationSeconds':60,'channels':2,'gains':{'me':1,'remote':1},'notes':'Decision: keep recordings local.\nNext: validate the clean-Mac installer and publish a short demo.','bookmarks':[{'id':'FE9A7289-9B04-4B3B-AED4-192D16C6E861','seconds':24,'title':'Launch decision'}],'transcriptionState':'completed'}
(session/'session.json').write_text(json.dumps(metadata))
(session/'transcript.txt').write_text('0|M|Let’s review the release plan for Ryokuon.\n7000|R|The first priority is reliable recording on a clean Mac.\n15000|M|Agreed. We’ll test wired headsets, Bluetooth and recovery.\n24000|R|Keep the meeting audio on-device and make exports easy to inspect.\n34000|M|I’ve bookmarked that decision and added the next steps to our notes.\n45000|R|Then we can invite a small group of testers.\n53000|M|Let’s share the verified build and collect reproducible feedback.\n')
with wave.open(str(session/'call.wav'),'wb') as f:
    f.setparams((2,2,16000,0,'NONE','not compressed'))
    f.writeframes(b''.join(struct.pack('<hh',int(500*math.sin(i/40)),0) for i in range(960000)))
PY
session="$fixture/Launch planning/2026-10-10_0930/call.wav"
mkdir -p "$ROOT/.build/visual-evidence"
"$ROOT/.build/Ryokuon.app/Contents/Helpers/lame" --quiet -b 64 "$session" "$fixture/bundled-export.mp3"
afinfo "$fixture/bundled-export.mp3" > "$ROOT/.build/visual-evidence/bundled-mp3.txt"
defaults write dev.ryokuon.app dev.ryokuon.storageRootPath -string "$fixture"
defaults write dev.ryokuon.app dev.ryokuon.lastSelectedAudioPath -string "$session"
defaults write dev.ryokuon.app dev.ryokuon.hasOpenedLibrary -bool true
defaults write dev.ryokuon.app dev.ryokuon.appLanguage -string en
mkdir -p "$ROOT/.build/visual-evidence"
RYOKUON_UI_DIAGNOSTICS=1 "$ROOT/.build/Ryokuon.app/Contents/MacOS/Ryokuon" > "$ROOT/.build/visual-evidence/app.log" 2>&1 &
sleep 8
pgrep -x Ryokuon >/dev/null
mkdir -p "$ROOT/.build/visual-evidence"
screencapture -x "$ROOT/.build/visual-evidence/meeting-workspace.png"
