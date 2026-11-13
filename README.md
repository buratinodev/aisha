# aisha - AI(-powered) Shell Assistant

An AI shell assistant with command suggestions, safety checks, and context awareness. A thin sourced shell shim (`aisha.sh`) owns the shell-integration surface — capturing exit codes and history, injecting suggestions into your editable input line — while a Python core (`aisha_core.py`) does everything else via the `llm` CLI.

## Purpose

**aisha** transforms your shell into an intelligent assistant that:
- **Understands natural language**: Type what you want to do, not the exact command syntax
- **Learns from context**: Automatically considers your current directory, git status, and recent commands
- **Protects you from mistakes**: Requires explicit confirmation for risky operations with color-coded warnings
- **Explains its reasoning**: Can explain why it suggested a command and what it does
- **Fixes errors automatically**: Detects failed commands and suggests corrections

Perfect for:
- Learning new commands and tools
- Working with unfamiliar systems
- Preventing destructive mistakes
- Speeding up common tasks
- Understanding what went wrong when commands fail
- Examples: manipulating docker images and containers, crafting long piped commands like search and execute

## Features

- **Smart Command Suggestions**: Ask in natural language, get shell commands
- **Context-Aware**: Automatically captures shell history, current directory, and git status
- **Safety First**: 
  - Requires explicit "YES" confirmation for risky operations (sudo, rm, dd, shred, kubectl delete, etc.)
  - Standard Y/n confirmation for safe commands
  - Color-coded warnings (red for risky, green for safe, yellow for aborted)
  - Detects complex destructive patterns (e.g., `find ... -exec rm`, `shred`, etc.)
- **Memory**: Remembers last suggestion for quick redo/explain
- **Auto-Fix**: Detects failed commands and suggests fixes
- **Edit-before-run**: Suggestions land in your editable input line (zsh) or history (bash) — review, tweak, run; `AISHA_AUTORUN=1` restores the classic confirm prompt
- **Pipe anything in**: `docker logs app 2>&1 | ai why is this crashing` — piped input becomes context
- **Refinement**: `ai -c "use ripgrep instead"` revises the last suggestion
- **Script-friendly**: `ai -n <request>` prints just the command — usable in `$( )`, pipes, `pbcopy`
- **Streaming answers**: explanations render as they are generated
- **Built-in help & tips**: `ai /help` and `ai /tips [topic]`
- **Tab completion** for subcommands and flags (zsh and bash)
- **Config file**: `~/.config/aisha/config` — no script editing needed
- **Colorized Output**: Preserves colors in ls, grep, diff, and tree commands
- **OS-Aware**: Auto-detects your operating system for platform-specific commands
- **Agent Mode**: Autonomous multi-step task execution with tool use, checkpoints, and safety controls
- **One model, many modes**: a single resident model (`AISHA_MODEL`) serves
  every mode; modes differ in prompt and in whether the model thinks first
- **Second-opinion review**: risky and config/system-file-editing commands
  (`sed -i`, redirects into dotfiles or `/etc`, `chmod`, ...) get a thinking
  review pass before they reach you; a safer alternative replaces a flawed one
- **`ai /selftest`**: score your installed model on sed/awk/grep config tasks
  with known answers
- **`ai /config`**: view and change settings without hand-editing files
- **Dual Personas**:
  - **sysadmin** (default): Concise, practical suggestions
  - **deep**: Step-by-step reasoning with edge case analysis (auto-selected for how/why/what/explain queries)

## Installation

### One-Command Install

```bash
curl -fsSL https://raw.githubusercontent.com/buratinodev/aisha/main/install.sh | bash
```

### From a Clone

```bash
git clone https://github.com/buratinodev/aisha.git
cd aisha
./aisha.sh --install
```

Either way, the installer:
- Copies `aisha.sh` to `~/.aisha` and `aisha_core.py` to `~/.aisha-core.py`
- Detects your shell (bash or zsh) and adds the loader to your
  `~/.bashrc` or `~/.zshrc`
