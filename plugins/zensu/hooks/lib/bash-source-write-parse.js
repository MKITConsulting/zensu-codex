"use strict";

// Parser for pre-bash-source-write-gate.sh. Reads the PreToolUse shell-tool
// payload (shell/Bash/exec_command/exec — command extraction shared with the
// witness via shell-command-extract.js)
// from $PAYLOAD, walks the command, and decides whether any write through a
// gated channel (redirect / tee / sed -i / dd of= / heredoc) hits a source file
// that must not be clobbered. Prints the deny reason on stdout, or nothing.
//
// Kept in its own file (like hooks/lib/resolve-session-id.js) so the logic uses
// normal quoting instead of being escaped inside a bash single-quoted node -e.
//
// Paths are resolved LEXICALLY (path.resolve/path.relative, no realpath), so a
// symlink inside the project pointing at a sibling/main checkout resolves as
// "within project" and slips the (B) escape rule. Likewise `tee >(proc) realfile`
// is not caught — the process-substitution `(` severs the real file operand that
// follows `)`. Both are accepted rare-idiom gaps: this is a convention-nudge with
// an env escape hatch, not a security boundary.

const path = require("path");
const fs = require("fs");
const { execFileSync } = require("child_process");

const SRC = new Set(
  "rs ts tsx js jsx mjs cjs py java kt kts go rb c cc cpp cxx h hh hpp cs php swift scala vue svelte".split(" ")
);

// Transparent command wrappers — skipped so `env sed -i …` / `sudo dd of=…`
// still resolve to the real verb.
const WRAP = new Set("command builtin exec env sudo nohup nice time".split(" "));

function stripSlash(p) {
  return p && p.length > 1 && p.endsWith("/") ? p.replace(/\/+$/, "") : p;
}

