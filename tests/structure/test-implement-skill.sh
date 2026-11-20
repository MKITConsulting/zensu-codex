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
before_feature_command() {
  T="$1" A="$2" awk 'BEGIN {
    t = ENVIRON["T"]; i = index(t, ENVIRON["A"]); j = match(t, /zensu [a-z-]+ [a-z-]+ <feature-id>/)
    print ((i > 0 && j > i) ? "PASS" : "FAIL")
  }'
}
filter_runs() {
  [ -f "$1" ] || { echo FAIL; return; }
  node -e '
    const fs = require("node:fs");
    const { spawnSync } = require("node:child_process");
    const text = fs.readFileSync(process.argv[1], "utf8").replace(/\r\n/g, "\n");
    const block = (text.match(/```bash\n([\s\S]*?)\n```/) || [])[1] || "";
    const head = "zensu features list --product \x27<product-id>\x27 --json | node -e \x27";
    const tail = "\x27 \x27<product-id>\x27 \x27<N or slug>\x27";
    if (!block.startsWith(head) || !block.endsWith(tail)) { console.log("FAIL"); process.exit(0); }
    const script = block.slice(head.length, block.length - tail.length);
    const data = JSON.stringify({ data: [
      { id: "u-1", product_id: "p-1", number: 1, slug: "alpha" },
      { id: "u-42", product_id: "p-1", number: 42, slug: "beta" },
      { id: "x-42", product_id: "p-2", number: 42, slug: "beta" } ] });
    const run = (product, key) => {
      const r = spawnSync(process.execPath, ["-e", script, product, key], { input: data, encoding: "utf8" });
      return r.status === 0 ? r.stdout.trim() : "exit " + r.status;
    };
    const ok = run("p-1", "001") === "u-1" && run("p-1", "42") === "u-42" &&
      run("p-2", "beta") === "x-42" && run("p-1", "gamma") === "no single match (0)";
    console.log(ok ? "PASS" : "FAIL");
  ' "$1"
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
  local resolve="$dir/skills/implement/references/feature-id-resolution.md"
  local review="$dir/skills/security-review/SKILL.md"
  local prereq step1 step5 step6 step7 summary cli_table norm_guide norm_skill row rule verdict others
  local norm_resolve review_prereq review_step1 norm_review copies

  if [ ! -f "$skill" ] || [ ! -f "$guide" ]; then
    emit FAIL M1 "skills/implement/SKILL.md and docs/documentation-guide.md exist"
    return
  fi
  emit PASS M1 "skills/implement/SKILL.md and docs/documentation-guide.md exist"

  prereq="$(section "$skill" '## Prerequisites' '## Workflow')"
  step1="$(section "$skill" '### Step 1:' '### Step 2:')"
  step5="$(section "$skill" '### Step 5:' '### Step 6:')"
  norm_resolve=""
  [ -f "$resolve" ] && norm_resolve="$(squash "$resolve")"
  review_prereq="" review_step1="" norm_review=""
  if [ -f "$review" ]; then
    review_prereq="$(section "$review" '## Prerequisites' '## Workflow')"
    review_step1="$(section "$review" '### Step 1:' '### Step 2:')"
    norm_review="$(squash "$review")"
  fi
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
    "$([ -f "$resolve" ] && echo PASS || echo FAIL)" \
    "$(has "$norm_resolve" 'fails with `invalid feature id (status 400, code bad_request)`')" \
    "$(has "$norm_resolve" 'when an automatic context package was supplied for this `KEY-N`, its `feature_id` is already the UUID')" \
    "$(has "$norm_resolve" 'run `zensu products list --json` and take, from its `data` array, the product whose `feature_key` equals `KEY` exactly')" \
    "$(has "$norm_resolve" 'never one whose key merely starts with it')" \
    "$(has "$norm_resolve" 'ask the user which product it belongs to unless they named it')" \
    "$(has "$norm_resolve" 'never guess a feature')" \
    "$(has "$norm_resolve" 'far too much to read, so never print it unfiltered')" \
    "$(has "$norm_resolve" 'its `number` equals `N` as an integer (`ZEN-001` is number 1)')" \
    "$(before "$norm_resolve" 'zensu products list --json' 'zensu features list --product')")" M13 \
    "the feature-id-resolution reference resolves a KEY-N id or a slug to the feature UUID (automatic package, exact feature_key, integer number or slug, filtered output)"

  emit "$(all \
    "$(has "$step1" 'Every `<feature-id>` below is the feature UUID, so if the ID is not a UUID, read and follow [Resolve a feature ID to its UUID](references/feature-id-resolution.md) before any other `zensu` call')" \
    "$(has "$review_step1" 'Every `<feature-id>` below is the feature UUID, so if the ID is not a UUID, read and follow [Resolve a feature ID to its UUID](../implement/references/feature-id-resolution.md) before any other `zensu` call')" \
    "$(has "$prereq" '**every `<feature-id>` CLI argument takes the feature UUID**')" \
    "$(has "$prereq" 'a `KEY-N` id or a slug fails with `invalid feature id (status 400, code bad_request)`')" \
    "$(has "$review_prereq" '**every `<feature-id>` CLI argument takes the feature UUID**')" \
    "$(has "$review_prereq" 'a `KEY-N` id or a slug fails with `invalid feature id (status 400, code bad_request)`')" \
    "$([ -z "$(grep -rlF -- 'ZEN-xxx format or UUID' "$dir/skills" 2>/dev/null)" ] && echo PASS || echo FAIL)")" M14 \
    "the implement and security-review skills make every <feature-id> argument the UUID through the shared reference, and no skill keeps the ZEN-xxx-or-UUID wording"

  emit "$(all \
    "$(has "$cli_table" '| `zensu products list` | 1, 5 |')" \
    "$(has "$cli_table" '| `zensu features list` | 1, 5 |')" \
    "$(has "$norm_review" '| `zensu products list` | 1 |')" \
    "$(has "$norm_review" '| `zensu features list` | 1 |')")" M15 \
    "the CLI tables of both skills list the products and features list reads that resolve the id"

  emit "$(filter_runs "$resolve")" M16 \
    "the reference's filter prints only the matching feature id (integer N, same product, slug) and reports no single match otherwise"

  emit "$(all \
    "$(before_feature_command "$step1" 'feature-id-resolution.md')" \
    "$(before_feature_command "$review_step1" 'feature-id-resolution.md')")" M17 \
    "both skills point at the resolution before their first <feature-id> command"

  emit "$(all \
    "$(has "$step5" 'For cross-feature mapping, resolve each target feature to its UUID as Step 1 item 1 does, then run `zensu link source` once per target')" \
    "$(lacks "$step5" 'once per target feature id')")" M18 \
    "Step 5 resolves every cross-feature target to its UUID before zensu link source"

  copies="$(grep -rlF --include='*.md' --include='*.toml' -- 'f.product_id === product' "$dir/skills" "$dir/agents" "$dir/docs" "$dir/../../reference" 2>/dev/null | grep -vxF -- "$resolve")"
  if [ -z "$copies" ]; then
    emit PASS G6 "only the feature-id-resolution reference carries the feature filter"
  else
    emit FAIL G6 "a copy of the feature filter outside the reference: $(printf '%s' "$copies" | tr '\n' ' ')"
  fi

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