- **Checks dependencies and offers to install what's missing:**
  - `llm` CLI — via Homebrew if available, otherwise `pip install --user llm`
  - `llm-ollama` plugin — via `llm install llm-ollama`
  - `ollama` — via Homebrew on macOS (or a direct download of the latest
    [GitHub release](https://github.com/ollama/ollama/releases) to
    `~/.local/bin`), or the official install script on Linux
- Prints the `ollama pull` command for the default model

Nothing is installed without asking — each missing dependency gets a Y/n
prompt, and in non-interactive runs the installer only prints instructions.

Then load aisha in your current shell:
```bash
source ~/.zshrc  # or source ~/.bashrc for bash users
```

### Upgrading

```bash
ai --upgrade
# Checking https://raw.githubusercontent.com/buratinodev/aisha/main for updates...
# Upgrading aisha 0.5.0 → 0.6.0
# Also upgrade the llm-ollama plugin? [Y/n]:
# Also update the model gemma4:e4b-mlx (ollama pull)? [Y/n]:
```

Downloads the latest release, installs it with its own installer (never
downgrades), then offers to update the `llm-ollama` plugin and pull the
latest build of your configured model. From a clone, `git pull &&
./aisha.sh --install` does the same for aisha itself.

### Uninstall

```bash
ai --uninstall        # or: ./aisha.sh --uninstall
```

Removes `~/.aisha` and `~/.aisha-core.py`, removes the loader block from your
shell rc file (a `.aisha-bak` backup is written first), and offers to delete
the state directory. Your config file is left in place.

### Manual Installation

If you prefer to install manually or need to customize the installation:

1. Copy the shim and the core to your home directory:
   ```bash
   cp aisha.sh ~/.aisha
   cp aisha_core.py ~/.aisha-core.py
   ```

2. Add to your shell configuration file (`~/.bashrc` or `~/.zshrc`):
   ```bash
   # Load AI shell helpers
   if [[ -f "$HOME/.aisha" ]]; then
     source "$HOME/.aisha"
   fi
   ```

3. Reload your shell configuration:
   ```bash
   source ~/.zshrc  # or source ~/.bashrc
   ```

### Prerequisites

You need the `llm` CLI tool with a configured model:

1. Install `llm`:
   ```bash
   pip install llm
   ```

2. Install the Ollama plugin and pull a model:
   ```bash
   llm install llm-ollama
   ollama pull gemma4:e4b-mlx    # the default — ~9.5 GB, supports thinking
   ```

   **One model with thinking is the recommended setup.** A single resident
   model means no swapping between models when you switch modes; the modes
   differ only in prompt and in whether the model thinks first (Ollama's
   `think` option, see `AISHA_THINK`). In local tests `gemma4:e4b-mlx`
   answered in ~1–5 s, beat `qwen3.5:4b-mlx` on correctness at a fraction
   of the time, and with thinking on avoided mistakes it made without it
   (e.g. `find / … -delete` instead of `find . …`).

   To use another model:
   ```bash
   ai /config set AISHA_MODEL qwen3.5:9b-mlx
   ai /selftest                  # check how it does on known tasks
   ```
   Bigger machines can run a larger model the same way (e.g.
   `gemma4:26b-mlx`, MoE with 4B active parameters, or `qwen3.6:35b-mlx`).
   Models without thinking support work too — aisha detects the rejection
   and retries without the option.

   On Apple Silicon, always prefer the `-mlx` tags — they run on the MLX
   backend and are meaningfully faster than the default GGUF builds.

   > **Why not Apple's on-device model (`fm` CLI)?** Considered and
   > rejected: its 4K shared context and Apple's own warning against code
   > generation make it unfit for command suggestions — see the decisions
   > log in `IMPLEMENTATION_PLAN.md`.

## Usage

### Basic Command Suggestions

Simply describe what you want to do in natural language:

```bash
ai list all files
# Suggested command:
#   ls -la
#   ↳ placed in your input line — edit if needed, Enter to run
```

By default the suggestion is injected into your shell's editable input line
(zsh) or pushed to history so `↑` recalls it (bash). You review it, tweak it
if needed, and run it yourself — and it lands in your shell history like any
other command.

Prefer the classic behavior where aisha prompts and runs the command for you?

```bash
export AISHA_AUTORUN=1   # restores: Execute this command? [Y/n]
```

### Conversational Queries

For questions and greetings, aisha responds directly without suggesting a command:

```bash
ai how are you?
# I'm here and ready to help! How can I assist you today?

ai what is a symlink?
# A symlink (symbolic link) is a file that points to another file or directory...
```

> **Note (zsh)**: Special characters like `?`, `*`, and apostrophes work without quoting.
> aisha enables `nonomatch` for glob characters, and a ZLE widget transparently replaces `'` with a
> visually identical Unicode apostrophe (`ʼ` U+02BC) so shell parsing isn't broken.
> If the shell still eats your arguments, aisha falls back to an interactive `Ask:` prompt.

### Piping Input as Context

Anything piped into `ai` is attached as context (capped at 64 KB):

```bash
docker logs app 2>&1 | ai why is this crashing
# Analyzes the log and explains the crash

kubectl describe pod web | ai                 # no question needed —
# piped data with no prompt is summarized and diagnosed automatically

dmesg | tail -50 | ai is this disk failing
```

Set `AISHA_STDIN_CONTEXT=0` to disable this behavior.

### Refining a Suggestion

Not quite what you wanted? Refine it instead of rephrasing from scratch:

```bash
ai find all TODO comments
#   grep -rn "TODO" .

ai -c use ripgrep and include FIXME too
#   rg -n "TODO|FIXME"
```

Refinements chain — each `ai -c` sees the original request plus all previous
feedback.

### Script-Friendly Output

`ai -n` (`--no-exec`) prints only the bare command — no colors, no prompts:

```bash
ai -n list open ports | pbcopy
vim $(ai -n which file defines the ai function in this repo)
```

Piping `ai`'s output does the same automatically: `ai find big files | pbcopy`
gets just the command.

For structured scripting, `ai --json <request>` emits one JSON object —
`{"type": "command", "command": "...", "risky": false, "model": "..."}` for
tasks, `{"type": "answer", ...}` for questions:

```bash
ai --json delete old logs | jq -r 'select(.risky | not).command'
```

### Help and Tips

```bash
ai /help         # usage, flags, configuration reference
ai /tips         # curated power-user one-liners (instant, no model call)
ai /tips awk     # five model-generated one-liners about any topic
ai --version
```

### Settings: `ai /config`

```bash
ai /config                              # effective settings and where each comes from
ai /config set AISHA_MODEL qwen3.5:9b-mlx
ai /config set think off                # AISHA_ prefix optional, case-insensitive
ai /config unset AISHA_THINK
ai /config edit                         # open in $VISUAL / $EDITOR
```

Unknown keys and invalid values are rejected; the file is rewritten
atomically and other lines are kept. The model also knows this command —
`ai set qwen3.5:9b-mlx as my model` suggests `ai /config set ...` instead of
hand-editing files.

### Model self-test: `ai /selftest`

```bash
ai /selftest                  # the configured model
ai /selftest qwen3.5:9b-mlx   # any installed model, without switching
```

Eleven fixed tasks on config-style files — in-place `sed` edits (including
values with slashes and replace-all), appending to a dotfile, `grep`
filtering/counting/recursive search, `awk` columns and sums, extracting a
config value. Each case creates sample files in a throwaway directory
(with `HOME` pointed at it), runs the model's command there, and checks the
**result** — the edited file or the output — not the command text, so any
working command passes and GNU-only flags on macOS fail. Commands flagged
risky are never run.

```
✓ sed: change a value in place (6.2s)
✗ sed: value containing slashes (4.6s)
    sed -i '' 's/^DATABASE_URL=.*/DATABASE_URL=postgres://db:5432/app/' .env
    .env is now: ...
9/11 passed in 41.3s
```

### Risky Command Handling

Risky commands (sudo, rm, dd, kubectl delete, ...) always get a red warning
under the suggestion:

```bash
ai delete all .tmp files
# Suggested command:
#   find . -name "*.tmp" -type f -exec rm {} +
#   ⚠️  Review carefully — this command can be destructive.
```

When aisha executes commands itself (`AISHA_AUTORUN=1`, `ai redo`, agent
mode), destructive commands additionally require typing "YES" (not just Y):

```bash
ai redo
# ⚠️  Risky command detected.
# Type YES to execute (Ctrl+C to abort):
```

**Risky commands include**:
- `sudo` - privilege escalation
- `rm` - file deletion (including all variants)
- `dd`, `mkfs` - disk operations
- `shred` - secure deletion
- `find ... -exec rm/shred` - bulk deletion
- `kubectl delete` - Kubernetes resource deletion
- `terraform apply/destroy` - infrastructure changes
- `gcloud delete` - cloud resource deletion

### Review of Sensitive Commands

Risky commands and commands that edit config or system files (`sed -i`,
`perl -i`, `>`/`>>` into dotfiles, `~`, or `/etc`, `tee`, `chmod`/`chown`,
`defaults write`, `launchctl`, `crontab`, ...) get a second, thinking pass
that checks the command against your request: right file, right scope,
append vs overwrite, a backup for edited configs, macOS vs GNU flags.

```bash
ai change a to b in my zshrc
# 🔎 Review: edits ~/.zshrc without a backup
#   original: sed -i '' 's/a/b/' ~/.zshrc
# Suggested command:
#   sed -i.bak 's/a/b/' ~/.zshrc
```

When the review finds a problem and offers a safer command, the safer one is
what lands in your input line (the original is shown). `--json` output
includes a `review` object. Disable with `ai /config set AISHA_REVIEW 0`.
The reviewer is the same model — a second look, not a guarantee.

### Explanation Mode

Get a detailed explanation of the last suggested command:

```bash
ai explain
# Provides detailed explanation of why the command was suggested,
# what it does, and any potential risks
```

Queries starting with how/why/what/explain/help get the deep persona:

```bash
ai what is the difference between hard links and symlinks
```

### Agent Mode

For complex, multi-step tasks, use agent mode. The agent first shows a plan
and waits for your OK, then executes it step by step:

```bash
ai --agent clean the above containers
#   📋 Plan
#     1. docker ps -a
#     2. docker stop $(docker ps -aq)
#     3. docker rm $(docker ps -aq)  ⚠️
#
#   Execute this plan? [Y/n]:
```

Read-only steps are white, steps that change things are yellow, risky ones
red with ⚠️ (aisha marks these itself rather than trusting the model). The
agent follows the approved plan and stops with FAILED instead of taking a
changing action the plan doesn't cover. Risky steps still require typing
YES during execution. Skip planning with `ai /config set AISHA_AGENT_PLAN 0`.

The agent sees your recent shell history (not its output), so "the above
containers" resolves to your last `docker ps -a` — it re-runs read-only
commands like that to see the output.

```bash
ai --agent set up a new git repo with .gitignore for Node.js
# ╔══════════════════════════════════════════════════════════╗
# ║  🤖 Agent Mode                                         ║
# ║  Goal: set up a new git repo with .gitignore for Node.js║
# ║  Max steps: 15 │ Ctrl+C to abort                       ║
# ╚══════════════════════════════════════════════════════════╝
#
#   ⚡ Run  step 1/15  [██░░░░░░░░] 6%
#   $ git init
#   ┌──────────────────────────────────────────────────────
#   │ Initialized empty Git repository in ...
#   └──────────────────────────────────────── ✓ exit 0 ──
#   ...
#   ✅ Done! Completed in 3 step(s)
```

**Safe mode** — requires confirmation before each action:

```bash
ai --agent-safe reorganize the project structure
# Each step will prompt: Allow? [Y/n/skip]:
# - Y: execute the action
# - n: abort the agent entirely
# - s/skip: skip this step and continue
```

**Continuation** — when the agent reaches the max steps limit, it asks if you want to keep going:

```
  ⚠️  Reached max steps (15) without completing goal.
  Continue for another 15 steps? [Y/n]:
```

The step counter resets and the agent continues where it left off.

**Resume from checkpoint** — if an agent run is interrupted or paused:

```bash
ai --agent --resume
# Picks up from the last saved checkpoint
```

#### Agent Tools

The agent has access to these built-in tools:

| Tool | Description |
|------|-------------|
| `COMMAND: <cmd>` | Execute any shell command |
| `TOOL:read_file(<path>)` | Read a file's contents |
| `TOOL:write_file(<path>, <content>)` | Write content to a file |
| `TOOL:search(<pattern>, <dir>)` | Search for text in files |
| `TOOL:web_fetch(<url>)` | Fetch a URL's content |
| `TOOL:list_dir(<path>)` | List directory contents |

#### Agent Safety

- Risky commands (rm, sudo, etc.) always require confirmation, even in auto mode
- `rm -rf` is blocked entirely
- Use `--agent-safe` to approve every action individually
- Checkpoints are saved after each step so you can resume if interrupted

### Auto-Fix Mode

Just run `ai` (no arguments) after a command fails:

```bash
$ kubectl get pod
error: the server doesn't have a resource type "pod"

$ ai
# Explains: the resource type should be "pods" (plural), then:
# Suggested command:
#   kubectl get pods
#   ↳ placed in your input line — edit if needed, Enter to run
```

Auto-fix streams an explanation of the failure and then delivers the
corrected command straight to your input line, ready to run. If a command was
previously run through aisha, its captured output (`last_output.txt`) is
attached as context.

aisha can't see the output of commands you ran directly (the shell doesn't
capture it). When the error message matters, use `ai rerun`: it re-runs your
last command with output capture, and if it fails, diagnoses it with the full
output attached:

