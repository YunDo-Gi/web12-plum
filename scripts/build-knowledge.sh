#!/bin/bash
# Plum 지식베이스 자동 빌더 — packages/shared-interfaces의 .ts 파일을
# Dify에 업로드 가능한 마크다운으로 변환한다.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/knowledge"
mkdir -p "$OUT"

OUTFILE="$OUT/01-shared-interfaces.md"
{
  echo "# Plum 공통 타입 / 시그널링 인터페이스"
  echo
  echo "> 출처: \`packages/shared-interfaces/src\` — 빌드 스크립트가 자동 생성. 수정 금지."
  echo
  for f in "$ROOT"/packages/shared-interfaces/src/*.ts; do
    name="$(basename "$f")"
    echo "## $name"
    echo
    echo '```typescript'
    cat "$f"
    echo '```'
    echo
  done
} > "$OUTFILE"

echo "✅ Generated: $OUTFILE ($(wc -l < "$OUTFILE") lines)"
