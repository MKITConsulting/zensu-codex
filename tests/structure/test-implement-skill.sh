#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_DIR="$ROOT/plugins/zensu"
SCOPE_TITLE='Required doc types (the release gate)'
REFUSAL='previous revision must be released or superseded before creating a new one'
SCOPE_ROW_RE='^[|] *(unset[^|]*|`(default|api|internal_only|public_facing)`) *[|] *`(user_facing|api_reference|adr|tutorial)`'
TAB="$(printf '\t')"

PASS=0
FAIL=0
report() {
  if [ "$1" = PASS ]; then
    echo "  PASS  $2"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $2"
    FAIL=$((FAIL + 1))
  fi
}
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

has() {
  case "$1" in
    *"$2"*) echo PASS ;;
    *) echo FAIL ;;
  esac
}
lacks() {
  case "$1" in
    *"$2"*) echo FAIL ;;
    *) echo PASS ;;
  esac
}
before() {
  T="$1" A="$2" B="$3" awk 'BEGIN {
    i = index(ENVIRON["T"], ENVIRON["A"]); j = index(ENVIRON["T"], ENVIRON["B"])
    print ((i > 0 && j > i) ? "PASS" : "FAIL")
  }'
}
count_of() {
  T="$1" N="$2" awk 'BEGIN {
    t = ENVIRON["T"]; n = ENVIRON["N"]; c = 0
    while (n != "" && (i = index(t, n)) > 0) { c++; t = substr(t, i + length(n)) }
    print c
  }'
}
all() {
  for verdict in "$@"; do
    [ "$verdict" = PASS ] || { echo FAIL; return; }
  done
  echo PASS
}
squash() { tr -s '[:space:]' ' ' < "$1"; }
section() {
  awk -v start="$2" -v stop="$3" 'index($0, start) == 1 {p = 1} p && index($0, stop) == 1 {exit} p' "$1" \
    | tr -s '[:space:]' ' '
}
scope_rows() {
  grep -rnE --include='*.md' --include='*.toml' -- "$SCOPE_ROW_RE" "$@" 2>/dev/null
}