```bash
$ ai rerun
# Re-running to capture output:
#   kubectl get pod
# Execute this command? [Y/n]:
# ... diagnosis with the actual error text, corrected command in your buffer
```

### Special Commands

**Redo last suggestion**:
```bash
ai redo
```

**Re-run your last command with output capture, then diagnose**:
```bash
ai rerun
```

**Explain last suggestion**:
```bash
ai explain
```

**Deep thinking mode** (deep persona, thinking on):
```bash
ai --deep migrate database from postgres to mysql
```

## Safety Features

- **Review-before-run by default**: suggested commands are placed in your
  editable input line, never executed behind your back — you are the final
  safety layer
- **Strict confirmation** (must type "YES") whenever aisha executes commands
  itself (`AISHA_AUTORUN=1`, `ai redo`, agent mode) for risky operations:
  - `sudo` - privilege escalation
  - `rm` - all file deletion commands (including `-rf`, `-r`, etc.)
  - `dd`, `mkfs` - disk operations
  - `shred` - secure deletion
  - `find` with `-exec rm` or `-exec shred` - bulk deletion
  - `mv` to deleted/trash directories
  - `kubectl delete` - Kubernetes deletions
  - `terraform apply/destroy` - infrastructure changes
  - `gcloud delete` - cloud resource deletion
