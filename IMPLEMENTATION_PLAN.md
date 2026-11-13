# aisha — Improvement Investigation & Implementation Plan

Status: **all phases complete (2026-11-13)** · Scope: `aisha.sh`, `aisha_core.py`, README

This document captures a code-level audit of aisha and a phased plan to fix the
weaknesses and close the gap to what a power user expects from a shell AI
assistant.

---

## Part 1 — Findings

### A. Confirmed bugs (fix first)

1. **`last_exit` never reflects the user's last command** (`aisha.sh:118-125`).
   `_ai_capture_context` sets `last_exit=$?` *after* running `git status`, so it
   captures git's exit code, not the user's previous command. Consequences:
   - Outside a git repo, bare `ai` **always** enters auto-fix mode ("your last
     command failed") because `git status` exits 128.
   - Inside a git repo, auto-fix **never** triggers, because `git status`
     succeeds.
   The real `$?` must be captured as the very first statement of `ai()` before
   anything else runs.

2. **Literal `\n` in source** (`aisha.sh:263`).
   `local _ai_interactive=false\n  local exit_code` is one line containing a
   literal backslash-n. The shell parses this as
   `local _ai_interactive=falsen local exit_code` — the variable's value is the
   string `falsen`, and `if $_ai_interactive` then executes a command named
   `falsen`, printing "command not found" to stderr on every non-interactive
   execution. (It accidentally behaves like `false` because the command fails,
   which is why it went unnoticed.)

3. **`ai explain <question>` and `ai redo <anything>` are hijacked**
   (`aisha.sh:780, 794`). The subcommand check is `[[ "$1" == "explain" ]]`
   with no check that it's the *only* argument, so `ai explain what cron does`
   tries to explain the last suggested command instead of answering the
   question. Guard with `$# -eq 1`.

### B. Design weaknesses

4. **`eval` + Y/n is the wrong execution model for power users.** The single
   highest-impact change available: instead of `eval`-ing the suggestion behind
   a confirm prompt, **inject the suggested command into the shell's input
   buffer** (`print -z` in zsh, `READLINE_LINE` via a bound widget or
   `history -s` fallback in bash). The user can then edit it, run it, or
   discard it — and it lands in shell history naturally. This also eliminates a
   whole class of `eval` quoting/safety problems and removes the need for the
   interactive-command detection hack (the command runs as a normal top-level
   command, so `htop`, `vim`, pipelines, `cd` all just work).

5. **Risk detection is a bypassable blacklist** (`aisha.sh:93`).
   `_AI_RISKY_RE` requires whitespace before the keyword, so `echo x;rm -rf y`,
   `/bin/rm`, `command rm`, `xargs rm`, `$(rm …)`, backticks, `curl … | sh`,
   `chmod -R 777 /`, `git push --force`, and `> /dev/sda` all sail through.
   A regex blacklist can never be sound; treat it as a heuristic and
   compensate: (a) widen the pattern set, (b) match after `;`, `|`, `&`, `$(`,
   (c) make the rules user-configurable (allow/deny lists in config), and
   (d) lean on the buffer-injection model from #4 so the user always sees and
   edits the command before the shell runs it.

6. **First-line truncation destroys multi-line output**
   (`_ai_strip_response`, `aisha.sh:129-142`). `head -1` means any multi-line
   suggestion (heredocs, `for` loops, `write_file` with real content) is
   silently truncated to its first line — and if the model prefixes one line of
   prose, the prose becomes the "command". Better: extract the first fenced
   code block if present, else take the full trimmed response; ask the model
   for a fenced block in the prompt.

7. **Agent tool-call parsing is comma-split and unquoted**
   (`_ai_agent_dispatch_tool`, `aisha.sh:343-379`). `write_file(path, content)`
   breaks on any content containing a comma, parenthesis, or newline. Checkpoint
   "JSON" is written with string interpolation and read back with `grep`/`sed`.
   Either define a line-oriented protocol (`TOOL write_file <path>` + heredoc
   body) or require JSON tool calls and parse with `python3 -c`/`jq` (python3
   is already a soft dependency).

8. **Shared, predictable state dir `/tmp/ai`** (`aisha.sh:775`). World-visible
   on multi-user machines (symlink/snoop risk), and two concurrent terminals
   clobber each other's `last_command.txt`, agent checkpoints, and context.
   Move to `${XDG_STATE_HOME:-$HOME/.local/state}/aisha/<session-pid>/` with a
   cleanup trap, keeping one stable "latest" symlink for `redo`/`explain`.

9. **Global namespace pollution.** `COLOR_*`, `AI_MODEL_*`, `AI_OS`,
   `last_exit` (leaks from `ai()` as a global) are all exported into every
   interactive shell. Prefix everything `AISHA_`/`_aisha_` and declare locals.

10. **`accept-line` widget is hostile to other zsh plugins**
    (`aisha.sh:940-947`). `zle -N accept-line` unconditionally replaces
    whatever widget zsh-autosuggestions/syntax-highlighting/etc. installed, and
    the U+02BC substitution mutates quoted strings too (`ai 'find x'` →
    `ai ʼfind xʼ`). Wrap the *existing* widget instead of replacing it, and only
    rewrite apostrophes outside quotes — or drop the hack and lean on the
    `Ask:` fallback plus a documented `ai -- "quoted question"` form.

11. **No configuration surface.** Models, max steps, risky patterns, and colors
    are hardcoded; the installer copies the script to `~/.aisha`, so every
    customization is lost on update. Add `~/.config/aisha/config` (simple
    sourced shell file) read at load, with env-var overrides
    (`AISHA_MODEL_TASK=…`). Keep script defaults as fallback.

12. **Auto-fix can't see the error it's fixing.** The most valuable context for
    "why did my last command fail" is its stderr, which aisha never has (it only
    captures output of commands *it* ran). Document the limitation, and offer an
    opt-in `precmd`/`PROMPT_COMMAND` hook or an `ai rerun` helper that re-runs
    the last history entry capturing output, then diagnoses.

13. **Zero tests, zero lint, no CI.** shellcheck isn't run (several of the bugs
    above are shellcheck-detectable, including the literal `\n`), and there is
    no bats suite. For a project whose core is "eval what an LLM said", a test
    harness with a mocked `llm` binary is essential.

