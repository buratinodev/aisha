# aisha — Improvement Investigation & Implementation Plan

Status: **Phases 1–6 complete (2026-11-13)** · Scope: `aisha.sh`, `aisha_core.py`, README

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
thinking — see README). Test suite: 34. *(The two-model tiers were replaced
by a single model in Phase 6.)*

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

### Phase 6 — Model strategy, review, self-test ✅ DONE (2026-11-13)

Triggered by a real failure: asked to "set qwen3.5:9b-mlx as default in the
.aisha config", the model hand-edited `~/.aisha` — the program itself (the
installed copy was still the pre-Phase-1 monolith) — and broke the shell
integration. The model had no idea where aisha's settings live.

Shipped (v0.6.0):

1. **One model, modes in the prompt.** `AISHA_MODEL` (default
   `gemma4:e4b-mlx`) replaces `AISHA_MODEL_TASK`/`AISHA_MODEL_THINKING`; the
   old keys are ignored with a migration warning. Modes differ only in
   system prompt and thinking (`MODES` table in the core).
2. **Per-mode thinking** via Ollama's `think` request option
   (`llm -o think true|false`, llm-ollama ≥ 0.15). On wherever a command may
   be executed (suggest, refine, review, diagnose/auto-fix, `--deep`, agent
   steps); off for streamed prose (explain questions, `/tips`).
   `AISHA_THINK=auto|on|off`. Models/plugins that reject the option are
   detected from the error and retried without it (cached per process).
3. **Review pass** for sensitive commands: anything `is_risky` or matching
   `SENSITIVE_PATTERNS` (`sed -i`, `perl -i`, redirects into `~`/dotfiles/
   `/etc`, `tee`, `chmod`/`chown`, `defaults write`, `launchctl`, `crontab`,
   ...) gets a second thinking call that returns `OK` or `WARN: reason` +
   optional `SAFER: cmd`. A WARN with a safer command swaps it in (original
   shown); `--json` carries a `review` object; notes go to stderr when
   stdout is piped. `AISHA_REVIEW=0` disables. `-n` skips review (scripts).
4. **`ai /config`** — show (with source: config/env/default), `set`,
   `unset`, `edit`, `path`. Keys validated (`AISHA_` prefix optional),
   enumerated values checked, atomic rewrite preserving other lines. Every
   system prompt now includes `AISHA_SELF`: settings change only via
   `ai /config set`, never edit `~/.aisha`/`~/.aisha-core.py`.
5. **`ai /selftest [model]`** — 11 fixed sed/awk/grep tasks on config-style
   files. Each case writes sample files to a scratch dir (HOME pointed
   there), sends the exact production suggestion prompt (`SUGGEST_RULES`),
   runs the answer, and checks the *outcome* (file content, stdout, or a
   path set) — not the command text. Risky answers are never run. Every
   case has a portable `reference` answer; `--reference` runs those
   instead of the model, which validates the cases themselves in CI.
6. **`ai --upgrade`** — downloads the latest shim + core
   (`AISHA_REPO_RAW` overridable), installs via the *downloaded* installer,
   never downgrades, then offers to `llm install -U llm-ollama` and
   `ollama pull $AISHA_MODEL`.

Also: `ai /selftest`, `/config`, `--upgrade` in help and completion;
installer prints a single `ollama pull`; tests isolate prompts from the
developer's terminal via `AISHA_TTY`. Test suite: 57.