- **Standard confirmation** (Y/n) for all other commands
- **Color-coded warnings**: Red for risky, green for safe, yellow for aborted
- **Preserved command output**: Colors maintained for ls, grep, diff, tree
- **Context awareness**: Considers your location, git state, and recent history

### Aborting Commands

- **Standard commands**: Press `n` and Enter, or just Enter to accept
- **Risky commands**: Type anything except "YES" to abort
- **Anytime**: Press `Ctrl+C` to abort immediately

## Shell Integration

Tab completion for subcommands and flags (`redo`, `explain`, `/config`,
`/selftest`, `/help`, `/tips`, `--deep`, `--agent`, `-n`, `-c`, ...) is
registered in both zsh (requires `compinit`) and bash.

When running in zsh, aisha enables two additional quality-of-life features:

- **`setopt nonomatch`** — Glob characters (`?`, `*`) are passed literally instead of causing errors, so you can type `ai what?` without quoting.
- **ZLE apostrophe widget** — A lightweight `accept-line` widget detects lines starting with `ai ` that contain `'` and replaces them with the visually identical Unicode right single quotation mark (`ʼ` U+02BC). This prevents the shell from interpreting the apostrophe as an unterminated single quote. Your history stays clean: `ai whatʼs cooking?`.
- **Interactive fallback** — If the shell still consumes your arguments (edge cases), aisha detects the empty prompt and presents an `Ask:` prompt so you can type your question interactively.

