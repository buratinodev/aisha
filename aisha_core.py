#!/usr/bin/env python3
"""aisha core — all logic behind the thin sourced shell shim (aisha.sh).

The shim owns the shell-integration surface ($? capture, history dump, buffer
injection, ZLE/completion); this core does everything else: flag parsing,
context assembly, llm calls, markdown rendering, risk engine, state
management, confirm-and-run, and the agent loop.

Environment contract with the shim:
  AISHA_LAST_EXIT    exit code of the user's previous command
  AISHA_INTERACTIVE  "1" when the invoking shell is interactive
  AISHA_SHELL        "zsh" or "bash"
  AISHA_SESSION_DIR  per-shell-session state directory
  AISHA_STATE_ROOT   state root (for the `latest` symlink)

The shim injects $AISHA_SESSION_DIR/inject.txt into the input buffer after
the core exits, when that file exists.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import time

VERSION = "0.5.0"

# ============================================================================
# Configuration  (precedence: config file > environment > defaults)
# ============================================================================

DEFAULTS = {
    # Defaults sized for ~48GB Apple Silicon; see README for a 16GB tier
    "AISHA_MODEL_TASK": "qwen3.6:35b-mlx",
    "AISHA_MODEL_THINKING": "gemma4:31b-mlx",
    "AISHA_AUTORUN": "0",
    "AISHA_STDIN_CONTEXT": "1",
    "AISHA_AGENT_MAX_STEPS": "15",
    "AISHA_AGENT_TOOLS": "command,read_file,write_file,search,web_fetch,list_dir",
    "AISHA_RISKY_EXTRA": "",   # extra risky-pattern regex (ERE), user supplied
    "AISHA_RISKY_ALLOW": "",   # allowlist regex — matching commands are never flagged
}


def load_config():
    cfg = dict(DEFAULTS)
    cfg.update({k: v for k, v in os.environ.items() if k.startswith("AISHA_")})
    path = cfg.get("AISHA_CONFIG_FILE") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
        "aisha", "config")
    cfg["AISHA_CONFIG_FILE"] = path
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
                if not m:
                    continue
                key, val = m.group(1), m.group(2).strip()
                try:
                    parts = shlex.split(val)
                    val = " ".join(parts) if parts else ""
                except ValueError:
                    pass
                cfg[key] = val
    except OSError:
        pass
    return cfg


CFG = load_config()


def cfg(name):
    return CFG.get(name, DEFAULTS.get(name, ""))


# ---- Colors (overridable via AISHA_COLOR_*; values may use \033 escapes) ----

def _color(name, default):
    v = CFG.get(name)
    if v is None:
        return default
    try:
        return v.encode("utf-8").decode("unicode_escape")
    except (UnicodeDecodeError, ValueError):
        return v


RED = _color("AISHA_COLOR_RED", "\033[1;31m")
GREEN = _color("AISHA_COLOR_GREEN", "\033[1;32m")
YELLOW = _color("AISHA_COLOR_YELLOW", "\033[1;33m")
CYAN = _color("AISHA_COLOR_CYAN", "\033[1;36m")
DIM = _color("AISHA_COLOR_DIM", "\033[2m")
BOLD = _color("AISHA_COLOR_BOLD", "\033[1m")
WHITE = _color("AISHA_COLOR_WHITE", "\033[1;37m")
RESET = _color("AISHA_COLOR_RESET", "\033[0m")

OS_INFO = None


def os_info():
    global OS_INFO
    if OS_INFO is None:
        u = os.uname()
        OS_INFO = f"{u.sysname}/{u.machine}"
        if u.sysname == "Darwin":
            try:
                v = subprocess.run(["sw_vers", "-productVersion"],
                                   capture_output=True, text=True).stdout.strip()
                OS_INFO += f" macOS {v}"
            except OSError:
                pass
        elif os.path.isfile("/etc/os-release"):
            info = {}
            with open("/etc/os-release") as f:
                for line in f:
                    if "=" in line:
                        k, _, val = line.partition("=")
                        info[k.strip()] = val.strip().strip('"')
            OS_INFO += f" {info.get('NAME', '')} {info.get('VERSION_ID', '')}".rstrip()
    return OS_INFO


# ============================================================================
# State paths
# ============================================================================

STATE_ROOT = os.environ.get(
    "AISHA_STATE_ROOT",
    os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "aisha"))
SESSION = os.environ.get("AISHA_SESSION_DIR",
                         os.path.join(STATE_ROOT, f"session-{os.getppid()}"))
CTX = os.path.join(SESSION, "last_context")

INTERACTIVE = os.environ.get("AISHA_INTERACTIVE", "0") == "1"
LAST_EXIT = int(os.environ.get("AISHA_LAST_EXIT", "0") or 0)
SHELL = os.environ.get("AISHA_SHELL", "bash")

STDIN_CONSUMED = False


def ensure_dirs():
    os.makedirs(CTX, exist_ok=True)
    try:
        link = os.path.join(STATE_ROOT, "latest")
        tmp = link + ".tmp"
        if os.path.islink(tmp) or os.path.exists(tmp):
            os.remove(tmp)
        os.symlink(SESSION, tmp)
        os.replace(tmp, link)
    except OSError:
        pass


def spath(*parts):
    return os.path.join(SESSION, *parts)


def read_file(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


# ============================================================================
# Risk engine
# ============================================================================
# \b-anchored patterns match after any separator (;, |, &&, $( ...), unlike
# the old whitespace-anchored shell regex. Heuristics, not a sandbox: the user
# reviewing the command in the buffer is the real safety layer.

RISKY_PATTERNS = [
    r'\bsudo\b',
    r'\brm\b',
    r'\bdd\b',
    r'\bmkfs\b',
    r'\bshred\b',
    r'\btruncate\b',
    r'\bfind\b.*(-delete\b|-exec\s+(rm|shred)\b)',
    r'\bmv\b.*\bdeleted\b',
    r'\bkubectl\s+delete\b',
    r'\bterraform\s+(apply|destroy)\b',
    r'\bgcloud\b.*\bdelete\b',
    r'\bgit\s+push\b.*(--force\b|-f\b)',
    r'\bchmod\s+(-[a-zA-Z]*R[a-zA-Z]*\s+)?777\b',
    r'\b(curl|wget)\b[^|]*\|\s*(ba|z|da)?sh\b',
    r'>\s*/dev/(sd|nvme|disk)',
]

INTERACTIVE_CMD_RE = re.compile(
    r'^(top|htop|btop|nmon|vim|vi|nvim|nano|less|more|man|watch|tmux|screen)( |$)')


def is_risky(cmd):
    allow = cfg("AISHA_RISKY_ALLOW")
    if allow:
        try:
            if re.search(allow, cmd):
                return False
        except re.error:
            pass
    patterns = list(RISKY_PATTERNS)
    extra = cfg("AISHA_RISKY_EXTRA")
    if extra:
        patterns.append(extra)
    for pat in patterns:
        try:
            if re.search(pat, cmd):
                return True
        except re.error:
            continue
    return False


# ============================================================================
# Response post-processing & markdown rendering
# ============================================================================

def strip_response(raw):
    """Strip <think> blocks; prefer the first fenced code block (multi-line
    commands supported); otherwise the first meaningful line, trimmed."""
    raw = re.sub(r'<think>.*?</think>', '', raw, flags=re.S)
    raw = re.sub(r'<think>.*', '', raw, flags=re.S)  # unterminated block
    m = re.search(r'```[a-zA-Z0-9_-]*\n?(.*?)```', raw, flags=re.S)
    if m:
        block = m.group(1).strip()
        if block:
            return block
    for line in raw.splitlines():
        line = line.strip()
        if line and not line.startswith("```"):
            return line
    return ""


_INLINE_CODE = re.compile(r'`([^`]*)`')
_BOLD = re.compile(r'\*\*([^*]*)\*\*')


class MarkdownRenderer:
    """Streaming ANSI renderer; feed() one line at a time."""

    def __init__(self, write=None):
        self.write = write or sys.stdout.write
        self.in_code = False
        self.in_think = False

    def _inline(self, text):
        text = _BOLD.sub(BOLD + WHITE + r'\1' + RESET, text)
        return _INLINE_CODE.sub(YELLOW + r'\1' + RESET, text)

    def feed(self, line):
        if "<think>" in line:
            self.in_think = True
        if self.in_think:
            if "</think>" in line:
                self.in_think = False
            return
        # Internal protocol marker (auto-fix corrected command) — not for display
        if line.startswith("FIX:"):
            return
        if line.startswith("```"):
            if self.in_code:
                self.in_code = False
            else:
                self.in_code = True
                lang = line[3:].strip()
                if lang:
                    self.write(f"{DIM}  ── {lang} ──{RESET}\n")
            return
        if self.in_code:
            self.write(f"{YELLOW}  {line}{RESET}\n")
            return
        m = re.match(r'^#{1,4}\s+(.*)$', line)
        if m:
            self.write(f"\n{CYAN}{BOLD}  {m.group(1)}{RESET}\n")
            return
        if re.match(r'^-{3,}$', line):
            self.write(f"{DIM}  ──────────────────────────────────────{RESET}\n")
            return
        m = re.match(r'^\s*[-*]\s+(.*)$', line)
        if m:
            self.write(f"{GREEN}  • {RESET}{self._inline(m.group(1))}\n")
            return
        m = re.match(r'^\s*(\d+)\.\s+(.*)$', line)
        if m:
            self.write(f"{CYAN}  {m.group(1)}.{RESET} {self._inline(m.group(2))}\n")
            return
        if not line:
            self.write("\n")
            return
        self.write(f"  {self._inline(line)}\n")


def render_markdown(text):
    r = MarkdownRenderer()
    for line in text.splitlines():
        r.feed(line)


# ============================================================================
# LLM invocation
# ============================================================================
# All model access goes through the `llm` CLI — one seam, plugin-extensible.
# (Apple's on-device `fm` CLI was considered as a second backend and
# rejected: 4K shared context and Apple's own no-code-generation guidance
# make it unfit for command suggestions; see IMPLEMENTATION_PLAN.md.)


def llm_args(model, files, prompt):
    args = ["llm", "-m", model]
    for f in files:
        if f and os.path.isfile(f):
            args += ["-f", f]
    args.append(prompt)
    return args


def llm_capture(model, files, prompt):
    try:
        r = subprocess.run(llm_args(model, files, prompt),
                           stdout=subprocess.PIPE, text=True)
        return r.stdout
    except FileNotFoundError:
        err("llm CLI not found — install it with: pip install llm")
        return ""


def llm_stream_render(model, files, prompt):
    """Stream llm output through the renderer; returns the full raw text."""
    env = dict(os.environ, PYTHONUNBUFFERED="1")
    try:
        p = subprocess.Popen(llm_args(model, files, prompt),
                             stdout=subprocess.PIPE, text=True, env=env)
    except FileNotFoundError:
        err("llm CLI not found — install it with: pip install llm")
        return ""
    rend = MarkdownRenderer()
    captured = []
    assert p.stdout is not None
    for line in p.stdout:
        captured.append(line)
        rend.feed(line.rstrip("\n"))
        sys.stdout.flush()
    p.wait()
    return "".join(captured)


def thinking_start():
    if sys.stdout.isatty():
        sys.stdout.write(f"{DIM}  ⏳ Thinking...{RESET}\r")
        sys.stdout.flush()


def thinking_end():
    if sys.stdout.isatty():
        sys.stdout.write("\033[2K\r")
        sys.stdout.flush()


# ============================================================================
# I/O helpers
# ============================================================================

def out(s=""):
    print(s)


def err(s):
    print(f"{RED}{s}{RESET}")


def read_reply():
    """Read a confirmation reply. When piped stdin was consumed as context,
    read from the terminal instead. Returns (reply, ok) — ok False means no
    reply could be read at all (EOF / no tty): callers take the safe path."""
    if STDIN_CONSUMED:
        try:
            # AISHA_TTY lets tests keep prompts off the real terminal.
            with open(os.environ.get("AISHA_TTY", "/dev/tty"), encoding="utf-8") as t:
                line = t.readline()
        except OSError:
            return "", False
        if line == "":
            return "", False
        return line.rstrip("\n"), True
    line = sys.stdin.readline()
    if line == "":
        return "", False
    return line.rstrip("\n"), True


# ============================================================================
# Context capture
# ============================================================================

def capture_context(exit_code):
    ensure_dirs()
    write_text(os.path.join(CTX, "pwd.txt"), os.getcwd() + "\n")
    try:
        git = subprocess.run(["git", "status", "--short"],
                             capture_output=True, text=True).stdout
    except OSError:
        git = ""
    write_text(os.path.join(CTX, "git.txt"), git)
    write_text(os.path.join(CTX, "exit.txt"), f"Last exit code: {exit_code}\n")


def ctx_files(*names):
    return [os.path.join(CTX, n) for n in names]


def system_prompt(persona):
    if persona == "deep":
        return (f"You are a senior systems engineer. The user's OS is: {os_info()}\n"
                "Think step-by-step, consider edge cases, tradeoffs, and failure modes.\n"
                "Prefer correctness over speed.")
    return (f"You are an expert Unix/Linux sysadmin. The user's OS is: {os_info()}\n"
            "Be concise, practical, and production-safe.")


def model_for(persona):
    return cfg("AISHA_MODEL_THINKING") if persona == "deep" else cfg("AISHA_MODEL_TASK")


# ============================================================================
# Command execution (confirm-and-run)
# ============================================================================

RUN_STATUS = {"last": "aborted"}


def run_command(cmd, capture=True):
    """Execute cmd via bash. Captured output is teed to last_output.txt.
    Interactive/curses commands run attached to the tty, uncaptured."""
    env = dict(os.environ)
    if re.match(r'^(ls|grep|diff|tree)\b', cmd):
        env["CLICOLOR_FORCE"] = "1"

    if INTERACTIVE_CMD_RE.search(cmd) or not capture:
        rc = subprocess.call(["bash", "-c", cmd], env=env)
        return rc

    p = subprocess.Popen(["bash", "-c", cmd], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, env=env)
    lines = []
    assert p.stdout is not None
    for line in p.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        lines.append(line)
    rc = p.wait()
    write_text(spath("last_output.txt"), "".join(lines))
    return rc


def confirm_and_run(cmd):
    """Confirm with the user, then execute. Risky commands require 'YES'.
    Sets RUN_STATUS['last'] to 'ran' or 'aborted'."""
    RUN_STATUS["last"] = "aborted"

    if is_risky(cmd):
        err("⚠️  Risky command detected.")
        sys.stdout.write("Type YES to execute (Ctrl+C to abort): ")
        sys.stdout.flush()
        reply, _ok = read_reply()
        if reply != "YES":
            print(f"{YELLOW}Aborted.{RESET}")
            return 0
    else:
        sys.stdout.write(f"{GREEN}Execute this command? [Y/n]:{RESET} ")
        sys.stdout.flush()
        reply, ok = read_reply()
        confirm = (reply or "Y") if ok else "n"
        if confirm.lower() != "y":
            print(f"{YELLOW}Aborted.{RESET}")
            return 0

    RUN_STATUS["last"] = "ran"
    return run_command(cmd)


# ============================================================================
# Suggestion delivery
# ============================================================================

def deliver_suggestion(response, no_exec=False):
    """-n → bare print; AUTORUN=1 → confirm-and-run; piped stdout or
    non-interactive shell → bare print; else hand to the shim for buffer
    injection via inject.txt."""
    ensure_dirs()
    write_text(spath("last_command.txt"), response + "\n")

    if no_exec:
        out(response)
        return 0

    if cfg("AISHA_AUTORUN") == "1":
        out("")
        out(f"{CYAN}Suggested command:{RESET}")
        for line in response.splitlines():
            out(f"  {YELLOW}{line}{RESET}")
        out("")
        return confirm_and_run(response)

    if not sys.stdout.isatty() or not INTERACTIVE:
        out(response)
        return 0

    out("")
    out(f"{CYAN}Suggested command:{RESET}")
    for line in response.splitlines():
        out(f"  {YELLOW}{line}{RESET}")
    if is_risky(response):
        out(f"  {RED}⚠️  Review carefully — this command can be destructive.{RESET}")

    write_text(spath("inject.txt"), response)
    return 0


# ============================================================================
# Auto-fix & rerun
# ============================================================================

def autofix(exit_code):
    """Stream a diagnosis of the failed command, then extract the model's
    corrected command (final 'FIX: <cmd>' line) and deliver it."""
    files = ctx_files("history.txt", "pwd.txt", "git.txt", "exit.txt")
    out_file = spath("last_output.txt")
    if os.path.isfile(out_file) and os.path.getsize(out_file) > 0:
        files.append(out_file)

    prompt = f"""{system_prompt('deep')}