S3_GOOD='follow feature-id-resolution.md, then run `zensu features get <feature-id>`.'
S3_LATE='run `zensu link source <feature-id>`, then follow feature-id-resolution.md.'
S3_NONE='follow feature-id-resolution.md and stop.'
report "$(all \
  "$(before_feature_command "$S3_GOOD" 'feature-id-resolution.md')" \
  "$([ "$(before_feature_command "$S3_LATE" 'feature-id-resolution.md')" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(before_feature_command "$S3_NONE" 'feature-id-resolution.md')" = FAIL ] && echo PASS || echo FAIL)")" \
  "S3 the feature-command order check passes a resolution first and fails a late resolution or no feature command"

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
RESOLVE_REL='skills/implement/references/feature-id-resolution.md'
REVIEW_REL='skills/security-review/SKILL.md'
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
mutation X11 "Step 1 passing a KEY-N id or a slug through unresolved" "M14 M17" "$SKILL_REL" \
  'read and follow [Resolve a feature ID to its UUID](references/feature-id-resolution.md) before any other `zensu` call' 'pass the ID to every `zensu` call as given'
mutation X12 "a prefix match on the product feature_key" "M13" "$RESOLVE_REL" \
  'whose `feature_key` equals `KEY` exactly' 'whose `feature_key` starts with `KEY`'
mutation X13 "a feature read before the id is resolved" "M17" "$SKILL_REL" \
  '1. Ask the user for the feature ID.' '1. Run `zensu features get <feature-id>`, then ask the user for the feature ID.'
mutation X14 "the old prerequisite that passes ZEN-xxx ids through" "M14" "$SKILL_REL" \
  '**every `<feature-id>` CLI argument takes the feature UUID**' 'every ZEN-xxx format or UUID works'
mutation X15 "a security read before the id is resolved" "M17" "$SKILL_REL" \
  '1. Ask the user for the feature ID.' '1. Run `zensu security analyze <feature-id>` first. Ask the user for the feature ID.'
mutation X16 "a filter that compares the feature number as a string" "M16" "$RESOLVE_REL" \
  'f.number === n' 'String(f.number) === key'
mutation X17 "a filter that keeps features of other products" "M16" "$RESOLVE_REL" \
  'f.product_id === product && ' ''
mutation X18 "a security-review prerequisite that still takes ZEN-xxx ids" "M14" "$REVIEW_REL" \
  'A feature ID to review. The user may name it' 'A feature ID (ZEN-xxx format or UUID) to review. The user may name it'
mutation X19 "a security classification before the id is resolved" "M17" "$REVIEW_REL" \
  'Ask the user for the feature ID. Every `<feature-id>` below' 'Run `zensu security classify <feature-id>` now. Ask the user for the feature ID. Every `<feature-id>` below'
mutation X20 "cross-feature source links with unresolved target ids" "M18" "$SKILL_REL" \
  'resolve each target feature to its UUID as Step 1 item 1 does, then run `zensu link source` once per target.' 'run `zensu link source` once per target feature id.'
mutation X21 "a copy of the feature filter in the implement skill" "G6" "$SKILL_REL" \
  '' 'Filter with `f.product_id === product` here.
'

echo "----"
echo "test-implement-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