checks_for() {
  local dir="$1"
  local skill="$dir/skills/implement/SKILL.md"
  local guide="$dir/docs/documentation-guide.md"
  local step1 step6 step7 summary cli_table norm_guide norm_skill row rule verdict others

  if [ ! -f "$skill" ] || [ ! -f "$guide" ]; then
    emit FAIL M1 "skills/implement/SKILL.md and docs/documentation-guide.md exist"
    return
  fi
  emit PASS M1 "skills/implement/SKILL.md and docs/documentation-guide.md exist"

  step1="$(section "$skill" '### Step 1:' '### Step 2:')"
  step6="$(section "$skill" '### Step 6:' '### Step 7:')"
  step7="$(section "$skill" '### Step 7:' '### Step 8:')"
  summary="$(section "$skill" '### Summary' '## Important Notes')"
  cli_table="$(section "$skill" '## CLI Commands Used' '## Agents & Skills Used')"
  norm_guide="$(squash "$guide")"
  norm_skill="$(squash "$skill")"

  verdict=PASS
  grep -qxF -- "## $SCOPE_TITLE" "$guide" || verdict=FAIL
  for row in \
    '| unset (`null`, the default) | `user_facing` | `end_user` |' \
    '| `api` | `api_reference` | `developer` |' \
    '| `internal_only` | `adr` | `internal` |' \
    '| `public_facing` | `user_facing` — **plus** `tutorial` when `estimated_effort` ∈ {L, XL} | `user_facing`→`end_user`; `tutorial`→`developer` |'; do
    grep -qF -- "$row" "$guide" || verdict=FAIL
  done
  emit "$verdict" G1 "the guide owns the '$SCOPE_TITLE' heading and its four feature_scope rows with their audiences"

  verdict=PASS
  for rule in \
    'So the scope picks the type, not the security classification' \
    'a gate that requires docs reports `documentation must be complete before release`' \
    'A response without a `feature_scope` field counts as unset: author `user_facing`' \
    'note that the `tutorial` was skipped for lack of an effort signal' \
    'A confidential backend feature with an unset scope still needs `user_facing`' \
    'a type the table does not require for the scope never completes the gate' \
    'with a required doc type from the table above'; do
    [ "$(has "$norm_guide" "$rule")" = PASS ] || verdict=FAIL
  done
  emit "$verdict" G2 "the guide states the unset-scope, unknown-effort and required-type-only rules and sends gen-context a required type"

  emit "$([ "$(grep -cE -- "$SCOPE_ROW_RE" "$guide")" = 4 ] && echo PASS || echo FAIL)" G3 \
    "the guide holds exactly one feature_scope table of four rows"

  emit "$(all \
    "$(lacks "$norm_guide" 'usually warrants `internal`')" \
    "$(lacks "$norm_guide" 'Pick the type by what the reader needs')" \
    "$(has "$norm_guide" "Every doc type the feature's \`feature_scope\` requires has its doc (Required doc types)")")" G4 \
    "the guide picks no type by classification or reader and its checklist asks for every required type"

  others="$(scope_rows "$dir/skills" "$dir/agents" "$dir/docs" "$dir/../../reference" | grep -vF -- "$guide:")"
  if [ -z "$others" ]; then
    emit PASS G5 "no skill, agent, reference or other doc keeps its own feature_scope -> doc_type table"
  else
    emit FAIL G5 "a copy of the feature_scope -> doc_type table outside the guide: $(printf '%s' "$others" | tr '\n' ' ')"
  fi

  emit "$(has "$step1" '`feature_scope` and `estimated_effort` that Step 6 picks the doc type from')" M2 \
    "Step 1's feature read names the feature_scope and estimated_effort Step 6 picks the doc type from"

  emit "$(all \
    "$(has "$step6" "The table under \"$SCOPE_TITLE\" in that guide maps the \`feature_scope\` and \`estimated_effort\`")" \
    "$(before "$step6" 'documentation-guide.md' 'The table under')" \
    "$(has "$step6" 'a feature with an unset scope needs `user_facing`, even a confidential backend feature')" \
    "$(has "$step6" 'Run the items below once per required type, with that type as every `<type>` and `--doc-type`')" \
    "$(has "$step6" '`--doc-type` (required): the required type this pass documents')" \
    "$(has "$step6" "\`--audience\` (optional): end_user | developer | admin | internal; pass the audience the guide's table gives the type")")" M3 \
    "Step 6 reads the guide, takes the required doc type(s) and audience from its '$SCOPE_TITLE' table and documents once per type"

  emit "$(all \
    "$(has "$step6" 'read `docs_complete` from `zensu features get <feature-id>`')" \
    "$(has "$step6" 'report the docs as open, never as complete')" \
    "$(before "$step6" 'zensu link docs <feature-id>' 'read `docs_complete` from')")" M4 \
    "Step 6 reads docs_complete after linking and never reports open docs as complete"

  emit "$(all \
    "$(has "$step7" "it refuses a new one with HTTP 400 \`$REFUSAL\`")" \
    "$(has "$step7" 'A new top-level feature starts with an open `v1`')")" M5 \
    "Step 7 states the backend's one-open-revision rule with its refusal text"

  emit "$(has "$step7" '**A revision is open** when `active_revision_id` is set and `stage` is neither `shipped` nor `superseded`')" M6 \
    "Step 7 calls a revision open when active_revision_id is set and stage is neither shipped nor superseded"

  emit "$(all \
    "$(has "$step7" 'Re-read the feature with `zensu features get <feature-id>` and take `active_revision_id` and `stage` from it')" \
    "$(before "$step7" 'zensu features get <feature-id>' 'zensu features revision <feature-id>')")" M7 \
    "Step 7 reads the feature before it runs zensu features revision"

  emit "$(all \
    "$(has "$step7" 'Create nothing: this work belongs to that revision')" \
    "$(has "$step7" '(stage `<stage>`) holds this work; no new revision created')")" M8 \
    "Step 7 creates nothing for an open revision and reports which one holds the work"

  emit "$(all \
    "$(has "$step7" '**No revision is open** (`stage` is `shipped` or `superseded`, or `active_revision_id` is null): run `zensu features revision <feature-id>`')" \
    "$(has "$step7" "If it still answers \`$REFUSAL\`, a revision opened in the meantime: report it as in item 2 and do not retry")" \
    "$(before "$step7" '**No revision is open**' 'zensu features revision <feature-id>')" \
    "$([ "$(count_of "$norm_skill" 'zensu features revision <feature-id>')" = 1 ] && echo PASS || echo FAIL)")" M9 \
    "the skill runs zensu features revision only in Step 7's no-open-revision branch and answers the refusal without a retry"

  emit "$(all \
    "$(has "$summary" 'Documentation linked (doc type(s) and whether `docs_complete` is `true`)')" \
    "$(has "$summary" 'Revision: the one created (version number), or the open revision this work belongs to (id and stage)')" \
    "$(has "$cli_table" '| `zensu features get` | 1, 6, 7 |')" \
    "$(has "$cli_table" '| `zensu features revision` | 7 | Create a feature revision when none is open |')")" M10 \
    "the summary and the CLI table report the docs gate and both revision outcomes"

  emit "$(all \
    "$(has "$step7" '- `--scope-summary` (required): Brief summary of what was implemented')" \
    "$(has "$step7" '`--scope-summary` and `--scope-details` are plain text')" \
    "$(before "$step7" '**No revision is open**' '`--scope-summary` and `--scope-details` are plain text')")" M12 \
    "Step 7 keeps the revision flags and the plain-text file-form recipe after the open-revision check"
}

