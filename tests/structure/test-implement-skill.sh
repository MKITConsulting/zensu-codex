#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_DIR="$ROOT/plugins/zensu"
SCOPE_TITLE='Required doc types (the release gate)'
REFUSAL='previous revision must be released or superseded before creating a new one'
SCOPE_ROW_RE='^[|] *(unset[^|]*|`(default|api|internal_only|public_facing)`) *[|] *`(user_facing|api_reference|adr|tutorial)`'
TAB="$(printf '\t')"
SKILL_REL='skills/implement/SKILL.md'
GUIDE_REL='docs/documentation-guide.md'
RESOLVE_REL='skills/implement/references/feature-id-resolution.md'
REVIEW_REL='skills/security-review/SKILL.md'

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
bash_fences() { awk '{ sub(/\r$/, "") } /^```bash$/ { f = 1 } f { print } f && /^```$/ { f = 0 }' "$1"; }
filter_runs() {
  [ -f "$1" ] || { echo FAIL; return; }
  if [ "${3:-}" = cached ] && [ -n "${M16_BASE:-}" ] && [ -n "$M16_BASE_FENCES" ] && [ "$(bash_fences "$1")" = "$M16_BASE_FENCES" ]; then
    echo "$M16_BASE"
    return
  fi
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const { spawnSync } = require("node:child_process");
    const [file, stubDir, fixture] = process.argv.slice(1);
    const head = "zensu features list --product \x27<product-id>\x27 --json | node -e \x27";
    const tail = "\x27 \x27<product-id>\x27 \x27<N or slug>\x27";
    const text = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");
    const blocks = [...text.matchAll(/```bash\n([\s\S]*?)\n```/g)].map((m) => m[1]).filter((b) => b.startsWith(head) && b.endsWith(tail));
    const quote = (value) => "\x27" + value.split("\x27").join("\x27\\\x27\x27") + "\x27";
    const onPath = (name) => (process.env.PATH || "").split(path.delimiter).filter(Boolean).map((dir) => path.resolve(dir, name)).find((file) => {
      try { fs.accessSync(file, fs.constants.X_OK); return fs.statSync(file).isFile(); } catch (e) { return false; }
    });
    const run = (shell, product, key, extra) => {
      const cmd = blocks[0].split(quote("<product-id>")).join(quote(product)).split(quote("<N or slug>")).join(quote(key));
      const env = Object.assign({
        PATH: [stubDir, path.dirname(process.execPath), "/usr/bin", "/bin"].join(path.delimiter),
        ZENSU_STUB_PRODUCT: product,
        ZENSU_STUB_FIXTURE: fixture }, extra);
      return spawnSync(shell, path.basename(shell) === "zsh" ? ["-f", "-c", cmd] : ["-c", cmd], { env, encoding: "utf8" });
    };
    const cases = [
      ["p-1", "001", "u-1"], ["p-1", "42", "u-42"], ["p-2", "beta", "x-42"],
      ["p-1", "gamma", "no single match (0)"], ["p-1", "alpha", "no single match (2)"],
      ["p-1", "o\x27brien-$(echo x)", "u-q"] ];
    let cause = "";
    const verdict = (() => {
      if (blocks.length !== 1) return "found " + blocks.length + " bash fences with the documented head and tail, expected 1";
      const size = fs.statSync(fixture).size;
      if (size <= 4 * 65536) return "fixture of " + size + " bytes fits in four 64 KiB pipe reads";
      const bash = fs.existsSync("/bin/bash") ? "/bin/bash" : onPath("bash");
      if (!bash) return "bash is missing";
      const zsh = onPath("zsh");
      const shells = [bash];
      if (zsh && spawnSync(zsh, ["-f", "-c", "exit 0"]).status === 0) shells.push(zsh);
      else if (process.platform === "darwin") return "zsh is missing on macOS";
      for (const shell of shells) {
        for (const [product, key, want] of cases) {
          const r = run(shell, product, key, {});
          const got = r.status === 0 ? r.stdout.trim() : "exit " + r.status;
          const err = r.stderr || "";
          if (got !== want) return shell + " " + product + " " + key + ": expected " + want + ", got " + got + "; stderr: " + err.split("\n")[0];
          if (err.includes("filler-")) return shell + " " + product + " " + key + ": the feature list reached stderr";
        }
        const broken = run(shell, "p-1", "001", { ZENSU_STUB_FAIL: "1" });
        cause = broken.status === 0 ? "exit" : broken.stdout.trim() !== "" ? "stdout" : (broken.stderr || "").includes("zensu stub: forced failure") ? "" : "stderr";
        if (cause !== "")
          return shell + " failing zensu: expected a non-zero exit, no output and the CLI error on stderr, got exit " + broken.status + " and output " + broken.stdout.trim();
      }
      return "";
    })();
    console.log(verdict === "" ? "PASS" : "FAIL\n" + verdict.replace(/\s+/g, " ").slice(0, 240) + (cause === "" ? "" : "\ncause=" + cause));
  ' "$1" "${2:-$STUB_DIR}" "$STUB_FIXTURE"
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
  local skill="$dir/$SKILL_REL"
  local guide="$dir/$GUIDE_REL"
  local resolve="$dir/$RESOLVE_REL"
  local review="$dir/$REVIEW_REL"
  local m16
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
    "$(has "$norm_resolve" 'take from `zensu products list --json` the one product whose `name`, `slug` or `feature_key` equals what the user named')" \
    "$(has "$norm_resolve" 'never guess a feature')" \
    "$(has "$norm_resolve" 'far too much to read, so never print it unfiltered')" \
    "$(has "$norm_resolve" 'its `number` equals `N` as an integer (`ZEN-001` is number 1)')" \
    "$(has "$norm_resolve" "Replace each placeholder with its value inside the single quotes, and write each apostrophe in a value as \`'\\''\`")" \
    "$(before "$norm_resolve" 'zensu products list --json' 'zensu features list --product')")" M13 \
    "the feature-id-resolution reference resolves a KEY-N id or a slug to the feature UUID (automatic package, exact feature_key, one exactly named product, integer number or slug, quoted values, filtered output)"

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

  m16="$(filter_runs "$resolve" "$STUB_DIR" cached)"
  emit "$(printf '%s\n' "$m16" | sed -n '1p')" M16 \
    "the reference's documented command, run through bash and zsh where installed against a zensu stub whose list spans several pipe reads, prints only the matching feature id (integer N, same product, slug, quoted apostrophe), reports no single match otherwise and fails with the CLI error on stderr when zensu fails$(printf '%s\n' "$m16" | sed -n '2s/^/ — /p')"

  emit "$(all \
    "$(before_feature_command "$norm_skill" 'read and follow [Resolve a feature ID to its UUID](')" \
    "$(before_feature_command "$norm_review" 'read and follow [Resolve a feature ID to its UUID](')")" M17 \
    "both skills point at the resolution before the first <feature-id> command anywhere in their text"

  emit "$(all \
    "$(has "$step5" 'For cross-feature mapping, resolve each target feature to its UUID as Step 1 item 1 does, then run `zensu link source` once per target')" \
    "$(lacks "$step5" 'once per target feature id')")" M18 \
    "Step 5 resolves every cross-feature target to its UUID before zensu link source"

  emit "$(all \
    "$(has "$norm_resolve" "when no product's \`feature_key\` equals \`KEY\`")" \
    "$(has "$norm_resolve" 'when the product the user named matches no product or more than one in the `zensu products list --json` output')" \
    "$(has "$norm_resolve" 'when a `zensu` command fails')" \
    "$(has "$norm_resolve" 'or when the filter prints `no single match`')" \
    "$(has "$norm_resolve" "show the user what you looked up and the command's error if one failed, and ask again")" \
    "$(has "$norm_resolve" 'never pass the unresolved id to a `<feature-id>` argument')")" M19 \
    "the reference's No match rule covers a missing product, a named product that matches none or several, a failing command and no single match, and never passes the unresolved id on"

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

STUB_DIR="$MUT_ROOT/zensu-stub"
STUB_FIXTURE="$STUB_DIR/features.json"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/zensu" <<'STUB'
#!/bin/sh
[ -n "${ZENSU_STUB_FAIL:-}" ] && { echo "zensu stub: forced failure" >&2; exit 1; }
[ "$1 $2" = "features list" ] || { echo "zensu stub: unexpected command: $*" >&2; exit 2; }
shift 2
product="" json=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --product) product="$2"; shift 2 ;;
    --json) json=1; shift ;;
    *) echo "zensu stub: unexpected argument: $1" >&2; exit 2 ;;
  esac
done
[ "$product" = "$ZENSU_STUB_PRODUCT" ] && [ -n "$json" ] || { echo "zensu stub: wrong --product or no --json" >&2; exit 2; }
exec cat "$ZENSU_STUB_FIXTURE"
STUB
chmod +x "$STUB_DIR/zensu"
node -e '
  const filler = Array.from({ length: 4000 }, (_, i) => ({ id: "f-" + i, product_id: "p-9", number: i + 1, slug: "filler-" + i, title: "Filler feature " + i }));
  const data = filler.concat([
    { id: "u-1", product_id: "p-1", number: 1, slug: "alpha" },
    { id: "u-42", product_id: "p-1", number: 42, slug: "beta" },
    { id: "u-43", product_id: "p-1", number: 43, slug: "alpha" },
    { id: "x-42", product_id: "p-2", number: 42, slug: "beta" },
    { id: "u-q", product_id: "p-1", number: 77, slug: "o\x27brien-$(echo x)" } ]);
  require("node:fs").writeFileSync(process.argv[1], JSON.stringify({ data, total: data.length, page: 1, perPage: data.length }));
' "$STUB_FIXTURE" || exit 1

echo "  INFO  shell: $BASH $BASH_VERSION"
OUT="$(checks_for "$PLUGIN_DIR")"
M16_BASE="$(printf '%s\n' "$OUT" | awk -F'\t' '$2 == "M16" { print $1 }')"
M16_BASE_FENCES="$(bash_fences "$PLUGIN_DIR/$RESOLVE_REL" 2>/dev/null)"
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

S3_ANCHOR='read and follow [Resolve a feature ID to its UUID]('
S3_GOOD='## Prerequisites A feature ID. ### Step 1: read and follow [Resolve a feature ID to its UUID](references/feature-id-resolution.md), then run `zensu features get <feature-id>`.'
S3_EARLY='## Prerequisites Check it with `zensu features get <feature-id>`. ### Step 1: read and follow [Resolve a feature ID to its UUID](references/feature-id-resolution.md), then run `zensu security analyze <feature-id>`.'
S3_LATE='run `zensu link source <feature-id>`, then read and follow [Resolve a feature ID to its UUID](references/feature-id-resolution.md).'
S3_NONE='read and follow [Resolve a feature ID to its UUID](references/feature-id-resolution.md) and stop.'
report "$(all \
  "$(before_feature_command "$S3_GOOD" "$S3_ANCHOR")" \
  "$([ "$(before_feature_command "$S3_EARLY" "$S3_ANCHOR")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(before_feature_command "$S3_LATE" "$S3_ANCHOR")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(before_feature_command "$S3_NONE" "$S3_ANCHOR")" = FAIL ] && echo PASS || echo FAIL)")" \
  "S3 the feature-command order check passes a resolution first and fails a feature command in an earlier section, a late resolution or no feature command"

S4_DIR="$MUT_ROOT/s4"
mkdir -p "$S4_DIR"
{ printf '%s\n' '```bash' "touch '$S4_DIR/ran'" '```' ''; cat "$PLUGIN_DIR/$RESOLVE_REL"; } > "$S4_DIR/reference.md"
S4_VERDICT="$(filter_runs "$S4_DIR/reference.md" | sed -n '1p')"
report "$([ "$S4_VERDICT" = PASS ] && [ ! -e "$S4_DIR/ran" ] && echo PASS || echo FAIL)" \
  "S4 the M16 harness runs only the documented filter fence and never another bash fence of the reference (verdict=$S4_VERDICT)"

S5_DIR="$MUT_ROOT/s5"
mkdir -p "$S5_DIR"
sed 's/echo "zensu stub: forced failure" >&2; //' "$STUB_DIR/zensu" > "$S5_DIR/zensu"
chmod +x "$S5_DIR/zensu"
S5_OUT="$(filter_runs "$PLUGIN_DIR/$RESOLVE_REL" "$S5_DIR")"
S5_VERDICT="$(printf '%s\n' "$S5_OUT" | sed -n '1p')"
S5_CAUSE="$(printf '%s\n' "$S5_OUT" | sed -n '3s/^cause=//p')"
report "$([ "$S5_VERDICT" = FAIL ] && [ "$S5_CAUSE" = stderr ] && ! grep -q 'forced failure' "$S5_DIR/zensu" && echo PASS || echo FAIL)" \
  "S5 the M16 harness fails a zensu that exits non-zero without output when its error never reaches stderr (verdict=$S5_VERDICT cause=${S5_CAUSE:-none})"

S6_DIR="$MUT_ROOT/s6"
mkdir -p "$S6_DIR"
cat > "$S6_DIR/zsh" <<EOF
#!/bin/sh
printf '%s %s %.19s|%s\n' "\$1" "\$2" "\$3" "\$PATH" >> '$S6_DIR/calls'
shift 2
exec /bin/sh -c "\$1"
EOF
chmod +x "$S6_DIR/zsh"
S6_MIN_PATH="$STUB_DIR:$(node -p 'require("node:path").dirname(process.execPath)'):/usr/bin:/bin"
S6_VERDICT="$(PATH="$S6_DIR:$PATH"; filter_runs "$PLUGIN_DIR/$RESOLVE_REL" | sed -n '1p')"
S6_RUNS="$(grep -c '^-f -c zensu features list|' "$S6_DIR/calls" 2>/dev/null)"
S6_MINIMAL="$(grep -cxF -- "-f -c zensu features list|$S6_MIN_PATH" "$S6_DIR/calls" 2>/dev/null)"
report "$([ "$S6_VERDICT" = PASS ] && [ "${S6_RUNS:-0}" -gt 0 ] && [ "${S6_MINIMAL:-0}" = "${S6_RUNS:-0}" ] && echo PASS || echo FAIL)" \
  "S6 the M16 harness runs the zsh it finds on the suite PATH by its absolute path, also outside the minimal run PATH, and keeps the minimal run PATH inside it (verdict=$S6_VERDICT runs=${S6_RUNS:-0} minimal=${S6_MINIMAL:-0})"

S7_DIR="$MUT_ROOT/s7"
mkdir -p "$S7_DIR"
cp "$STUB_DIR/zensu" "$S7_DIR/zensu"
chmod +x "$S7_DIR/zensu"
S7_BASH="$(command -v bash)"
cat > "$S7_DIR/bash" <<EOF
#!/bin/sh
printf '%.19s\n' "\$2" >> '$S7_DIR/calls'
exec '$S7_BASH' "\$@"
EOF
chmod +x "$S7_DIR/bash"
S7_VERDICT="$(PATH="$S7_DIR:$PATH"; filter_runs "$PLUGIN_DIR/$RESOLVE_REL" "$S7_DIR" | sed -n '1p')"
S7_RUNS="$(grep -c '^zensu features list$' "$S7_DIR/calls" 2>/dev/null)"
S7_RUNS="${S7_RUNS:-0}"
if [ -x /bin/bash ]; then S7_OK="$([ "$S7_RUNS" -eq 0 ] && echo yes)"; else S7_OK="$([ "$S7_RUNS" -gt 0 ] && echo yes)"; fi
report "$([ "$S7_VERDICT" = PASS ] && [ "$S7_OK" = yes ] && echo PASS || echo FAIL)" \
  "S7 the M16 harness runs its bash leg with /bin/bash when that exists, else with the first bash on the suite PATH, even with another bash first on the suite and run PATH (verdict=$S7_VERDICT wrapper_runs=$S7_RUNS)"

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

clause_case() {
  local id="$1" inject="$2" want="$3" label="$4" dir="$MUT_ROOT/$1" swapped=missing out verdict cause ok
  mkdir -p "$dir"
  cp "$PLUGIN_DIR/$RESOLVE_REL" "$dir/reference.md"
  swap "$dir/reference.md" 's += d; }).on("end", () => {' "s += d; }).on(\"end\", () => { $inject" && swapped=landed
  out="$(filter_runs "$dir/reference.md")"
  verdict="$(printf '%s\n' "$out" | sed -n '1p')"
  cause="$(printf '%s\n' "$out" | sed -n '3s/^cause=//p')"
  ok="$([ "$swapped" = landed ] && [ "$verdict" = FAIL ] && [ "$cause" = "$want" ] && echo PASS || echo FAIL)"
  report "$ok" "$id $label (swap=$swapped verdict=$verdict cause=${cause:-none})$([ "$ok" = PASS ] || printf '%s\n' "$out" | sed -n '2s/^/ — /p')"
}

clause_case S8 'if (s === "") return;' exit \
  "the M16 harness fails a filter that exits 0 without output when zensu fails"
clause_case S9 'if (s === "") { console.log("no input"); process.exitCode = 1; return; }' stdout \
  "the M16 harness fails a filter that prints a line and exits non-zero when zensu fails"

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
mutation X22 "a filter that takes the first of several matches" "M16" "$RESOLVE_REL" \
  'hits.length === 1 ?' 'hits.length >= 1 ?'
mutation X23 "the old No match rule that covers only the filter output" "M19" "$RESOLVE_REL" \
  "when no product's \`feature_key\` equals \`KEY\`, when the product the user named matches no product or more than one in the \`zensu products list --json\` output, when a \`zensu\` command fails (it prints an error instead of the JSON envelope, so the filter fails too), or when the filter prints \`no single match\`, show the user what you looked up and the command's error if one failed, and ask again; never guess a feature, and never pass the unresolved id to a \`<feature-id>\` argument." \
  'when the filter prints `no single match`, show the user what you looked up and ask again; never guess a feature.'
mutation X24 "a feature read in the implement prerequisites" "M17" "$SKILL_REL" \
  'Step 1 resolves it first.' 'Check it with `zensu features get <feature-id>`; Step 1 resolves it first.'
mutation X25 "a security read before Step 1 of security-review" "M17" "$REVIEW_REL" \
  'Execute these steps in order.' 'Run `zensu security analyze <feature-id>` to see the current state. Execute these steps in order.'
mutation X26 "a single quote inside the shell-quoted filter" "M16" "$RESOLVE_REL" \
  '"no single match ("' "'no single match ('"
mutation X27 "a filter that parses on the first stdin chunk" "M16" "$RESOLVE_REL" \
  '.on("end", () => {' '.once("data", () => {'
mutation X28 "a No match rule without the no-single-match case" "M19" "$RESOLVE_REL" \
  ', or when the filter prints `no single match`' ''
mutation X29 "a reference without the quoting rule for placeholder values" "M13" "$RESOLVE_REL" \
  "Replace each placeholder with its value inside the single quotes, and write each apostrophe in a value as \`'\\''\`. " ''
mutation X30 "a filter that hides the CLI error" "M16" "$RESOLVE_REL" \
  '--json | node -e' '--json 2>/dev/null | node -e'
mutation X31 "a filter that turns a CLI failure into an empty list" "M16" "$RESOLVE_REL" \
  'JSON.parse(s).data.filter(' '(JSON.parse(s || "{}").data || []).filter('
mutation X32 "a filter that copies the feature list to stderr" "M16" "$RESOLVE_REL" \
  'console.log(hits.length === 1' 'console.error(s); console.log(hits.length === 1'
mutation X33 "a No match rule that ignores a name matching several products" "M19" "$RESOLVE_REL" \
  'matches no product or more than one in' 'is not in'
mutation X34 "a slug lookup that takes any product the user named" "M13" "$RESOLVE_REL" \
  'the one product whose `name`, `slug` or `feature_key` equals what the user named' 'the product the user named'

echo "----"
echo "test-implement-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