**0.6.1 follow-ups (same day):** the first real `ai --upgrade` ran
`llm install -U llm-ollama`, which also upgraded llm 0.28 → 0.37.2 and
llm-ollama 0.15.1 → 0.19.1, and broke two assumptions: llm-ollama 0.19
registers models as `ollama/<name>` (bare names now fail with "Unknown
model"), and llm 0.37 prints reasoning to stderr. aisha now retries with
the other naming on "Unknown model" (works with old and new plugins) and
only surfaces llm's stderr when the call fails. Also fixed: re-sourcing
0.6 over a pre-0.5 shell left the zsh `accept-line` wrapper without an
original widget ("No such widget"); it now falls back to `.accept-line`.
Test suite: 58.

**0.6.2 — prose vs command:** `ai what's …` was routed as a command request
because the zsh widget's U+02BC apostrophe (`whatʼs`) defeated the
question regex, and the model's prose answer was injected into the input
line. Fixes: the question regex accepts contractions; replies are split into
prose and command (`split_response`: a fenced block is the command, text
around it is the explanation; unfenced text whose first word isn't a
builtin/path/executable on PATH is treated as prose and never injected);
questions may end with a `COMMAND: <cmd>` line (like auto-fix's `FIX:`),
hidden from the rendered answer and delivered to the input line. `--json`
adds `explanation` / `command` fields accordingly. Test suite: 62.

**0.6.3 — agent context and plan-first:** `ai --agent clean the above
containers` (after `docker ps -a`) listed the cwd instead: the agent never
received history.txt. Now every mode gets `HISTORY_NOTE` (history has
commands, not output; "the above" = output of the latest relevant command)
and the agent re-runs read-only commands to see it. The agent now plans
first (`AISHA_AGENT_PLAN=1`): numbered plan → shown with aisha's own
risk colouring (the model's `[changes]` tags proved unreliable) → Y/n →
execution with plan.txt attached; a changing action outside the plan must
end in FAILED. The first real plan included `docker system prune -a`
(deletes all images — far beyond the goal); a "stay strictly within the
goal" rule fixed it. `docker rm/rmi/prune` are now risky, `docker
stop/kill/restart` sensitive. Test suite: 65.

**0.6.4 / 0.6.5 — agent output and plan tracking:** long output lines now
wrap inside the output box at terminal width (ANSI-aware). A real run of
the 4-step container plan succeeded through step 4, then the model called
`read_file(goal.txt)` — the prompt said "the goal is in the attached
goal.txt", which reads like a file on disk — and wandered (ls, README)
until FAILED. Fixes: goal, approved plan, and previous steps are inlined in
the prompt (no internal files attached); the prompt states attachments are
not on disk, and to reply DONE once the last plan step succeeds; progress
shows `step k/N` against the plan (max steps stays a safety cap). Also
found while verifying: the `llm` subprocess inherited aisha's stdin and
consumed the user's piped reply (plan approval); llm now always gets
`stdin=DEVNULL`. Test suite: 66.

---

## Decisions log

**One model with per-mode thinking instead of task/thinking models
(2026-11-13).** Two models cost RAM and, on 16 GB machines, a model swap on
every mode change. Modern small models (Gemma 4, Qwen 3.5) are hybrid
reasoners: the same weights answer fast with thinking off or carefully with
it on, so the "thinking model" role collapses into a request option.

**No fast model by default; no dense "deep" model (2026-11-13).** Measured
on an M-series Mac, same prompts, think off/on:

| Prompt | qwen3.5:4b-mlx off / on | gemma4:e4b-mlx off / on |
|---|---|---|
| 5 largest files | GNU-only flags (broken on macOS) / malformed `-exec` | ok / ok |
| port 8080 | ok / ok | ok / ok |
| delete .log > 7 days | ok / ok | **`find / … -delete`** / ok |
| count Python LOC | counts files, not lines / broken | approx. / ok |
| latency | 0.9–3.7 s / 2.5–6.3 s | 0.8–1.1 s / 1.1–5.3 s |

qwen3.5:4b was no faster and less correct, so a separate fast model buys
nothing; `AISHA_MODEL_FAST` was dropped before shipping. With both models
loaded `ollama ps` showed 5.0 + 9.6 GB resident. A dense deep model was
rejected for a shell assistant: thinking on the main model covers `--deep`,
and a 19 GB load for occasional use isn't worth the RAM; users who want one
can point `AISHA_MODEL` at it. The `find / -delete` row is why thinking is
on for command suggestions by default.

**Thinking control: Ollama `think` option, not prompt tags (2026-11-13).**
`/think` / `/no_think` are Qwen3 soft switches and not part of Gemma 4's
protocol (Gemma uses a `<|think|>` system-prompt token, which Ollama's chat
template manages) — a prompt tag is model-specific and silently ignored
elsewhere. The `think` request option is model-agnostic and exposed by
llm-ollama 0.15.1 as `-o think`. Reasoning text comes back in a separate
field, so it never reaches aisha's output (the `<think>` stripping stays as a
fallback for other backends). Sending `think` to a model without the
capability fails with HTTP 400 ("does not support thinking") — hence the
retry-without-option fallback.

**Review pass instead of more blacklist (2026-11-13).** Config and system
file edits are rarely "destructive" by pattern, but a wrong path, missing
`/g`, overwrite-vs-append, or GNU `sed -i` on macOS silently breaks things.
A second thinking pass that knows the user's intent catches these. Trigger
is pattern-based (cheap; safe commands cost one call), the reviewer is the
same model (no extra RAM). Known limitation from testing: the reviewer can
be over-cautious — for "delete .log files older than 7 days" it swapped
`-delete` for `-print` (safer, but not what was asked); the original is
always shown so the user can take it back.

**Built-in `ai /config` instead of letting the model edit files
(2026-11-13).** A deterministic, validated writer beats any prompt rule. The
prompt rule (`AISHA_SELF`) only has to point the model at the command —
verified with the real model: "set qwen3.5:9b-mlx as default in the .aisha
config" now yields `ai /config set AISHA_MODEL qwen3.5:9b-mlx`.

**Self-test checks outcomes, not command text (2026-11-13).** Many correct
commands exist per task; comparing strings would fail good answers and
miss broken ones. Running in a scratch dir with `HOME` redirected and risky
answers skipped keeps it safe enough for a user-facing command. First
results (10 cases at the time; the replace-all case was added after):

| Model | Score | Time | Failures |
|---|---|---|---|
| gemma4:e4b-mlx | 8/10 | 39 s | `/` delimiter with a URL value (sed parse error); took "host key" literally |
| qwen3.5:4b-mlx | 8/10 | 673 s | same URL-delimiter failure; over-specified grep for the host value |

Both models failing the slash-delimiter case is exactly the kind of bug that
broke the user's config by hand — worth keeping as a regression signal when
trying new models or prompt changes.

**`ai --upgrade` installs with the downloaded installer (2026-11-13).** The
new release may change install logic (files, rc block), so the old core must
not install the new one. Version comparison prevents accidental downgrades
when running from an unreleased clone.

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

Phases 1–6 are complete (2026-11-13). Ideas, roughly by value:

- Prompt work driven by `/selftest`: both models fail values containing
  `/` in `sed` — add a rule ("use `|` as the sed delimiter when the value
  contains `/`") and macOS `sed -i ''` guidance, then re-score.
- Tune the reviewer to keep the requested action (don't downgrade `-delete`
  to `-print` when deletion was asked for); add selftest cases for review.
- `/selftest --json` and a published score table per model in the README.
- The `ai /summarize` lane from the fm decision, if on-device summarization
  ever becomes interesting.