MUT_ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$MUT_ROOT"' EXIT

OUT="$(checks_for "$PLUGIN_DIR")"
while IFS="$TAB" read -r cond id label; do
  report "$cond" "$id $label"
done <<< "$OUT"

M11_GOOD='1. Re-read with `zensu features get <feature-id>`. 3. Run `zensu features revision <feature-id>`.'
M11_LATE='Run `zensu features revision <feature-id>`, then check `zensu features get <feature-id>`.'
M11_NONE='Run `zensu features revision <feature-id>`.'
report "$(all \
  "$(before "$M11_GOOD" 'zensu features get <feature-id>' 'zensu features revision <feature-id>')" \
  "$([ "$(before "$M11_LATE" 'zensu features get <feature-id>' 'zensu features revision <feature-id>')" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(before "$M11_NONE" 'zensu features get <feature-id>' 'zensu features revision <feature-id>')" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(count_of "$M11_GOOD" 'zensu features')" = 2 ] && [ "$(count_of "$M11_NONE" 'zensu features revision <feature-id>')" = 1 ] && echo PASS || echo FAIL)")" \
  "S1 the order and count checks pass the read-first text and fail a late, a missing or a repeated command"

SCAN_FIXTURE="$MUT_ROOT/scan-fixture"
mkdir -p "$SCAN_FIXTURE/copy" "$SCAN_FIXTURE/other"
printf '%s\n' '| `api` | `api_reference` | `developer` |' > "$SCAN_FIXTURE/copy/SKILL.md"
printf '%s\n' '| `default` | `user_facing` | `end_user` |' > "$SCAN_FIXTURE/copy/rules.md"
printf '%s\n' '| `public_facing` | `tutorial` | `developer` |' > "$SCAN_FIXTURE/copy/agent.toml"
printf '%s\n' '| `api` | REST endpoints | `curl` |' '| `api` | status code, response body |' > "$SCAN_FIXTURE/other/SKILL.md"
SCAN_COPY="$(scope_rows "$SCAN_FIXTURE/copy" | wc -l | tr -d ' ')"
SCAN_OTHER="$(scope_rows "$SCAN_FIXTURE/other" | wc -l | tr -d ' ')"
report "$([ "$SCAN_COPY" = 3 ] && [ "$SCAN_OTHER" = 0 ] && echo PASS || echo FAIL)" \
  "S2 the table-copy scan flags a planted row in Markdown and TOML and leaves other api tables alone (copy=$SCAN_COPY other=$SCAN_OTHER)"

