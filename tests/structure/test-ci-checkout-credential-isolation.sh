#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOWS="$ROOT/.github/workflows"
RELEASE="$WORKFLOWS/release.yml"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

CHECKOUTS="$(grep -RhE 'uses: actions/checkout@' "$WORKFLOWS"/*.yml | wc -l | tr -d ' ')"
NON_PERSISTED="$(grep -RhE 'persist-credentials:[[:space:]]*false' "$WORKFLOWS"/*.yml | wc -l | tr -d ' ')"
if [ "$CHECKOUTS" -gt 0 ] && [ "$NON_PERSISTED" -eq "$CHECKOUTS" ]; then
  check "every checkout drops the injected Git credential before tests and evals" PASS
else
  check "checkout credential isolation (checkouts=$CHECKOUTS non-persisted=$NON_PERSISTED)" FAIL
fi

PUSH_LINE="$(grep -nF -- '- name: Push release branch + print PR link' "$RELEASE" | cut -d: -f1)"
PUSH_BLOCK="$(sed -n "${PUSH_LINE},$((PUSH_LINE + 18))p" "$RELEASE")"
if printf '%s\n' "$PUSH_BLOCK" | grep -Fq 'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' \
  && printf '%s\n' "$PUSH_BLOCK" | grep -Fq 'gh auth setup-git' \
  && printf '%s\n' "$PUSH_BLOCK" | grep -Fq 'git push -f origin "$BR"'; then
  check "release push receives Git authority only in its dedicated step" PASS
else
  check "release push uses a step-scoped Git credential" FAIL
fi

if awk '
  /- name: Install exact Codex runtime without model credentials/ {
    inside = 1; installs += 1; next
  }
  inside && /^[[:space:]]+- name:/ { inside = 0 }
  inside && /(CODEX_AUTH|GH_TOKEN|GITHUB_TOKEN|secrets\.)/ { leaked = 1 }
  END { exit !(installs == 2 && !leaked) }
' "$RELEASE"; then
  check "dependency and Codex runtime installation cannot read model or Git credentials" PASS
else
  check "runtime installation is isolated from every model and Git credential" FAIL
fi

if awk '
  /- name: Exact-SHA Session Control (release|publish) gate/ {
    inside = 1; gates += 1; next
  }
  inside && /^[[:space:]]+- name:/ { inside = 0 }
  inside && /(npm ci|npm install)/ { install = 1 }
  END { exit !(gates == 2 && !install) }
' "$RELEASE"; then
  check "model-authenticated gates never execute package installation" PASS
else
  check "model-authenticated gates contain no package installation" FAIL
fi

printf '%s\n' "----" "test-ci-checkout-credential-isolation: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
