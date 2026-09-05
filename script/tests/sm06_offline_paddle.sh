#!/bin/zsh
set -euo pipefail

# This lane requires explicit, previously copied fixtures. Never discover a
# user's environment or download a model while attempting to make the Gate pass.
if [[ -z "${SM06_PADDLE_RUNTIME_FILE:-}" || ! -f "$SM06_PADDLE_RUNTIME_FILE" ]]; then
  print -u2 'missing required tool/environment: SM06_PADDLE_RUNTIME_FILE offline fixture'
  exit 127
fi
python3 - "$SM06_PADDLE_RUNTIME_FILE" <<'PY'
import json,hashlib,sys
from pathlib import Path
value=json.loads(Path(sys.argv[1]).read_text())
for key in ['python','cache','work','home']:
    if not Path(value[key]).exists():
        print('missing required tool/environment: isolated Paddle '+key,file=sys.stderr);sys.exit(127)
# Hashes refer to the explicitly copied test models, never the source cache.
for relative,expected in value['models'].items():
    path=Path(value['cache'])/relative
    if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
        print('assertion failed: offline Paddle model fixture hash mismatch',file=sys.stderr);sys.exit(1)
print('Offline Paddle model files verified:',len(value['models']))
PY
# --disable-sandbox only disables SwiftPM's nested manifest sandbox. The outer
# OS policy remains inherited by Python/native code and denies all networking.
SM06_PADDLE_GATE=1 /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  swift test --disable-sandbox --skip-build --filter PaddleProcessTests/testOfflineActualPaddlePrewarmTwiceAndClose