### C. Power-user gaps (missing features)

- **`ai --help` / `ai --version`** — currently nothing; flags are ad-hoc parsed
  and order-sensitive (`ai --deep --agent` silently misbehaves).
- **Non-interactive mode**: `ai -n "find big files"` → print the command to
  stdout, no prompt — enables `$(ai -n …)`, scripting, and piping to `pbcopy`.
- **Stdin as context**: `docker logs app 2>&1 | ai why is this crashing` —
  detect a non-tty stdin and attach it to the prompt. This is the killer
  feature of comparable tools.
- **Refinement loop**: after a suggestion, allow `r`/`ai -c "use ripgrep
  instead"` to revise the previous suggestion with conversation context
  (the `llm` CLI already supports `-c` continuation).
- **Streaming output** for explain/deep modes instead of a silent block until
  the full response arrives (pipe `llm` output through the renderer line by
  line — the renderer already reads line-wise, just don't buffer).
- **Shell completion** for `ai` subcommands/flags (zsh compdef + bash
  complete).
- **Interactive-command detection misses pipelines** (`ps aux | less`) —
  moot if #4 (buffer injection) lands, since the shell runs the command itself.

---

## Part 2 — Implementation plan

Ordered so each phase is independently shippable; earlier phases reduce risk
for later ones.

### Phase 1 — Correctness & hygiene ✅ DONE (2026-11-13)

Shipped: `$?` captured at `ai()` entry (auto-fix fixed both ways); literal `\n`
bug fixed; `redo`/`explain` guarded to bare form; all globals renamed to
`AISHA_*` with env-var overrides; state moved to
`${XDG_STATE_HOME:-~/.local/state}/aisha/session-<pid>` with a `latest`
symlink and dead-session pruning; `CLICOLOR_FORCE` preserved; shellcheck clean
(policy in `.shellcheckrc`); 16-test bats suite with a stubbed `llm`;
`Makefile` + GitHub Actions CI.

1. Capture `$?` as the first statement of `ai()`; thread it into
   `_ai_capture_context` instead of computing it there. Fixes auto-fix in both
   directions (findings #1).
2. Fix the literal `\n` on line 263 (finding #2).
3. Guard `redo`/`explain` subcommands with `[[ $# -eq 1 ]]` (finding #3).
4. Namespace all globals `AISHA_*`, make function-locals `local`, stop leaking
   `last_exit` (finding #9). Preserve `CLICOLOR_FORCE`'s prior value instead of
   unsetting.
5. Move state from `/tmp/ai` to XDG state dir with per-session subdir +
   `latest` symlink (finding #8).
6. Add `shellcheck` to the repo (Makefile target or `./aisha.sh --check`), fix
   all findings; add GitHub Actions running shellcheck on push.
7. Add a minimal bats test suite with a stub `llm` on `$PATH`
   (echoes canned responses): tests for strip/render helpers, risky-regex
   cases, subcommand routing, and the auto-fix trigger logic.

**Exit criteria**: shellcheck clean, bats green in CI, bare `ai` behaves
correctly inside and outside git repos.

### Phase 2 — Execution model & core UX ✅ DONE (2026-11-13)

Shipped: buffer injection as the default execution model (`print -z` in zsh,
`history -s` in bash; `AISHA_AUTORUN=1` for legacy confirm-and-eval; bare
command when stdout is piped or the shell is non-interactive); order-free flag
parser with `--help`/`--version`; `ai -n/--no-exec`; piped stdin as context
(64 KB cap, `/dev/tty` fallback for prompts, `AISHA_STDIN_CONTEXT=0` to
disable, bare-pipe auto-diagnosis); `ai -c/--refine` with chained feedback;
config file at `~/.config/aisha/config`; streaming via `PYTHONUNBUFFERED=1`
for all explanation modes; zsh+bash completion; `ai /help`; `ai /tips [topic]`
(curated list instant, topic mode via task model). The confirm-prompt
e(dit)/x(plain) sub-options from item 5 were dropped: buffer injection makes
editing the default.

Follow-up additions (same day): auto-fix now attaches `last_output.txt` when
present and ends by extracting the model's `FIX:` line and delivering the
corrected command to the input buffer; `ai rerun` (pulled forward from Phase
5) re-runs the last history command with output capture and diagnoses
failures. Along the way a long-standing bug surfaced: `_ai_confirm_and_run`
read `PIPESTATUS[0]` *after* a `[[ ]]` test had already reset it, so executed
commands always reported exit code 1 in bash — fixed by capturing immediately
after the pipeline. Test suite: 31.

1. **Buffer injection instead of eval** (finding #4): on accept, place the
   suggested command into the editing buffer (`print -z` / `READLINE_LINE`;
   `history -s` + echo fallback for plain bash). Keep an opt-in
   `AISHA_AUTORUN=1` for the old confirm-and-eval behavior. The risky-command
   warning becomes an advisory banner rather than a gate.
2. `ai --help`, `ai --version`, and a single ordered flag parser (`while`
   over `$@`) so `--deep`, `--agent`, `-n` compose predictably.
3. **Non-interactive mode** `ai -n/--no-exec`: print the bare command to
   stdout, suppress colors when stdout is not a tty.
4. **Stdin context**: if stdin is not a tty, read it (bounded, e.g. last 400
   lines) into the context dir and attach with `-f`.
5. **Refinement**: `ai -c <feedback>` re-prompts with the previous
   prompt+suggestion as context; offer `e`(dit)/`r`(efine)/`x`(plain) in the
   confirm prompt for the autorun path.
6. **Config file** `~/.config/aisha/config` sourced at load; document all
   `AISHA_*` knobs there; installer no longer requires editing the script
   (finding #11).
7. **Streaming output** for explain/deep/auto-fix modes: pipe `llm` through
   `_ai_render_markdown` directly instead of buffering the full response —
   the renderer already works line-by-line.
8. **Shell completion**: zsh `compdef` + bash `complete` for subcommands
   (`redo`, `explain`, `/help`, `/tips`) and flags (`--deep`, `--agent`,
   `--agent-safe`, `-n`, `-c`).
9. **`ai /help`** (and `--help`): usage summary — subcommands, flags, safety
   model, config knobs — rendered through the markdown renderer. Slash-style
   subcommands avoid colliding with natural-language prompts ("ai help me…"
   still routes to the LLM).
10. **`ai /tips`**: curated power-user one-liners shipped with aisha (static
    list, no LLM call — instant), e.g. context-aware gems per tool (git, find,
    awk, docker, kubectl). `ai /tips <topic>` asks the task model for five
    one-liners on that topic. Rotating "tip of the day" on plain `ai /tips`.

**Exit criteria**: `vim`, `htop`, pipelines, and `cd` suggestions all work with
no special-casing; `$(ai -n "…")` usable in scripts; README rewritten around
the new flow.

### Phase 3 — Architecture split: thin shim + Python core ✅ DONE (2026-11-13)

Shipped: `aisha.sh` reduced to a ~200-line shim ($? capture, fc history dump,
inject.txt buffer injection, ZLE/completion, installer); `aisha_core.py`
(stdlib-only Python) now owns flags, context, llm calls, rendering, risk
engine, state, confirm-and-run, and the agent loop. Hardening landed with the
port: \b-anchored risky patterns catch separators (`;rm`, `|sh`, `&&sudo`)
plus new patterns (git push --force, chmod 777, curl|sh, /dev/sd writes) with
`AISHA_RISKY_EXTRA`/`AISHA_RISKY_ALLOW` config; multi-line suggestions via
fenced-block extraction; agent gets real JSON checkpoints, byte-budgeted
history, enforced tool gating, cwd-tracking + restore on resume, stdlib
web_fetch with byte cap; markdown renderer is one pass in Python. Model
defaults re-tiered for Apple Silicon (48 GB: qwen3.6:35b-mlx task /
gemma4:31b-mlx thinking; 16 GB: gemma4:e4b-mlx task / qwen3.5:9b-mlx
thinking — see README). Test suite: 34.

Original rationale and the single-file-install discussion follow.

The shell implementation had hit its ceiling: ad-hoc parsing, string-built
JSON, sed pipelines per rendered line, and quoting hazards in every `eval`.
The target architecture:

- **A thin sourced shim (~150 lines of shell)** that owns only the
  shell-integration surface — the things a child process cannot do:
  - capture `$?` at `ai()` entry
  - dump shell history (`fc`) and hand off cwd/session identity
  - invoke the core, passing interactivity flags and inheriting stdin/tty
  - inject the returned command into the input buffer (`print -z` /
    `history -s`)
  - ZLE widget, `nonomatch`, tab completion registration
- **A Python core** that does everything else: flag parsing, context
  assembly, llm calls, markdown rendering, risk engine, state management,
  confirm-and-run, and the agent loop.

Python is the pragmatic core choice: `llm` is already a Python dependency and
`python3` is already a soft requirement, so this adds zero install burden.
The core shells out to the `llm` CLI (keeps model config, plugins, and the
test stub working unchanged).

The former safety-hardening and agent-robustness phases land naturally as
part of the port, where they are easy instead of painful:

1. Risk engine: match risky patterns after separators (`;`, `|`, `&&`,
   `$(`), add missing patterns (`git push --force`, `chmod -R 777`,
   `curl … | sh`), warn/confirm levels, user-configurable allow/deny lists
   (finding #5).
2. Multi-line suggestions: fenced-block extraction instead of first-line
   truncation (finding #6).
3. Agent: real JSON checkpoints and robust tool-call parsing (finding #7),
   byte-budgeted step history instead of `head -5`, enforced tool gating
   (`AISHA_AGENT_TOOLS`), honest `--resume` (restore cwd), `web_fetch` with
   byte caps.
4. Markdown renderer in Python: one pass, no subprocesses per line.
5. Document the safety model honestly in the README: heuristics, not a
   sandbox; the user reviewing the buffer is the real safety layer.

**Open discussion — single-file install:** it would be nice to keep a
"one file, one `--install`" story (like a Node install script). Options:
(a) ship two files, installer copies both — simplest, current direction;
(b) embed the Python core in the shim as a heredoc that self-extracts to
`~/.local/share/aisha/core.py` on load — true single file, but adds a build
step or careful escaping maintenance; (c) installer downloads the core from
the repo — adds a network dependency. Decide once the core stabilizes;
(a) is the default until then.

### Phase 5 — Polish

1. ~~Streaming render~~ → moved to Phase 2, item 7 (user-requested).
2. ~~zsh/bash completion~~ → moved to Phase 2, item 8 (user-requested).
3. ~~Rework the zsh apostrophe widget~~ → shipped (2026-11-13): the widget
   now wraps any previously-installed `accept-line` widget (saved and
   chained, so zsh-autosuggestions and friends keep working) and only
   rewrites contraction apostrophes between letters — quoted args like
   `'find x'` are left intact (finding #10).
4. ~~`ai rerun`~~ → shipped early with the Phase 2 follow-ups (finding #12).
5. ~~Installer~~ → shipped (2026-11-13): installer moved into the Python core
   (shim only bootstraps it when executed); `--install` is version-aware and
   upgrades in place; `--uninstall` removes both files and the rc-file block
   (with backup) and offers to delete state; dependency checks offer to
   install `llm` (brew/pip), the `llm-ollama` plugin, and `ollama` (brew,
   GitHub-release download to `~/.local/bin` on macOS, official script on
   Linux) — each behind a Y/n prompt, instructions-only when non-interactive.
   **Single-file install decided:** option (c) — a curl-able `install.sh`
   that downloads both files and runs the installer. Option (b) (heredoc
   embedding) rejected: escaping maintenance outweighs the benefit now that
   `install.sh` gives the same one-command experience.

---

## Decisions log

**Apple on-device Foundation Model (`fm` CLI) — considered, rejected
(2026-11-13).** macOS ships an `fm` command (Apple Silicon, ~3B params) that
looked attractive as an ollama alternative: zero download, always resident,
no server, battery-friendly. Rejected as an aisha backend because it is unfit
for the core workloads: a 4,096-token context window shared across
instructions/prompt/response (our context attachments alone can exceed it),
and Apple's own guidance warns against code generation and notes it
"frequently hallucinates procedural steps" and is "poor at troubleshooting
terminal errors" — which are exactly aisha's task model, auto-fix, and agent
jobs. A fast wrong command is worse than a slow right one. For a light-RAM
setup, `qwen3.5:4b-mlx` (~3.5 GB) via ollama is the better option and keeps
the single `llm` seam. Revisit if an `llm` plugin for Apple Foundation Models
appears (that would make it a zero-code config choice) or Apple ships a
code-capable tier; a narrow `ai /summarize` lane over piped text would be the
one defensible use (summarization is fm's strength).

## Next up

All planned phases and findings are addressed (2026-11-13): agent bats
coverage landed (multi-step plans, risky gating, tool gating, resume — via a
response queue in the llm stub) and `ai --json` shipped for scripting.
Remaining ideas are nice-to-haves: an end-to-end pass against the real
models, and the `ai /summarize` lane from the fm decision above if on-device
summarization ever becomes interesting.