swap() {
  node -e '
    const fs = require("node:fs");
    const [file, from, to] = process.argv.slice(1);
    const text = fs.readFileSync(file, "utf8");
    if (from === "") {
      fs.writeFileSync(file, text + to);
      process.exit(0);
    }
    const at = text.indexOf(from);
    if (at < 0) process.exit(3);
    fs.writeFileSync(file, text.slice(0, at) + to + text.slice(at + from.length));
  ' "$1" "$2" "$3"
}

mutation() {
  local id="$1" description="$2" expect="$3" rel="$4" from="$5" to="$6"
  local dir="$MUT_ROOT/$id/plugins/zensu" failed want missing=""
  mkdir -p "$dir"
  cp -R "$PLUGIN_DIR/skills" "$PLUGIN_DIR/agents" "$PLUGIN_DIR/docs" "$dir/"
  if ! swap "$dir/$rel" "$from" "$to"; then
    report FAIL "$id $description: the text to mutate is gone from $rel, so this case no longer bites"
    return
  fi
  failed=" $(checks_for "$dir" | awk -F'\t' '$1 == "FAIL" { printf "%s ", $2 }')"
  for want in $expect; do
    case "$failed" in
      *" $want "*) ;;
      *) missing="$missing $want" ;;
    esac
  done
  if [ -z "$missing" ]; then
    report PASS "$id $description trips $expect"
  else
    report FAIL "$id $description did not trip:$missing (tripped:$failed)"
  fi
}

SKILL_REL='skills/implement/SKILL.md'
GUIDE_REL='docs/documentation-guide.md'
mutation X1 "Step 7 without the read of active_revision_id and stage" "M7" "$SKILL_REL" \
  '1. Re-read the feature with' '1. Note the feature with'
mutation X2 "Step 7 creating a revision in every case" "M9" "$SKILL_REL" \
  '3. **No revision is open** (' '3. **Otherwise** ('
mutation X3 "Step 7 without the definition of an open revision" "M6" "$SKILL_REL" \
  '2. **A revision is open** when' '2. **A revision exists** when'
mutation X4 "Step 6 without the docs_complete outcome" "M4" "$SKILL_REL" \
  'report the docs as open, never as complete' 'report the docs as done'
mutation X5 "Step 6 without the pointer at the guide's table" "M3" "$SKILL_REL" \
  'The table under "Required doc types (the' 'The table under "Doc types (the'
mutation X6 "a second revision command outside the guarded branch" "M9" "$SKILL_REL" \
  '' 'Run `zensu features revision <feature-id>` once more.
'
mutation X7 "a scope table copy in the implement skill" "G5" "$SKILL_REL" \
  '' '
| `api` | `api_reference` | `developer` |
'
mutation X8 "a scope table copy in an agent definition" "G5" "agents/zensu-plm.toml" \
  '' '
| `internal_only` | `adr` | `internal` |
'
mutation X9 "a guide row with the wrong required type" "G1 G3" "$GUIDE_REL" \
  '| `internal_only` | `adr` | `internal` |' '| `internal_only` | `internal` | `internal` |'
mutation X10 "guide advice that picks a type by classification" "G4" "$GUIDE_REL" \
  'A confidential backend feature with an unset scope still' 'A confidential backend feature usually warrants `internal`; one with an unset scope still'

echo "----"
echo "test-implement-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