The user's last command failed (exit code {exit_code}).
history.txt holds the recent commands. If last_output.txt is attached, it is
the captured output of the most recent command run through aisha — use it if
it matches the failure.
Explain briefly why the command failed and how to fix it.
Then, if there is a clear corrected command, END your reply with exactly one
final line in this form (no code fences, nothing after it):
FIX: <the corrected command>
If there is no single corrected command, omit the FIX line entirely."""

    raw = llm_stream_render(cfg("AISHA_MODEL_THINKING"), files, prompt)

    fix = ""
    for line in raw.splitlines():
        if line.startswith("FIX:"):
            fix = line[4:].strip().strip("`")
    if fix:
        deliver_suggestion(fix, no_exec=False)
    return 0


AI_INVOCATION_RE = re.compile(r'(^\s*|[|;&]\s*)ai(\s|$)')


def cmd_rerun():
    """Re-run the most recent history command (that doesn't invoke ai),
    capture its output, and diagnose on failure."""
    history = read_file(os.path.join(CTX, "history.txt"))
    candidates = []
    for line in history.splitlines():
        entry = re.sub(r'^\s*\d+\*?\s+', '', line.rstrip())
        if entry.strip() and not AI_INVOCATION_RE.search(entry):
            candidates.append(entry.strip())
    if not candidates:
        err("No previous command found in history.")
        return 1
    prev = candidates[-1]

    out(f"{CYAN}Re-running to capture output:{RESET}")
    out(f"  {YELLOW}{prev}{RESET}")
    out("")
    rc = confirm_and_run(prev)
    if RUN_STATUS["last"] != "ran":
        return 0
    if rc != 0:
        out("")
        capture_context(rc)
        autofix(rc)
    else:
        out(f"{GREEN}✓ Command succeeded — nothing to fix.{RESET}")
    return 0


# ============================================================================
# redo / explain / refine
# ============================================================================

def cmd_redo():
    path = spath("last_command.txt")
    if not os.path.isfile(path):
        err("No previous AI suggestion to redo.")
        return 1
    cmd = read_file(path).strip()
    out(f"{CYAN}Redoing last suggested command:{RESET}")
    out(f"  {YELLOW}{cmd}{RESET}")
    out("")
    return confirm_and_run(cmd)


def cmd_explain():
    path = spath("last_command.txt")
    if not os.path.isfile(path):
        err("No previous AI suggestion to explain.")
        return 1
    files = ctx_files("history.txt", "pwd.txt", "git.txt", "exit.txt")
    files += [path, spath("last_prompt.txt")]
    llm_stream_render(cfg("AISHA_MODEL_THINKING"), files, f"""You are an expert sysadmin. The user's OS is: {os_info()}
Explain why the command in last_command.txt was suggested, what it does, and any risks.
The original user intent is in last_prompt.txt.""")
    return 0


def cmd_refine(feedback, extra_files, no_exec):
    if not feedback:
        err("Usage: ai -c <feedback on the last suggestion>")
        return 1
    cmd_file = spath("last_command.txt")
    prompt_file = spath("last_prompt.txt")
    if not (os.path.isfile(cmd_file) and os.path.isfile(prompt_file)):
        err("No previous suggestion to refine.")
        return 1
    capture_context(LAST_EXIT)
    thinking_start()
    raw = llm_capture(cfg("AISHA_MODEL_TASK"),
                      [prompt_file, cmd_file] + extra_files, f"""{system_prompt('sysadmin')}

last_prompt.txt is the user's original request; last_command.txt is the command you previously suggested.
The user wants it revised: {feedback}

Output ONLY the revised shell command — no explanation, no code fences.""")
    thinking_end()
    revised = strip_response(raw)
    if not revised:
        print(f"{YELLOW}No response available.{RESET}")
        return 1
    # Append the feedback so further refinements see the whole conversation
    prev_prompt = read_file(prompt_file)
    write_text(prompt_file, f"{prev_prompt.rstrip()}\nRefinement: {feedback}\n")
    return deliver_suggestion(revised, no_exec)


# ============================================================================
# Help & tips
# ============================================================================

def cmd_help():
    render_markdown(f"""# aisha {VERSION} — AI shell assistant

**Usage:** ai [flags] <request in natural language>

### Subcommands
- `ai redo` — re-run the last suggested command
- `ai rerun` — re-run your last command, capture its output, diagnose failures
- `ai explain` — explain the last suggested command (thinking model)
- `ai /help` — this help
- `ai /tips [topic]` — power-user one-liners (curated, or generated for a topic)

### Flags
- `--deep` — use the thinking model for thorough analysis
- `-n, --no-exec` — print the suggested command only (for scripts and pipes)
- `--json` — machine-readable output: {{"type","command","risky","model"}}
- `-c, --refine <feedback>` — revise the last suggestion ("use ripgrep instead")
- `--agent <goal>` — autonomous multi-step mode (`--agent --resume` to continue)
- `--agent-safe <goal>` — agent mode, confirm every step
- `--version` — print version
- `--install` / `--uninstall` — install, upgrade, or remove aisha

### Piping
- `docker logs app 2>&1 | ai why is this crashing` — piped input becomes context
- `ai -n list open ports | pbcopy` — pipe the bare command anywhere

### How suggestions run
By default the suggested command is placed in your input line (zsh) or
history (bash: press ↑) so you can edit it before running. Set
`AISHA_AUTORUN=1` for the legacy confirm-and-run prompt. Risky commands
(rm, sudo, dd, ...) always get a red warning.

### Configuration
Config file: `{cfg('AISHA_CONFIG_FILE')}` (KEY=value lines).
Key knobs: `AISHA_MODEL_TASK`, `AISHA_MODEL_THINKING`, `AISHA_AGENT_MAX_STEPS`,
`AISHA_AUTORUN`, `AISHA_STDIN_CONTEXT`, `AISHA_RISKY_EXTRA`, `AISHA_RISKY_ALLOW`.

Bare `ai` right after a failed command diagnoses the failure.""")
    return 0


CURATED_TIPS = """# aisha tips & tricks

### Getting more out of aisha
- `ai` — bare, right after a command fails: diagnoses it and puts a fix in your prompt
- `ai rerun` — re-run your last command with output capture, then diagnose
- `docker logs app 2>&1 | ai why is this crashing` — piped input becomes context
- `ai -c use ripgrep instead` — refine the last suggestion
- `ai -n list open ports | pbcopy` — print-only, pipe the command anywhere
- `ai --deep ...` — thinking model for gnarly questions
- `ai explain` — what the last suggestion does and its risks
- `ai /tips awk` — five generated one-liners on any topic

### Shell one-liners worth stealing
- `cd -` — jump back to the previous directory
- `sudo !!` — re-run the last command with sudo
- `cp config.yml{,.bak}` — instant backup via brace expansion
- `ctrl-r` — incremental history search; type a fragment, repeat to cycle
- `sort | uniq -c | sort -rn` — frequency table of anything
- `find . -name '*.log' -exec rm {} +` — batch exec with one process
- `xargs -P4 -I{} cmd {}` — poor man's parallelism
- `python3 -m http.server` — share the current directory on :8000
- `lsof -i :3000` — who owns that port
- `du -sh * | sort -h` — what's eating disk, sorted"""


def cmd_tips(topic_args):
    if topic_args:
        topic = " ".join(topic_args)
        llm_stream_render(cfg("AISHA_MODEL_TASK"), [], f"""You are an expert Unix/Linux sysadmin. The user's OS is: {os_info()}
Give exactly 5 practical, non-obvious shell one-liners about: {topic}
Format each as a markdown bullet: the command in backticks, then a dash and a one-sentence explanation.
No preamble, no closing remarks.""")
        return 0
    render_markdown(CURATED_TIPS)
    return 0


# ============================================================================
# Agent mode
# ============================================================================

class Agent:
    def __init__(self, mode, goal):
        self.mode = mode                     # "auto" | "safe"
        self.goal = goal
        self.dir = spath("agent")
        self.cpdir = os.path.join(self.dir, "checkpoints")
        self.max_steps = int(cfg("AISHA_AGENT_MAX_STEPS") or 15)
        self.allowed_tools = {t.strip() for t in cfg("AISHA_AGENT_TOOLS").split(",") if t.strip()}
        self.cwd = os.getcwd()

    # ---- checkpoints ----
    def save_checkpoint(self, step, action, output, status):
        os.makedirs(self.cpdir, exist_ok=True)
        meta = {
            "step": step,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "pwd": self.cwd,
            "action": action,
            "status": status,
            "output_file": f"step_{step}_output.txt",
        }
        write_text(os.path.join(self.cpdir, f"step_{step}.json"),
                   json.dumps(meta, indent=2) + "\n")
        write_text(os.path.join(self.cpdir, f"step_{step}_output.txt"), output)
        with open(os.path.join(self.dir, "agent_log.txt"), "a", encoding="utf-8") as f:
            f.write(f"[{step}] ({status}) {action}\n")

    def checkpoints(self):
        try:
            files = sorted(
                (f for f in os.listdir(self.cpdir)
                 if re.match(r'^step_\d+\.json$', f)),
                key=lambda f: int(re.findall(r'\d+', f)[0]))
        except OSError:
            return []
        result = []
        for f in files:
            try:
                result.append(json.loads(read_file(os.path.join(self.cpdir, f))))
            except json.JSONDecodeError:
                continue
        return result

    def history_context(self, max_history=5, output_budget=1000):
        cps = self.checkpoints()
        parts = []
        if len(cps) > max_history:
            parts.append(f"(Steps 1-{len(cps) - max_history} omitted for brevity)")
        for cp in cps[-max_history:]:
            output = read_file(os.path.join(self.cpdir, cp.get("output_file", "")))
            if len(output) > output_budget:
                output = output[:output_budget] + f"\n... (truncated, {len(output)} bytes total)"
            parts.append(f"--- Step {cp['step']} ({cp['status']}) ---\n"
                         f"Action: {cp['action']}\nOutput: {output}\n")
        return "\n".join(parts)

    # ---- display ----
    def header(self):
        label = "safe 🔒" if self.mode == "safe" else "auto"
        out("")
        out(f"{CYAN}╔══════════════════════════════════════════════════════════╗{RESET}")
        out(f"{CYAN}║{RESET}  {WHITE}🤖 Agent Mode{RESET} {DIM}({label}){RESET}")
        out(f"{CYAN}║{RESET}  {BOLD}{self.goal}{RESET}")
        out(f"{CYAN}║{RESET}  {DIM}Max steps: {self.max_steps} │ Ctrl+C to abort{RESET}")
        out(f"{CYAN}╚══════════════════════════════════════════════════════════╝{RESET}")
        out("")

    def step_header(self, iteration, label, action):
        pct = iteration * 100 // self.max_steps
        filled = pct // 5
        bar = "█" * filled + "░" * (20 - filled)
        out(f"{DIM}──────────────────────────────────────────────────────────{RESET}")
        out(f"{CYAN}  {label}{RESET} {DIM}step {iteration}/{self.max_steps}{RESET}  "
            f"{DIM}[{bar}]{RESET} {DIM}{pct}%{RESET}")
        out(f"  {YELLOW}❯ {action}{RESET}")

    def show_output(self, output, exit_code):
        lines = output.splitlines()
        out(f"{DIM}  ┌─ output ──────────────────────────────────────────────{RESET}")
        if lines:
            for line in lines[:10]:
                out(f"  │ {line}")
            if len(lines) > 10:
                out(f"  │ {DIM}... ({len(lines) - 10} more lines){RESET}")
        else:
            out(f"  │ {DIM}(no output){RESET}")
        out(f"{DIM}  └──────────────────────────────────────────────────────{RESET}")
        if exit_code != 0:
            out(f"  {RED}✗ exit code {exit_code}{RESET}")
        else:
            out(f"  {GREEN}✓ ok{RESET}")
        out("")

    # ---- tools ----
    def run_step_command(self, cmd):
        """Run a shell command for one agent step, tracking cwd changes."""
        m = re.match(r'^\s*cd\s+(.+?)\s*$', cmd)
        if m:
            target = os.path.expanduser(m.group(1).strip("'\""))
            new = os.path.normpath(os.path.join(self.cwd, target))
            if os.path.isdir(new):
                self.cwd = new
                return f"OK: now in {new}", 0
            return f"ERROR: no such directory: {target}", 1
        try:
            r = subprocess.run(["bash", "-c", cmd], cwd=self.cwd,
                               capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            return "ERROR: command timed out after 120s", 1
        output = r.stdout
        if r.stderr:
            output += ("\n[stderr]\n" if output else "[stderr]\n") + r.stderr
        return output.rstrip("\n"), r.returncode

    def dispatch_tool(self, call):
        m = re.match(r'^TOOL:([a-z_]+)\((.*)\)\s*$', call, flags=re.S)
        if not m:
            return f"ERROR: Invalid tool call format: {call}", 1
        name, args = m.group(1), m.group(2)
        if name not in self.allowed_tools:
            return f"ERROR: Tool not allowed by AISHA_AGENT_TOOLS: {name}", 1

        if name == "read_file":
            path = os.path.join(self.cwd, args.strip())
            if not os.path.isfile(path):
                return f"ERROR: File not found: {args.strip()}", 1
            return read_file(path), 0
        if name == "write_file":
            fname, _, content = args.partition(",")
            path = os.path.join(self.cwd, fname.strip())
            write_text(path, content.lstrip())
            return f"OK: Wrote {len(content.lstrip())} bytes to {fname.strip()}", 0
        if name == "search":
            pattern, _, directory = args.partition(",")
            directory = directory.strip() or "."
            output, rc = self.run_step_command(
                f"grep -rn {shlex.quote(pattern.strip())} {shlex.quote(directory)} | head -30")
            return output, rc
        if name == "web_fetch":
            return self.web_fetch(args.strip())
        if name == "list_dir":
            return self.run_step_command(f"ls -la {shlex.quote(args.strip() or '.')}")
        if name == "command":
            return self.run_step_command(args)
        return f"ERROR: Unknown tool: {name}", 1

    @staticmethod
    def web_fetch(url, cap=65536):
        import urllib.request
        import urllib.error
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "aisha"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = resp.read(cap).decode("utf-8", errors="replace")
                return f"HTTP {resp.status}\n{body}", 0
        except (urllib.error.URLError, OSError, ValueError) as e:
            return f"ERROR: Failed to fetch {url}: {e}", 1

    # ---- prompts ----
    def step_prompt(self, step, total):
        return f"""You are an autonomous shell agent working toward a goal.
The user's OS is: {os_info()}

The goal is in the attached goal.txt.

STEP: {step} of {self.max_steps} (total: {total})

The attached history_context.txt contains your previous steps.

AVAILABLE TOOLS:
- COMMAND: <shell command>         — Execute a shell command
- TOOL:read_file(<path>)           — Read a file's contents
- TOOL:write_file(<path>, <content>) — Write content to a file
- TOOL:search(<pattern>, <dir>)    — Search for text in files
- TOOL:web_fetch(<url>)            — Fetch a URL's content
- TOOL:list_dir(<path>)            — List directory contents

RESPONSE FORMAT — reply with EXACTLY ONE of:
1. COMMAND: <shell command to execute>
2. TOOL:<tool_name>(<args>)
3. DONE: <summary of what was accomplished>
4. FAILED: <explanation of why the goal cannot be achieved>

Rules:
- One action per step, observe output before deciding next
- Never use rm -rf
- Prefer safe, reversible operations
- If stuck after 3 retries, mark as FAILED"""

    # ---- step gating ----
    def confirm_step(self, prompt_text):
        """Returns 'yes', 'skip', or 'abort'."""
        sys.stdout.write(prompt_text)
        sys.stdout.flush()
        reply, ok = read_reply()
        if not ok:
            return "abort"
        reply = reply.strip().lower() or "y"
        if reply.startswith("s"):
            return "skip"
        if reply == "y" or reply == "yes":
            return "yes"
        return "abort"

    # ---- main loop ----
    def run(self, resume=False):
        if resume:
            if not os.path.isfile(os.path.join(self.dir, "goal.txt")):
                err("No agent session to resume.")
                return 1
            self.goal = read_file(os.path.join(self.dir, "goal.txt")).strip()
            self.mode = read_file(os.path.join(self.dir, "mode.txt")).strip() or "auto"
            out(f"{CYAN}🔄 Resuming agent session...{RESET}")
            cps = self.checkpoints()
            start = cps[-1]["step"] if cps else 0
            if cps and os.path.isdir(cps[-1].get("pwd", "")):
                self.cwd = cps[-1]["pwd"]
            out(f"  {DIM}Picking up from step {start} (cwd: {self.cwd}){RESET}")
        else:
            import shutil
            shutil.rmtree(self.dir, ignore_errors=True)
            os.makedirs(self.cpdir, exist_ok=True)
            write_text(os.path.join(self.dir, "goal.txt"), self.goal + "\n")
            write_text(os.path.join(self.dir, "mode.txt"), self.mode + "\n")
            start = 0

        self.header()
        capture_context(0)

        iteration, total = start, 0
        while True:  # continuation loop
            while iteration < self.max_steps:  # step loop
                iteration += 1
                total += 1

                write_text(os.path.join(self.dir, "history_context.txt"),
                           self.history_context())
                thinking_start()
                raw = llm_capture(cfg("AISHA_MODEL_TASK"), [
                    os.path.join(CTX, "pwd.txt"),
                    os.path.join(CTX, "git.txt"),
                    os.path.join(self.dir, "goal.txt"),
                    os.path.join(self.dir, "history_context.txt"),
                ], self.step_prompt(iteration, total))
                thinking_end()
                resp = strip_response(raw)

                if resp.startswith("DONE:"):
                    summary = resp[5:].strip()
                    self.save_checkpoint(iteration, "DONE", summary, "done")
                    out(f"{DIM}──────────────────────────────────────────────────────────{RESET}")
                    out("")
                    out(f"  {GREEN}✅ Done!{RESET} {DIM}Completed in {total} step(s){RESET}")
                    out(f"  {WHITE}{summary}{RESET}")
                    out("")
                    out(f"  {DIM}📋 Log: {self.dir}/agent_log.txt{RESET}")
                    out("")
                    return 0

                if resp.startswith("FAILED:"):
                    reason = resp[7:].strip()
                    self.save_checkpoint(iteration, "FAILED", reason, "failed")
                    out(f"{DIM}──────────────────────────────────────────────────────────{RESET}")
                    out("")
                    out(f"  {RED}❌ Failed at step {iteration}{RESET}")
                    out(f"  {YELLOW}{reason}{RESET}")
                    out("")
                    out(f"  {DIM}💡 Resume with:{RESET} {CYAN}ai --agent --resume{RESET}")
                    out("")
                    return 1

                if resp.startswith("TOOL:"):
                    self.step_header(iteration, "🔧 Tool", resp)
                    if self.mode == "safe":
                        choice = self.confirm_step(f"  {GREEN}Allow? [Y/n/skip]:{RESET} ")
                        if choice == "skip":
                            self.save_checkpoint(iteration, resp, "SKIPPED by user", "skipped")
                            out(f"  {YELLOW}⏭  Skipped{RESET}")
                            out("")
                            continue
                        if choice == "abort":
                            self.save_checkpoint(iteration, resp, "ABORTED by user", "aborted")
                            out("")
                            out(f"  {YELLOW}Agent paused.{RESET} {DIM}Resume with:{RESET} "
                                f"{CYAN}ai --agent --resume{RESET}")
                            out("")
                            return 1
                    output, rc = self.dispatch_tool(resp)
                    self.show_output(output, rc)
                    self.save_checkpoint(iteration, resp, output,
                                         "ok" if rc == 0 else "error")
                    continue

                # COMMAND (or bare command)
                cmd = resp[8:].strip() if resp.startswith("COMMAND:") else resp.strip()
                self.step_header(iteration, "⚡ Run", cmd)

                if is_risky(cmd):
                    out(f"  {RED}⚠️  Risky command — requires explicit approval{RESET}")
                    sys.stdout.write(f"  {RED}Type YES to execute, or 'skip' to skip:{RESET} ")
                    sys.stdout.flush()
                    reply, _ok = read_reply()
                    if reply == "skip":
                        self.save_checkpoint(iteration, cmd, "SKIPPED by user (risky)", "skipped")
                        out(f"  {YELLOW}⏭  Skipped{RESET}")
                        out("")
                        continue
                    if reply != "YES":
                        self.save_checkpoint(iteration, cmd, "ABORTED by user (risky)", "aborted")
                        out("")
                        out(f"  {YELLOW}Agent paused.{RESET} {DIM}Resume with:{RESET} "
                            f"{CYAN}ai --agent --resume{RESET}")
                        out("")
                        return 1
                elif self.mode == "safe":
                    choice = self.confirm_step(f"  {GREEN}Execute? [Y/n/skip]:{RESET} ")
                    if choice == "skip":
                        self.save_checkpoint(iteration, cmd, "SKIPPED by user", "skipped")
                        out(f"  {YELLOW}⏭  Skipped{RESET}")
                        out("")
                        continue
                    if choice == "abort":
                        self.save_checkpoint(iteration, cmd, "ABORTED by user", "aborted")
                        out("")
                        out(f"  {YELLOW}Agent paused.{RESET} {DIM}Resume with:{RESET} "
                            f"{CYAN}ai --agent --resume{RESET}")
                        out("")
                        return 1

                output, rc = self.run_step_command(cmd)
                self.show_output(output, rc)
                self.save_checkpoint(iteration, cmd, output, "ok" if rc == 0 else "error")

            # max steps reached — offer continuation
            out(f"{DIM}──────────────────────────────────────────────────────────{RESET}")
            out("")
            out(f"  {YELLOW}⚠️  Reached max steps ({self.max_steps}) without completing goal.{RESET}")
            choice = self.confirm_step(
                f"  {GREEN}Continue for another {self.max_steps} steps? [Y/n]:{RESET} ")
            if choice == "yes":
                iteration = 0
                out("")
                out(f"  {CYAN}↻ Continuing...{RESET} {DIM}(total steps so far: {total}){RESET}")
                out("")
            else:
                out("")
                out(f"  {DIM}Stopped after {total} total step(s).{RESET}")
                out(f"  {DIM}💡 Resume with:{RESET} {CYAN}ai --agent --resume{RESET}")
                out("")
                return 1


def cmd_agent(mode, args):
    ensure_dirs()
    if args and args[0] == "--resume":
        return Agent(mode, "").run(resume=True)
    goal = " ".join(args)
    if not goal:
        err("Usage: ai --agent <goal>")
        return 1
    return Agent(mode, goal).run(resume=False)


# ============================================================================
# Installer / uninstaller
# ============================================================================

RC_MARKER = "# Load AI shell helpers"
RC_BLOCK = f"""
{RC_MARKER}
if [[ -f "$HOME/.aisha" ]]; then
  source "$HOME/.aisha"
fi
"""

OLLAMA_RELEASES = "https://github.com/ollama/ollama/releases"


def _ask(question, default_yes=True):
    """Interactive yes/no; never answers yes without a human on a tty."""
    if not sys.stdin.isatty():
        return False
    suffix = "[Y/n]" if default_yes else "[y/N]"
    sys.stdout.write(f"{GREEN}{question} {suffix}:{RESET} ")
    sys.stdout.flush()
    try:
        reply = input().strip().lower()
    except EOFError:
        return False
    if not reply:
        return default_yes
    return reply in ("y", "yes")


def _run_visible(args, shell=False):
    out(f"{DIM}  $ {args if shell else ' '.join(args)}{RESET}")
    try:
        return subprocess.run(args, shell=shell).returncode == 0
    except OSError as e:
        err(f"  failed: {e}")
        return False


def _which(name):
    import shutil
    return shutil.which(name)


def _installed_version(path):
    m = re.search(r'^VERSION = "([^"]+)"', read_file(path), flags=re.M)
    return m.group(1) if m else None


def _rc_file():
    shell = os.path.basename(os.environ.get("SHELL", ""))
    if shell == "bash":
        return os.path.expanduser("~/.bashrc")
    if shell == "zsh":
        return os.path.expanduser("~/.zshrc")
    return None


def _install_ollama_darwin():
    """Download the latest release tarball and install to ~/.local/bin."""
    import tarfile
    import tempfile
    import urllib.request
    url = f"{OLLAMA_RELEASES}/latest/download/ollama-darwin.tgz"
    out(f"  Downloading {url} ...")
    try:
        with tempfile.TemporaryDirectory() as tmp:
            tgz = os.path.join(tmp, "ollama.tgz")
            urllib.request.urlretrieve(url, tgz)
            with tarfile.open(tgz) as tar:
                tar.extract("ollama", path=tmp)
            dest_dir = os.path.expanduser("~/.local/bin")
            os.makedirs(dest_dir, exist_ok=True)
            dest = os.path.join(dest_dir, "ollama")
            os.replace(os.path.join(tmp, "ollama"), dest)
            os.chmod(dest, 0o755)
    except (OSError, KeyError, tarfile.TarError) as e:
        err(f"  Download failed: {e}")
        out(f"  Install manually from {OLLAMA_RELEASES} or https://ollama.com/download")
        return False
    out(f"{GREEN}✓ Installed ollama to {dest}{RESET}")
    if dest_dir not in os.environ.get("PATH", "").split(":"):
        print(f"{YELLOW}⚠ {dest_dir} is not in your PATH — add it to your shell rc file.{RESET}")
    out(f"  {DIM}Note: run 'ollama serve' to start the server (the Mac app does this automatically).{RESET}")
    return True


def check_dependencies():
    """Check for llm and ollama; offer to install what's missing."""
    out("")
    out(f"{CYAN}Checking dependencies...{RESET}")

    # ---- llm CLI ----
    if _which("llm"):
        out(f"{GREEN}✓ llm found{RESET} {DIM}({_which('llm')}){RESET}")
    else:
        print(f"{YELLOW}⚠ llm CLI not found{RESET}")
        if _ask("Install llm now?"):
            if _which("brew"):
                ok = _run_visible(["brew", "install", "llm"])
            else:
                ok = _run_visible([sys.executable, "-m", "pip", "install", "--user", "llm"])
            if not ok:
                err("  llm installation failed — install manually: pip install llm")
        else:
            out(f"  {DIM}Install later with: pip install llm  (or: brew install llm){RESET}")

    # ---- llm-ollama plugin ----
    if _which("llm"):
        try:
            plugins = subprocess.run(["llm", "plugins"], capture_output=True,
                                     text=True, timeout=30).stdout
        except (OSError, subprocess.TimeoutExpired):
            plugins = ""
        if "llm-ollama" in plugins:
            out(f"{GREEN}✓ llm-ollama plugin found{RESET}")
        else:
            print(f"{YELLOW}⚠ llm-ollama plugin not found{RESET}")
            if _ask("Install the llm-ollama plugin now?"):
                _run_visible(["llm", "install", "llm-ollama"])
            else:
                out(f"  {DIM}Install later with: llm install llm-ollama{RESET}")

    # ---- ollama ----
    if _which("ollama"):
        out(f"{GREEN}✓ ollama found{RESET} {DIM}({_which('ollama')}){RESET}")
    else:
        print(f"{YELLOW}⚠ ollama not found{RESET}")
        if sys.platform == "darwin":
            if _which("brew"):
                if _ask("Install ollama now (brew install ollama)?"):
                    _run_visible(["brew", "install", "ollama"])
                else:
                    out(f"  {DIM}Install later with: brew install ollama "
                        f"(or from {OLLAMA_RELEASES}){RESET}")
            elif _ask(f"Download ollama from {OLLAMA_RELEASES} to ~/.local/bin?"):
                _install_ollama_darwin()
            else:
                out(f"  {DIM}Install from {OLLAMA_RELEASES} or https://ollama.com/download{RESET}")
        else:
            if _ask("Install ollama now (official install script, needs curl)?"):
                _run_visible("curl -fsSL https://ollama.com/install.sh | sh", shell=True)
            else:
                out(f"  {DIM}Install later: curl -fsSL https://ollama.com/install.sh | sh "
                    f"(or from {OLLAMA_RELEASES}){RESET}")

    if _which("ollama"):
        out("")
        out(f"{DIM}Pull models for your hardware (see README for the full guide):{RESET}")
        out(f"{DIM}  48 GB Mac:  ollama pull qwen3.6:35b-mlx && ollama pull gemma4:31b-mlx{RESET}")
        out(f"{DIM}  16 GB Mac:  ollama pull gemma4:e4b-mlx && ollama pull qwen3.5:9b-mlx{RESET}")


def cmd_install(shim_path):
    rc_file = _rc_file()
    if rc_file is None:
        err(f"Error: Unsupported shell '{os.path.basename(os.environ.get('SHELL', ''))}'. "
            "Only bash and zsh are supported.")
        return 1
    if not shim_path or not os.path.isfile(shim_path):
        err("Error: cannot locate aisha.sh to install.")
        return 1
    core_src = os.path.abspath(__file__)

    dest_shim = os.path.expanduser("~/.aisha")
    dest_core = os.path.expanduser("~/.aisha-core.py")
    old = _installed_version(dest_core)

    import shutil
    shutil.copyfile(shim_path, dest_shim)
    shutil.copyfile(core_src, dest_core)
    if old is None:
        out(f"{GREEN}✓ Installed aisha {VERSION} (~/.aisha, ~/.aisha-core.py){RESET}")
    elif old == VERSION:
        out(f"{GREEN}✓ aisha {VERSION} already installed — files refreshed{RESET}")
    else:
        out(f"{GREEN}✓ Upgraded aisha {old} → {VERSION}{RESET}")

    rc_text = read_file(rc_file)
    if RC_MARKER in rc_text:
        print(f"{YELLOW}⚠ aisha is already configured in {rc_file}{RESET}")
    else:
        with open(rc_file, "a", encoding="utf-8") as f:
            f.write(RC_BLOCK)
        out(f"{GREEN}✓ Added aisha loader to {rc_file}{RESET}")

    check_dependencies()

    out("")
    out(f"{CYAN}Installation complete!{RESET}")
    out(f"Run: {YELLOW}source {rc_file}{RESET} (or open a new terminal window)")
    return 0


def _remove_rc_block(rc_file):
    lines = read_file(rc_file).splitlines()
    if not lines:
        return False
    try:
        i = lines.index(RC_MARKER)
    except ValueError:
        return False
    end = i + 1
    while end < len(lines) and lines[end].strip() != "fi":
        end += 1
    if end < len(lines):
        end += 1  # include the fi
    if i > 0 and not lines[i - 1].strip():
        i -= 1  # drop the blank line the installer added
    import shutil
    shutil.copyfile(rc_file, rc_file + ".aisha-bak")
    write_text(rc_file, "\n".join(lines[:i] + lines[end:]) + "\n")
    return True


def cmd_uninstall():
    removed = False
    for path in ("~/.aisha", "~/.aisha-core.py"):
        full = os.path.expanduser(path)
        if os.path.isfile(full):
            os.remove(full)
            out(f"{GREEN}✓ Removed {path}{RESET}")
            removed = True
    for rc in ("~/.bashrc", "~/.zshrc"):
        full = os.path.expanduser(rc)
        if os.path.isfile(full) and _remove_rc_block(full):
            out(f"{GREEN}✓ Removed aisha loader from {rc} (backup: {rc}.aisha-bak){RESET}")
            removed = True
    if os.path.isdir(STATE_ROOT) and _ask(f"Remove state directory {STATE_ROOT}?",
                                          default_yes=False):
        import shutil
        shutil.rmtree(STATE_ROOT, ignore_errors=True)
        out(f"{GREEN}✓ Removed {STATE_ROOT}{RESET}")
    if not removed:
        print(f"{YELLOW}Nothing to uninstall.{RESET}")
    else:
        out(f"{DIM}Config file left in place: {cfg('AISHA_CONFIG_FILE')}{RESET}")
        out(f"{DIM}Open a new terminal for the change to take effect.{RESET}")
    return 0


# ============================================================================
# Main dispatch
# ============================================================================

EXPLAIN_QUERY_RE = re.compile(r'^(how|why|what|explain|help)(\s|$)')


def main(argv):
    global STDIN_CONSUMED

    # ---- internal test hooks ----
    if argv[:1] == ["--_strip"]:
        out(strip_response(" ".join(argv[1:])))
        return 0
    if argv[:1] == ["--_risky"]:
        return 0 if is_risky(" ".join(argv[1:])) else 1
    if argv[:1] == ["--_render"]:
        r = MarkdownRenderer()
        for line in sys.stdin.read().splitlines():
            r.feed(line)
        return 0

    # ---- installer / uninstaller ----
    if argv[:1] == ["--install"]:
        if "--shim" in argv:
            shim = argv[argv.index("--shim") + 1]
        else:
            here = os.path.dirname(os.path.abspath(__file__))
            shim = None
            for cand in (os.path.join(here, "aisha.sh"), os.path.expanduser("~/.aisha")):
                if os.path.isfile(cand):
                    shim = cand
                    break
        return cmd_install(shim)
    if argv[:1] == ["--uninstall"]:
        return cmd_uninstall()

    ensure_dirs()

    # ---- flags (order-independent, may precede the prompt) ----
    persona = "sysadmin"
    no_exec = False
    refine = False
    json_mode = False
    while argv:
        a = argv[0]
        if a == "--deep":
            persona = "deep"
        elif a in ("-n", "--no-exec"):
            no_exec = True
        elif a == "--json":
            json_mode = True
        elif a in ("-c", "--refine"):
            refine = True
        elif a in ("-h", "--help", "/help"):
            return cmd_help()
        elif a == "/tips":
            return cmd_tips(argv[1:])
        elif a == "--version":
            out(f"aisha {VERSION}")
            return 0
        elif a in ("-agent", "--agent"):
            return cmd_agent("auto", argv[1:])
        elif a in ("-agent-safe", "--agent-safe"):
            return cmd_agent("safe", argv[1:])
        elif a == "--":
            argv = argv[1:]
            break
        else:
            break
        argv = argv[1:]

    # ---- subcommands (bare form only) ----
    if argv == ["redo"]:
        return cmd_redo()
    if argv == ["rerun"]:
        return cmd_rerun()
    if argv == ["explain"]:
        return cmd_explain()

    # ---- piped stdin becomes context (capped at 64 KB) ----
    stdin_ctx = ""
    if not sys.stdin.isatty() and cfg("AISHA_STDIN_CONTEXT") == "1":
        data = sys.stdin.buffer.read(65536).decode("utf-8", errors="replace")
        STDIN_CONSUMED = True
        if data.strip():
            stdin_ctx = os.path.join(CTX, "stdin.txt")
            write_text(stdin_ctx, data)
        else:
            try:
                os.remove(os.path.join(CTX, "stdin.txt"))
            except OSError:
                pass
    extra_files = [stdin_ctx] if stdin_ctx else []

    # ---- refinement ----
    if refine:
        return cmd_refine(" ".join(argv), extra_files, no_exec)

    # ---- build prompt ----
    prompt = " ".join(argv)
    if prompt:
        write_text(spath("last_prompt.txt"), prompt + "\n")

    if json_mode and not prompt:
        print(json.dumps({"type": "error", "error": "--json requires a prompt"}))
        return 1

    capture_context(LAST_EXIT)

    # ---- piped input with no prompt → diagnose the piped data ----
    if not prompt and stdin_ctx:
        llm_stream_render(cfg("AISHA_MODEL_THINKING"),
                          [stdin_ctx] + ctx_files("pwd.txt", "git.txt"),
                          f"""{system_prompt('deep')}

The user piped data into aisha (attached stdin.txt) without a question.
Summarize what it shows and diagnose any errors or anomalies.""")
        return 0

    # ---- auto-fix: empty prompt + previous command failed ----
    if LAST_EXIT != 0 and not prompt:
        return autofix(LAST_EXIT)

    # ---- interactive fallback ----
    if not prompt:
        sys.stdout.write(f"{CYAN}Ask: {RESET}")
        sys.stdout.flush()
        reply, _ok = read_reply()
        prompt = reply.strip()
        if not prompt:
            return 0
        write_text(spath("last_prompt.txt"), prompt + "\n")

    # Auto-select deep persona for explanation queries
    if EXPLAIN_QUERY_RE.match(prompt):
        persona = "deep"
    model = model_for(persona)

    # ---- explanation mode (how/why/what/explain/help) ----
    if EXPLAIN_QUERY_RE.match(prompt):
        explain_prompt = f"""{system_prompt(persona)}

Explain clearly and include one concrete command example to illustrate if applicable, but do NOT prompt the user to execute anything.
The user's question is in the attached last_prompt.txt. If stdin.txt is attached, it is data the user piped in — treat it as the subject of the question."""
        explain_files = (ctx_files("history.txt", "pwd.txt", "git.txt")
                         + [spath("last_prompt.txt")] + extra_files)
        if json_mode:
            raw = llm_capture(model, explain_files, explain_prompt)
            answer = re.sub(r'<think>.*?</think>', '', raw, flags=re.S).strip()
            print(json.dumps({"type": "answer", "answer": answer, "model": model}))
            return 0
        llm_stream_render(model, explain_files, explain_prompt)
        return 0

    # ---- command suggestion mode ----
    thinking_start()
    raw = llm_capture(model,
                      ctx_files("history.txt", "pwd.txt", "git.txt")
                      + [spath("last_prompt.txt")] + extra_files,
                      f"""{system_prompt(persona)}

The user's request is in the attached last_prompt.txt.

Rules:
- If the request is a shell/system task, output ONLY the command (no explanation). Most requests are tasks.
- ONLY if the request is clearly a greeting or chit-chat (like 'hello', 'what's up', 'how are you'), prefix your response with 'ANSWER:' followed by a brief, friendly reply
- When in doubt, treat it as a task and output a command
- If stdin.txt is attached, it is data the user piped in — treat it as the subject of the request
- Multi-line commands are allowed: wrap them in a single fenced code block
- Never use rm -rf
- Avoid destructive commands""")
    thinking_end()

    response = strip_response(raw)

    if json_mode:
        if not response:
            print(json.dumps({"type": "error", "error": "no response from model"}))
            return 1
        if response.startswith("ANSWER:"):
            print(json.dumps({"type": "answer", "answer": response[7:].strip(),
                              "model": model}))
            return 0
        write_text(spath("last_command.txt"), response + "\n")
        print(json.dumps({"type": "command", "command": response,
                          "risky": is_risky(response), "model": model}))
        return 0

    if not response:
        out("")
        print(f"{YELLOW}No response available.{RESET}")
        return 0

    if response.startswith("ANSWER:"):
        out("")
        print(f"{CYAN}{response[7:].strip()}{RESET}")
        return 0

    write_text(spath("last_persona.txt"), persona + "\n")
    return deliver_suggestion(response, no_exec)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print()
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(0)