function unquote(t) {
  return t.replace(/^['"]+|['"]+$/g, "");
}

// Drop heredoc bodies so their content (which may contain `>` or `*.rs` text)
// cannot be misread as commands. The intro line is kept, so `cat > FILE <<EOF`
// still surfaces its `> FILE` redirect. The `(?<!<)<<(?!<)` guard excludes
// here-strings (`<<<WORD`), which are not heredocs and must not swallow lines.
function stripHeredocs(s) {
  const lines = s.split("\n");
  const out = [];
  let i = 0;
  while (i < lines.length) {
    out.push(lines[i]);
    const hm = lines[i].match(/(?<!<)<<(?!<)[-~]?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/);
    if (hm) {
      const delim = hm[2];
      i++;
      while (i < lines.length && lines[i].trim() !== delim) i++;
      if (i < lines.length) i++;
      continue;
    }
    i++;
  }
  return out.join("\n");
}

// Split into command segments while tracking subshell scope. `(`/`$(` emit an
// "enter" event and `)` a "leave" event so the caller can save/restore the cwd
// across a subshell — a `cd` inside `( … )` must not leak to later commands.
// Backtick is treated as a plain boundary. `&&`/`||`/`;`/`|`/newline/`&` split.
function lex(s) {
  const ev = [];
  let buf = "";
  let depth = 0;
  const flush = () => { ev.push({ t: "seg", text: buf }); buf = ""; };
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    const two = s.substr(i, 2);
    if (two === "$(") { flush(); ev.push({ t: "enter" }); depth++; i++; continue; }
    if (c === "(") { flush(); ev.push({ t: "enter" }); depth++; continue; }
    if (c === ")") { flush(); if (depth > 0) { ev.push({ t: "leave" }); depth--; } continue; }
    if (c === "`") { flush(); continue; }
    if (two === "&&" || two === "||") { flush(); i++; continue; }
    if (c === ";" || c === "|" || c === "\n" || c === "&") { flush(); continue; }
    buf += c;
  }
  flush();
  return ev;
}

function main() {
  let cmd = "";
  let cwd0 = "";
  try {
    const j = JSON.parse(process.env.PAYLOAD || "{}");
    cmd = require(__dirname + "/shell-command-extract.js").extractShellCommand(j.tool_input);
    if (typeof j.cwd === "string") cwd0 = j.cwd;
  } catch (e) {
    return "";
  }
  if (!cmd) return "";

  const HOME = process.env.HOME || "";
  const projectRoot = stripSlash(process.env.CLAUDE_PROJECT_DIR || cwd0 || process.cwd());
  let curdir = cwd0 || projectRoot;

  // Temp roots are exempt from the (B) escape rule. ZENSU_BSWGATE_TEMP_DIRS (a
  // colon-separated list) overrides the default set when present — an advanced
  // customization seam, also used by the test harness for deterministic paths.
  const tempOverride = process.env.ZENSU_BSWGATE_TEMP_DIRS;
  const TEMP = (tempOverride !== undefined
    ? tempOverride.split(":")
    : [process.env.TMPDIR || "", "/tmp", "/private/tmp", "/var/folders"]
  )
    .filter(Boolean)
    .map(stripSlash);

  function expand(p) {
    if (p === "~") return HOME;
    if (p.startsWith("~/")) return HOME + p.slice(1);
    return p;
  }
  function abspath(p) {
    return stripSlash(path.resolve(curdir, expand(p)));
  }
  function extOf(p) {
    const b = path.basename(p);
    const i = b.lastIndexOf(".");
    return i > 0 ? b.slice(i + 1).toLowerCase() : "";
  }
  function within(root, p) {
    root = stripSlash(root);
    if (p === root) return true;
    const rel = path.relative(root, p);
    return rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel);
  }
  function isTemp(p) {
    return TEMP.some((t) => p === t || within(t, p));
  }

  // git missing (ENOENT) or hung (2s timeout) → fail-open, so the gate cannot be
  // turned into a wedge or invert the gitignore carve-out on a git-less host.
  function bail(e) {
    return !!(e && (e.killed || e.signal === "SIGTERM" || e.code === "ETIMEDOUT" || e.code === "ENOENT"));
  }
  // In a git repo: true iff the path is tracked. In a real dir that is not a repo:
  // true (protect any existing source file, per the spec). git is invoked via
  // execFileSync arg-array (no shell), so an attacker-influenced path after `--`
  // cannot be reinterpreted as a flag.
  function tracked(p) {
    const dir = path.dirname(p);
    const opts = { stdio: "ignore", timeout: 2000 };
    try {
      execFileSync("git", ["-C", dir, "ls-files", "--error-unmatch", "--", p], opts);
      return true;
    } catch (e1) {
      if (bail(e1)) return false;
      try {
        execFileSync("git", ["-C", dir, "rev-parse", "--is-inside-work-tree"], opts);
        return false;
      } catch (e2) {
        if (bail(e2)) return false;
        return true;
      }
    }
  }

  function decide(raw, channel) {
    const p = abspath(unquote(raw));
    if (!SRC.has(extOf(p))) return "";
    if (isTemp(p)) return "";
    if (!within(projectRoot, p)) {
      return (
        "Blocked a Bash write to a source file OUTSIDE this session's worktree/project root (" +
        p +
        ", via " +
        channel +
        "). Writing source into a sibling or main checkout corrupts another session's working tree — " +
        "the cross-session contamination this gate prevents. Edit files through the Edit/Write tools inside " +
        "your own worktree. Deliberate one-off: prefix the command with ZENSU_BASH_WRITE_GATE=off."
      );
    }
    if (fs.existsSync(p) && tracked(p)) {
      return (
        "Blocked a Bash write that would overwrite an existing git-tracked source file (" +
        p +
        ", via " +
        channel +
        "). A raw shell write to tracked source bypasses the Edit/Write tools and the review/TDD discipline " +
        "that watch them — route the change through Edit/Write instead. New files, gitignored/untracked files, " +
        "and non-source files are unaffected. Deliberate one-off: prefix the command with ZENSU_BASH_WRITE_GATE=off."
      );
    }
    return "";
  }

  const REDIR = /^(&|\d*)(>>?)(\|?)(.*)$/; // >  >>  &>  2>  >|  (and glued target)

  // Bound the work: a crafted command with thousands of `>> a.rs >> b.rs …`
  // targets would otherwise fan out into thousands of synchronous git calls.
  const MAX_TARGETS = 200;
  let evaluated = 0;

  // `>|` (noclobber override) and `>&FILE`/`>>&FILE` (redirect-all-to-file) are
  // just `>`/`>>` with the same target; collapse them before lexing so the bare
  // `|`/`&` is not taken as a boundary that severs the redirect from its file.
  // fd dups (`>&2`, `>&-`, `2>&1` — a digit or `-` after `&`) are left intact.
  const stack = [];
  const pre = stripHeredocs(cmd)
    .replace(/>\|/g, ">")
    .replace(/(\d*)(>>?)&(?=\s*[^\s0-9&|;<>(\-])/g, "$1$2");
  for (const e of lex(pre)) {
    if (e.t === "enter") { stack.push(curdir); continue; }
    if (e.t === "leave") { if (stack.length) curdir = stack.pop(); continue; }

    const toks = e.text.trim().split(/\s+/).filter(Boolean);
    if (!toks.length) continue;

    let i = 0;
    const envp = {};
    while (i < toks.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[i])) {
      const a = toks[i];
      const eq = a.indexOf("=");
      envp[a.slice(0, eq)] = unquote(a.slice(eq + 1));
      i++;
    }
    const rest = toks.slice(i).filter((t) => t !== "");
    if (!rest.length) continue;

    // Skip transparent wrappers (env/sudo/command/exec/…) and env's VAR=val args
    // so a wrapped builtin still resolves to its real verb for the cmd0 gates.
    let ci = 0;
    while (ci < rest.length && WRAP.has(unquote(rest[ci]).split("/").pop())) {
      ci++;
      while (ci < rest.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(rest[ci])) ci++;
    }
    const cmd0 = ci < rest.length ? unquote(rest[ci]).split("/").pop() : "";

    // `cd` updates the scoped cwd BEFORE the escape-hatch check — an escaped
    // segment may still change the directory for the commands that follow it.
    if (cmd0 === "cd" && rest[ci + 1] !== undefined) {
      curdir = abspath(unquote(rest[ci + 1]));
      continue;
    }
    if (envp.ZENSU_BASH_WRITE_GATE === "off" || envp.ZENSU_MCP_GATE === "off") continue;

    const targets = [];
    for (let k = 0; k < rest.length; k++) {
      const m = rest[k].match(REDIR);
      if (m) {
        if (m[4]) targets.push([m[4], "redirect"]);
        else if (rest[k + 1] !== undefined) { targets.push([rest[k + 1], "redirect"]); k++; }
      }
    }
    const teeIdx = rest.findIndex((t) => unquote(t) === "tee");
    if (teeIdx !== -1) {
      for (let k = teeIdx + 1; k < rest.length; k++) {
        const t = rest[k];
        if (t.charAt(0) === "-") continue;            // flag
        const rm = t.match(REDIR);
        if (rm) { if (!rm[4]) k++; continue; }         // skip a redirect operator (+ its operand)
        targets.push([t, "tee"]);
      }
    }
    if (cmd0 === "sed" && rest.some((t) => /^-i/.test(unquote(t)))) {
      for (const t of rest) {
        const u = unquote(t);
        if (u.charAt(0) !== "-" && SRC.has(extOf(abspath(u)))) targets.push([t, "sed -i"]);
      }
    }
    if (cmd0 === "dd") {
      for (const t of rest) {
        const m = t.match(/^of=(.+)$/);
        if (m) targets.push([m[1], "dd of="]);
      }
    }

    for (let x = 0; x < targets.length; x++) {
      if (++evaluated > MAX_TARGETS) return "";
      const r = decide(targets[x][0], targets[x][1]);
      if (r) return r;
    }
  }
  return "";
}

process.stdout.write(main());