These features are invisible in normal use — just type naturally.

## Architecture

Two files:

- **`aisha.sh`** — a thin sourced shim (~200 lines). It owns only what a
  child process cannot do: capture `$?` at `ai()` entry, dump shell history
  (`fc`), inject the suggested command into your input buffer (`print -z` in
  zsh, `history -s` in bash), and register the ZLE widget and tab completion.
- **`aisha_core.py`** — the Python core (stdlib only). Flag parsing, context
  assembly, llm calls, markdown rendering, the risk engine, state management,
  confirm-and-run, and the agent loop (with real JSON checkpoints).

The two communicate through the session state directory: the shim writes
`history.txt` before invoking the core; the core writes `inject.txt` when a
command should land in your input buffer.

The safety model is honest heuristics, not a sandbox: risky-pattern matching
catches common destructive commands (including behind `;`, `|`, `&&`), but
you reviewing the command in your input line is the real safety layer.

## How It Works

1. Detects your OS at startup (e.g., `Darwin/arm64 macOS 15.3`)
2. Captures context (shell history, pwd, git status, last exit code)
3. Picks the mode — every mode uses the same model (`AISHA_MODEL`), with its
   own prompt and thinking on or off (see the table under Customization)
4. Sends your prompt + context + OS info to the model
5. Gets back a suggested command (or a direct answer for informational queries)
6. Reviews it with a second thinking pass if it is risky or edits config/system files
7. Presents it for review in your input line
8. Confirms before execution when aisha runs it itself (stricter for risky commands)

## File Structure

State lives under `${XDG_STATE_HOME:-~/.local/state}/aisha/`. Each shell
session gets its own directory (keyed by shell PID), so concurrent terminals
never clobber each other's suggestions, context, or agent checkpoints. A
`latest` symlink always points at the most recently active session, and stale
session directories from closed shells are pruned automatically.

```
~/.local/state/aisha/
├── latest -> session-<pid>     # Most recently active session
└── session-<pid>/
    ├── last_command.txt    # Last suggested command
    ├── last_prompt.txt     # Original user intent (passed to LLM via -f)
    ├── last_persona.txt    # Persona used (sysadmin/deep)
    ├── last_output.txt     # Output from last execution
    ├── last_context/
    │   ├── history.txt     # Last 15 shell commands
    │   ├── pwd.txt         # Current directory
    │   ├── git.txt         # Git status
    │   └── exit.txt        # Last exit code
    └── agent/              # Agent mode state
        ├── goal.txt            # Agent goal (passed to LLM via -f)
        ├── mode.txt            # Agent mode (auto/safe)
        ├── history_context.txt # Rolling context (last 5 steps, truncated)
        ├── agent_log.txt       # Cumulative log
        └── checkpoints/
            ├── step_1.json         # Per-step metadata
            ├── step_1_output.txt   # Step output
            ├── step_2.json
            └── step_2_output.txt
```

## Customization

All settings are environment variables with sensible defaults. The cleanest
way to customize is `ai /config set` (or the config file it writes — plain
shell assignments, read at load, survives updates):

```bash
# ~/.config/aisha/config
AISHA_MODEL="qwen3.5:9b-mlx"
AISHA_AGENT_MAX_STEPS=25
AISHA_AUTORUN=1        # classic confirm-and-run instead of buffer injection
AISHA_STDIN_CONTEXT=0  # never read piped stdin as context
```

Exporting the same variables before the aisha loader in your shell rc file
works too (the config file takes precedence).

### Model and Thinking
```bash
AISHA_MODEL="gemma4:e4b-mlx"   # the one model every mode uses
AISHA_THINK=auto               # auto (per mode, below) | on | off
AISHA_REVIEW=1                 # second-pass review of sensitive commands
```

| Mode | Thinking (`auto`) |
|------|-------------------|
| Command suggestions, `ai -c` refine | on |
| Review of sensitive commands | on |
| Auto-fix, `ai rerun`, piped-input diagnosis | on |
| `--deep` | on |
| Agent steps | on |
| how/why/what/explain questions, `ai explain` | off (answers stream immediately) |
| `ai /tips <topic>` | off |

Thinking is on wherever a command may end up being run: correctness over
speed. `AISHA_MODEL_TASK` / `AISHA_MODEL_THINKING` from earlier versions are
no longer used; aisha warns if it finds them.

### Agent Settings

Adjust the maximum steps per batch before the agent asks to continue:
```bash
AISHA_AGENT_MAX_STEPS=15
```

Configure which tools the agent can use:
```bash
AISHA_AGENT_TOOLS="command,read_file,write_file,search,web_fetch"
```

### Adjust Safety Rules
Modify the risky command detection regex in the `_ai_confirm_and_run` function to add or remove patterns.

### Customize Colors
Change the color definitions at the top of the script:
```bash
AISHA_COLOR_RED="\033[1;31m"
AISHA_COLOR_GREEN="\033[1;32m"
AISHA_COLOR_YELLOW="\033[1;33m"
AISHA_COLOR_CYAN="\033[1;36m"
AISHA_COLOR_RESET="\033[0m"
```

Set them to empty strings to disable colors:
```bash
AISHA_COLOR_RED=""
AISHA_COLOR_GREEN=""
# ... etc
```

### Add Custom Personas
Add new persona modes by extending the persona flag logic around line 52.

## Requirements

- bash or zsh shell
- `python3` (3.8+) — runs the aisha core
- `llm` CLI tool with `llm-ollama` plugin
- LLM model via Ollama — default `gemma4:e4b-mlx` (~9.5 GB; fine on 16 GB
  Apple Silicon)

## Development

```bash
make check   # shellcheck (lint policy in .shellcheckrc)
make test    # bats test suite (the llm CLI is stubbed — no models needed)
```

Install the tooling with `brew install shellcheck bats-core` (macOS) or
`apt-get install shellcheck bats` (Debian/Ubuntu). CI runs both on every push.

## License

MIT

## Contributing

Feel free to submit issues or pull requests!
