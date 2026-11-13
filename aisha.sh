#!/usr/bin/env bash
# shellcheck shell=bash

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║  aisha — AI-Powered Shell Assistant                                       ║
# ║  https://github.com/buratinodev/aisha                                     ║
# ╚════════════════════════════════════════════════════════════════════════════╝
#
# Table of contents:
#   1. Configuration          — config file, colors, models, state dirs, OS
#   2. Installer              — `./aisha.sh --install`
#   3. Shared helpers         — prompts, risk detection, context, streaming
#   4. Confirmation & exec    — confirm-and-run with risk gating
#   5. Agent tools            — read_file, write_file, search, etc.
#   6. Agent internals        — dispatcher, checkpoints, history, display
#   7. Agent command executor — step execution with safety checks
#   8. Agent loop             — _ai_agent() main loop
#   9. Help, tips & delivery  — /help, /tips, suggestion delivery modes
#  10. Main entry point       — _ai() dispatcher + ai() alias
#  11. Shell integration      — nonomatch, ZLE widget, completion


# ============================================================================
# 1. CONFIGURATION
# ============================================================================
# Every knob below can be overridden from the environment before sourcing,
# e.g.  export AISHA_MODEL_TASK="llama3.3:70b"
# or set in the config file (plain shell assignments), which takes precedence:
#   ${XDG_CONFIG_HOME:-~/.config}/aisha/config

AISHA_VERSION="0.2.0"

# ---- User config file (optional) ----
AISHA_CONFIG_FILE="${AISHA_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/aisha/config}"
# shellcheck disable=SC1090
[[ -r "$AISHA_CONFIG_FILE" ]] && source "$AISHA_CONFIG_FILE"

# ---- Colors ----
AISHA_COLOR_RED="${AISHA_COLOR_RED-\033[1;31m}"
AISHA_COLOR_GREEN="${AISHA_COLOR_GREEN-\033[1;32m}"
AISHA_COLOR_YELLOW="${AISHA_COLOR_YELLOW-\033[1;33m}"
AISHA_COLOR_CYAN="${AISHA_COLOR_CYAN-\033[1;36m}"
AISHA_COLOR_DIM="${AISHA_COLOR_DIM-\033[2m}"
AISHA_COLOR_BOLD="${AISHA_COLOR_BOLD-\033[1m}"
AISHA_COLOR_WHITE="${AISHA_COLOR_WHITE-\033[1;37m}"
AISHA_COLOR_RESET="${AISHA_COLOR_RESET-\033[0m}"

# ---- Models ----
AISHA_MODEL_TASK="${AISHA_MODEL_TASK:-qwen3-coder:30b}"   # Fast model for command suggestions & agent steps
AISHA_MODEL_THINKING="${AISHA_MODEL_THINKING:-qwen3:32b}" # Reasoning model for deep analysis & explanations

# ---- Behavior ----
AISHA_AUTORUN="${AISHA_AUTORUN:-0}"             # 1 = legacy confirm-and-eval instead of buffer injection
AISHA_STDIN_CONTEXT="${AISHA_STDIN_CONTEXT:-1}" # 0 = never read piped stdin as context

# ---- Agent ----
AISHA_AGENT_MAX_STEPS="${AISHA_AGENT_MAX_STEPS:-15}"
# shellcheck disable=SC2034  # reserved: tool gating is enforced in a later phase
AISHA_AGENT_TOOLS="${AISHA_AGENT_TOOLS:-command,read_file,write_file,search,web_fetch}"

# ---- State directories (XDG, per shell session) ----
# Each interactive shell gets its own state dir so concurrent terminals don't
# clobber each other's context, suggestions, or agent checkpoints.
AISHA_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/aisha"
AISHA_SESSION_DIR="$AISHA_STATE_ROOT/session-$$"

# ---- OS detection (e.g. "Darwin/arm64 macOS 15.3") ----
AISHA_OS="$(uname -s)/$(uname -m)"
# shellcheck disable=SC1091
[[ -f /etc/os-release ]] && AISHA_OS="$AISHA_OS $(. /etc/os-release && echo "$NAME $VERSION_ID")"
[[ "$(uname -s)" == "Darwin" ]] && AISHA_OS="$AISHA_OS macOS $(sw_vers -productVersion 2>/dev/null)"


# ============================================================================
# 2. INSTALLER  (run as: ./aisha.sh --install)
# ============================================================================

if [[ "$1" == "--install" ]]; then
  user_shell=$(basename "$SHELL")

  if [[ "$user_shell" == "bash" ]]; then
    rc_file="$HOME/.bashrc"
  elif [[ "$user_shell" == "zsh" ]]; then
    rc_file="$HOME/.zshrc"
  else
    echo -e "${AISHA_COLOR_RED}Error: Unsupported shell '$user_shell'. Only bash and zsh are supported.${AISHA_COLOR_RESET}"
    exit 1
  fi

  script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  cp "$script_path" "$HOME/.aisha"
  echo -e "${AISHA_COLOR_GREEN}✓ Copied aisha.sh to ~/.aisha${AISHA_COLOR_RESET}"

  if grep -q "Load AI shell helpers" "$rc_file" 2>/dev/null; then
    echo -e "${AISHA_COLOR_YELLOW}⚠ aisha is already configured in $rc_file${AISHA_COLOR_RESET}"
  else
    echo "" >> "$rc_file"
    echo "# Load AI shell helpers" >> "$rc_file"
    echo 'if [[ -f "$HOME/.aisha" ]]; then' >> "$rc_file"
    echo '  source "$HOME/.aisha"' >> "$rc_file"
    echo 'fi' >> "$rc_file"
    echo -e "${AISHA_COLOR_GREEN}✓ Added aisha loader to $rc_file${AISHA_COLOR_RESET}"
  fi

  echo ""
  echo -e "${AISHA_COLOR_CYAN}Installation complete!${AISHA_COLOR_RESET}"
  echo -e "Run: ${AISHA_COLOR_YELLOW}source $rc_file${AISHA_COLOR_RESET} to load aisha in your current shell"
  echo -e "Or open a new terminal window."
  exit 0
fi


# ============================================================================
# 3. SHARED HELPERS
# ============================================================================

# Regex used to detect risky commands (shared by _ai_confirm_and_run and agent)
_AISHA_RISKY_RE='(^|\s)(sudo|rm|dd|mkfs|shred|find.*(rm|shred)|mv.*deleted|kubectl delete|terraform (apply|destroy)|gcloud delete)(\s|$)'

# Regex for interactive/curses programs that break when piped through tee/subshell
_AISHA_INTERACTIVE_RE='^(top|htop|btop|nmon|vim|vi|nvim|nano|less|more|man|watch|tmux|screen)( |$)'

# Build a system prompt for the given persona.
_ai_system_prompt() {
  local persona="$1"
  if [[ "$persona" == "deep" ]]; then
    echo "You are a senior systems engineer. The user's OS is: $AISHA_OS
Think step-by-step, consider edge cases, tradeoffs, and failure modes.
Prefer correctness over speed."
  else
    echo "You are an expert Unix/Linux sysadmin. The user's OS is: $AISHA_OS
Be concise, practical, and production-safe."
  fi
}

# Select the LLM model for a persona.
_ai_model_for() {
  [[ "$1" == "deep" ]] && echo "$AISHA_MODEL_THINKING" || echo "$AISHA_MODEL_TASK"
}

# llm with Python output buffering disabled, so tokens stream through the
# markdown renderer as they are generated instead of arriving in one block.
_ai_llm_stream() {
  PYTHONUNBUFFERED=1 llm "$@"
}

# True when the current shell is interactive (a user is at the prompt).
_ai_shell_interactive() {
  if [[ -n "$ZSH_VERSION" ]]; then
    [[ -o interactive ]]
  else
    [[ $- == *i* ]]
  fi
}

# Put a command into the shell's editable input line so the user can review,
# edit, and run it — and it lands in shell history naturally.
# Returns 1 if no mechanism is available (caller falls back to confirm-and-run).
_ai_inject_buffer() {
  local cmd="$1"
  if [[ -n "$ZSH_VERSION" ]]; then
    print -rz -- "$cmd"
    return 0
  fi
  if [[ -n "$BASH_VERSION" ]]; then
    history -s "$cmd"
    return 0
  fi
  return 1
}

# Transient "Thinking..." indicator (only when stdout is a terminal).
_ai_thinking_start() {
  [[ -t 1 ]] && echo -ne "${AISHA_COLOR_DIM}  ⏳ Thinking...${AISHA_COLOR_RESET}\r"
  return 0
}
_ai_thinking_end() {
  [[ -t 1 ]] && echo -ne "\033[2K\r"
  return 0
}

# Create this session's state dir, point the "latest" symlink at it, and
# prune state dirs left behind by shells that are no longer running.
_ai_state_init() {
  mkdir -p "$AISHA_SESSION_DIR/last_context"
  ln -sfn "$AISHA_SESSION_DIR" "$AISHA_STATE_ROOT/latest" 2>/dev/null

  [[ -n "$_AISHA_STATE_PRUNED" ]] && return 0
  _AISHA_STATE_PRUNED=1
  local d pid
  for d in "$AISHA_STATE_ROOT"/session-*; do
    [[ -d "$d" ]] || continue
    pid="${d##*session-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$$" ]] && continue
    kill -0 "$pid" 2>/dev/null || rm -rf "$d"
  done
}

# Capture shell context (history, pwd, git status, exit code) into $ctxdir.
# $2 is the exit code of the user's last command, captured at ai() entry.
_ai_capture_context() {
  local ctxdir="$1" last_exit="${2:-0}"
  fc -l -15 > "$ctxdir/history.txt" 2>/dev/null
  pwd > "$ctxdir/pwd.txt"
  git status --short 2>/dev/null > "$ctxdir/git.txt"
  echo "Last exit code: $last_exit" > "$ctxdir/exit.txt"
}

# Strip <think>…</think> blocks, markdown code fences, blank lines, then
# return only the first meaningful line, trimmed.
_ai_strip_response() {
  local raw="$1"
  # First remove single-line <think>…</think> (BSD sed range fails when both
  # markers appear on the same line — it keeps scanning for the end marker
  # and deletes everything that follows).
  raw=$(echo "$raw" | sed 's/<think>[^<]*<\/think>//g')
  # Then remove multi-line <think>…</think> blocks
  raw=$(echo "$raw" | sed '/<think>/,/<\/think>/d')
  # Strip markdown fences, blank lines, take first meaningful line
  raw=$(echo "$raw" | sed 's/^```[a-z]*//g' | sed 's/```$//g' | sed '/^$/d' | head -1)
  raw="${raw#"${raw%%[![:space:]]*}"}"   # trim leading whitespace  (${x%%[![:space:]]*} = everything from first non-space onward)
  raw="${raw%"${raw##*[![:space:]]}"}"   # trim trailing whitespace (${x##*[![:space:]]}  = everything up to last non-space)
  echo "$raw"
}

# Render markdown-ish LLM output with ANSI colors for the terminal.
# - Code blocks (``` … ```)    → yellow
# - Inline `code`              → yellow
# - Headings (### …)           → bold cyan
# - Bold (**text**)            → bold white
# - Horizontal rules (---)     → dim line
# - Bullet lines (- …)        → green bullet + normal text
# - <think>…</think>           → stripped
# - Everything else            → normal
_ai_render_markdown() {
  local in_code=false in_think=false
  local line lang heading bullet_text num rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip <think> blocks
    if [[ "$line" == *"<think>"* ]]; then in_think=true; fi
    if $in_think; then
      [[ "$line" == *"</think>"* ]] && in_think=false
      continue
    fi

    # Internal protocol marker (auto-fix corrected command) — handled by the
    # caller, not for display
    [[ "$line" == FIX:* ]] && continue

    # Code fence toggle
    if [[ "$line" =~ ^\`\`\` ]]; then
      if $in_code; then
        in_code=false
      else
        in_code=true
        # Print language label if present
        lang="${line#\`\`\`}"
        [[ -n "$lang" ]] && printf "${AISHA_COLOR_DIM}  ── %s ──${AISHA_COLOR_RESET}\n" "$lang"
      fi
      continue
    fi

    # Inside code block → yellow
    if $in_code; then
      printf "${AISHA_COLOR_YELLOW}  %s${AISHA_COLOR_RESET}\n" "$line"
      continue
    fi

    # Heading → bold cyan (strip leading #'s and whitespace)
    if [[ "$line" =~ ^#{1,4}[[:space:]] ]]; then
      heading=$(echo "$line" | sed 's/^#* *//')
      printf "\n${AISHA_COLOR_CYAN}${AISHA_COLOR_BOLD}  %s${AISHA_COLOR_RESET}\n" "$heading"
      continue
    fi

    # Horizontal rule
    if [[ "$line" =~ ^-{3,}$ ]]; then
      printf "${AISHA_COLOR_DIM}  ──────────────────────────────────────${AISHA_COLOR_RESET}\n"
      continue
    fi

    # Bullet points
    if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]] ]]; then
      bullet_text="${line#*[-\*] }"
      # Colorize inline `code` within bullets
      bullet_text=$(echo "$bullet_text" | sed "s/\`\([^\`]*\)\`/$(printf "${AISHA_COLOR_YELLOW}")\1$(printf "${AISHA_COLOR_RESET}")/g")
      printf "${AISHA_COLOR_GREEN}  • ${AISHA_COLOR_RESET}%b\n" "$bullet_text"
      continue
    fi

    # Numbered list
    if [[ "$line" =~ ^[[:space:]]*[0-9]+\.[[:space:]] ]]; then
      num="${line%%.*}"
      num="${num#"${num%%[![:space:]]*}"}"
      rest="${line#*[0-9]. }"
      rest=$(echo "$rest" | sed "s/\`\([^\`]*\)\`/$(printf "${AISHA_COLOR_YELLOW}")\1$(printf "${AISHA_COLOR_RESET}")/g")
      printf "${AISHA_COLOR_CYAN}  %s.${AISHA_COLOR_RESET} %b\n" "$num" "$rest"
      continue
    fi

    # Empty line
    if [[ -z "$line" ]]; then
      echo
      continue
    fi

    # Normal text: render **bold** and `code`
    line=$(echo "$line" | sed "s/\*\*\([^*]*\)\*\*/$(printf "${AISHA_COLOR_BOLD}${AISHA_COLOR_WHITE}")\1$(printf "${AISHA_COLOR_RESET}")/g")
    line=$(echo "$line" | sed "s/\`\([^\`]*\)\`/$(printf "${AISHA_COLOR_YELLOW}")\1$(printf "${AISHA_COLOR_RESET}")/g")
    printf "  %b\n" "$line"
  done
}


# ============================================================================
# 4. CONFIRMATION & EXECUTION
# ============================================================================

# Read a confirmation reply into $_AISHA_REPLY. When piped stdin was already
# consumed as context, read from the terminal instead. $_AISHA_REPLY_OK is
# false when no reply could be read at all (EOF, no tty) so callers can
# distinguish "pressed Enter" from "nobody there" and take the safe path.
_ai_read_reply() {
  _AISHA_REPLY=""
  _AISHA_REPLY_OK=true
  if [[ "$_AISHA_STDIN_CONSUMED" == true ]]; then
    read -r _AISHA_REPLY < /dev/tty 2>/dev/null || _AISHA_REPLY_OK=false
  else
    read -r _AISHA_REPLY || _AISHA_REPLY_OK=false
  fi
}

# Confirm a command with the user, then execute it.
# Risky commands require typing "YES"; safe commands accept Y/n.
# Sets $_AISHA_RUN_STATUS to "ran" or "aborted" so callers can tell a
# declined command (exit 0) apart from one that ran successfully.
_ai_confirm_and_run() {
  local cmd="$1"
  local confirm
  _AISHA_RUN_STATUS="aborted"

  if echo "$cmd" | grep -Eq "$_AISHA_RISKY_RE"; then
    echo -e "${AISHA_COLOR_RED}⚠️  Risky command detected.${AISHA_COLOR_RESET}"
    echo -n "Type YES to execute (Ctrl+C to abort): "
    _ai_read_reply; confirm="$_AISHA_REPLY"
    if [[ "$confirm" != "YES" ]]; then
      echo -e "${AISHA_COLOR_YELLOW}Aborted.${AISHA_COLOR_RESET}"
      return 0
    fi
  else
    echo -n -e "${AISHA_COLOR_GREEN}Execute this command? [Y/n]:${AISHA_COLOR_RESET} "
    _ai_read_reply
    if [[ "$_AISHA_REPLY_OK" == true ]]; then
      confirm="${_AISHA_REPLY:-Y}"   # plain Enter accepts
    else
      confirm="n"                    # EOF / no tty → abort
    fi
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo -e "${AISHA_COLOR_YELLOW}Aborted.${AISHA_COLOR_RESET}"
      return 0
    fi
  fi

  _AISHA_RUN_STATUS="ran"

  # Force color output for common commands (restore any pre-existing value after)
  local prev_clicolor_force="${CLICOLOR_FORCE-__aisha_unset__}"
  if echo "$cmd" | grep -qE '^(ls|grep|diff|tree)'; then
    export CLICOLOR_FORCE=1
  fi

  # Interactive/curses commands get garbled when piped through tee.
  # Detect them and run directly, saving output only for non-interactive cmds.
  local _ai_interactive=false
  local exit_code
  if echo "$cmd" | grep -qE "$_AISHA_INTERACTIVE_RE"; then
    _ai_interactive=true
  fi

  if $_ai_interactive; then
    eval "$cmd"
    exit_code=$?
  else
    eval "$cmd" 2>&1 | tee "$AISHA_SESSION_DIR/last_output.txt"
    # Must be the first statement after the pipeline: even [[ ]] resets
    # PIPESTATUS. bash fills PIPESTATUS[0]; zsh falls through to pipestatus[1].
    # shellcheck disable=SC2154  # pipestatus is zsh's lowercase PIPESTATUS
    exit_code="${PIPESTATUS[0]:-${pipestatus[1]}}"
  fi

  if [[ "$prev_clicolor_force" == "__aisha_unset__" ]]; then
    unset CLICOLOR_FORCE
  else
    export CLICOLOR_FORCE="$prev_clicolor_force"
  fi
  return "$exit_code"
}


# ============================================================================
# 5. AGENT TOOLS
# ============================================================================

# Each tool takes simple positional arguments and writes to stdout.

_ai_tool_read_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "ERROR: File not found: $file"
    return 1
  fi
  cat "$file"
}

_ai_tool_write_file() {
  local file="$1"; shift
  local content="$*"
  mkdir -p "$(dirname "$file")"
  echo "$content" > "$file"
  echo "OK: Wrote $(wc -c < "$file") bytes to $file"
}

_ai_tool_search() {
  local pattern="$1"
  local dir="${2:-.}"
  grep -rn "$pattern" "$dir" --include='*' 2>/dev/null | head -30
}

_ai_tool_web_fetch() {
  local url="$1"
  if command -v curl &>/dev/null; then
    local output
    if ! output=$(curl -sL --fail --max-time 15 "$url" 2>&1); then
      echo "ERROR: Failed to fetch $url"
      [[ -n "$output" ]] && echo "$output"
      return 1
    fi
    echo "$output" | head -200
  else
    echo "ERROR: curl not available"
    return 1
  fi
}

_ai_tool_list_dir() {
  local dir="${1:-.}"
  ls -la "$dir" 2>/dev/null
}


# ============================================================================
# 6. AGENT INTERNALS  (dispatcher, checkpoints, history, display)
# ============================================================================

# ---- Tool dispatcher ----
# Parses TOOL:<name>(<args>) and routes to the matching _ai_tool_* function.
_ai_agent_dispatch_tool() {
  local tool_call="$1"
  local stripped="${tool_call#TOOL:}"
  local tool_name tool_args

  tool_name=$(echo "$stripped" | sed 's/(.*//')
  tool_args=$(echo "$stripped" | sed 's/^[a-z_]*(\(.*\))$/\1/')

  if [[ -z "$tool_name" || -z "$tool_args" ]]; then
    echo "ERROR: Invalid tool call format: $tool_call"
    return 1
  fi

  case "$tool_name" in
    read_file)  _ai_tool_read_file "$tool_args" ;;
    write_file)
      local file="${tool_args%%,*}"
      local content="${tool_args#*,}"
      content="${content#"${content%%[![:space:]]*}"}"
      _ai_tool_write_file "$file" "$content"
      ;;
    search)
      local pattern="${tool_args%%,*}"
      local dir="${tool_args#*,}"
      [[ "$dir" == "$tool_args" ]] && dir="."
      dir="${dir#"${dir%%[![:space:]]*}"}"
      _ai_tool_search "$pattern" "$dir"
      ;;
    web_fetch)  _ai_tool_web_fetch "$tool_args" ;;
    list_dir)   _ai_tool_list_dir "$tool_args" ;;
    command)    eval "$tool_args" 2>&1 ;;
    *)
      echo "ERROR: Unknown tool: $tool_name"
      return 1
      ;;
  esac
}

# ---- Checkpoint: save ----
_ai_agent_save_checkpoint() {
  local agentdir="$1" step="$2" cmd="$3" output="$4" step_status="$5"
  local cpdir="$agentdir/checkpoints"
  mkdir -p "$cpdir"

  cat > "$cpdir/step_${step}.json" <<EOF
{
  "step": $step,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pwd": "$(pwd)",
  "action": $(echo "$cmd" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo "\"$cmd\""),
  "status": "$step_status",
  "output_file": "step_${step}_output.txt"
}
EOF
  echo "$output" > "$cpdir/step_${step}_output.txt"
  echo "[$step] ($step_status) $cmd" >> "$agentdir/agent_log.txt"
}

# ---- Checkpoint: load (returns highest completed step number) ----
_ai_agent_load_checkpoint() {
  local cpdir="$1/checkpoints"
  if [[ ! -d "$cpdir" ]]; then echo "0"; return; fi

  local last_step=0 n
  for f in "$cpdir"/step_*.json; do
    [[ -f "$f" ]] || continue
    n=$(basename "$f" | sed 's/step_//;s/\.json//')
    [[ "$n" -gt "$last_step" ]] && last_step="$n"
  done
  echo "$last_step"
}

# ---- History: build rolling context (last N steps, 5 lines of output each) ----
_ai_agent_get_history() {
  local agentdir="$1" max_history="${2:-5}"
  local cpdir="$agentdir/checkpoints"

  if [[ ! -d "$cpdir" ]]; then echo ""; return; fi

  local all_files total
  all_files=$(ls "$cpdir"/step_*.json 2>/dev/null | sort -V)
  total=$(echo "$all_files" | grep -c .)

  if [[ $total -gt $max_history ]]; then
    local skipped=$((total - max_history))
    echo "(Steps 1-$skipped omitted for brevity)"
  fi

  local _sn _act _ss _out
  echo "$all_files" | tail -n "$max_history" | while IFS= read -r _f; do
    [[ -z "$_f" ]] && continue
    _sn=$(basename "$_f" | sed 's/step_//;s/\.json//')
    _act=$(grep '"action"' "$_f" | sed 's/.*"action": *"//;s/",*//')
    _ss=$(grep '"status"' "$_f" | sed 's/.*"status": *"//;s/".*//')
    _out=""
    [[ -f "$cpdir/step_${_sn}_output.txt" ]] && _out=$(head -5 "$cpdir/step_${_sn}_output.txt")
    echo "--- Step $_sn ($_ss) ---"
    echo "Action: $_act"
    echo "Output: $_out"
    echo
  done
}

# ---- Display: session header ----
_ai_agent_header() {
  local mode="$1" goal="$2" max_steps="$3"
  local mode_label="auto"
  [[ "$mode" == "safe" ]] && mode_label="safe 🔒"
  echo
  echo -e "${AISHA_COLOR_CYAN}╔══════════════════════════════════════════════════════════╗${AISHA_COLOR_RESET}"
  echo -e "${AISHA_COLOR_CYAN}║${AISHA_COLOR_RESET}  ${AISHA_COLOR_WHITE}🤖 Agent Mode${AISHA_COLOR_RESET} ${AISHA_COLOR_DIM}($mode_label)${AISHA_COLOR_RESET}"
  echo -e "${AISHA_COLOR_CYAN}║${AISHA_COLOR_RESET}  ${AISHA_COLOR_BOLD}$goal${AISHA_COLOR_RESET}"
  echo -e "${AISHA_COLOR_CYAN}║${AISHA_COLOR_RESET}  ${AISHA_COLOR_DIM}Max steps: $max_steps │ Ctrl+C to abort${AISHA_COLOR_RESET}"
  echo -e "${AISHA_COLOR_CYAN}╚══════════════════════════════════════════════════════════╝${AISHA_COLOR_RESET}"
  echo
}

# ---- Display: step header with progress bar ----
_ai_agent_step_header() {
  local iteration="$1" max_steps="$2" label="$3" action="$4"
  local pct=$((iteration * 100 / max_steps))
  local filled=$((pct / 5))
  local empty=$((20 - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  echo -e "${AISHA_COLOR_DIM}──────────────────────────────────────────────────────────${AISHA_COLOR_RESET}"
  echo -e "${AISHA_COLOR_CYAN}  $label${AISHA_COLOR_RESET} ${AISHA_COLOR_DIM}step $iteration/$max_steps${AISHA_COLOR_RESET}  ${AISHA_COLOR_DIM}[$bar]${AISHA_COLOR_RESET} ${AISHA_COLOR_DIM}${pct}%${AISHA_COLOR_RESET}"
  echo -e "  ${AISHA_COLOR_YELLOW}❯ $action${AISHA_COLOR_RESET}"
}

# ---- Display: command output with box drawing ----
_ai_agent_show_output() {
  local output="$1" exit_code="$2"
  local line_count
  line_count=$(echo "$output" | wc -l | tr -d ' ')

  echo -e "${AISHA_COLOR_DIM}  ┌─ output ──────────────────────────────────────────────${AISHA_COLOR_RESET}"
  if [[ -n "$output" ]]; then
    echo "$output" | head -10 | sed 's/^/  │ /'
    [[ "$line_count" -gt 10 ]] && echo -e "  │ ${AISHA_COLOR_DIM}... ($((line_count - 10)) more lines)${AISHA_COLOR_RESET}"
  else
    echo -e "  │ ${AISHA_COLOR_DIM}(no output)${AISHA_COLOR_RESET}"
  fi
  echo -e "${AISHA_COLOR_DIM}  └──────────────────────────────────────────────────────${AISHA_COLOR_RESET}"

  if [[ "$exit_code" -ne 0 ]]; then
    echo -e "  ${AISHA_COLOR_RED}✗ exit code $exit_code${AISHA_COLOR_RESET}"
  else
    echo -e "  ${AISHA_COLOR_GREEN}✓ ok${AISHA_COLOR_RESET}"
  fi
  echo
}


# ============================================================================
# 7. AGENT COMMAND EXECUTOR
# ============================================================================

# Execute one agent step with safety gating.
# Returns: 0=executed, 1=aborted, 2=skipped
_ai_agent_exec_cmd() {
  local cmd="$1" mode="$2" agentdir="$3" iteration="$4"

  # Risky commands always require confirmation, regardless of mode
  local is_risky=false
  echo "$cmd" | grep -Eq "$_AISHA_RISKY_RE" && is_risky=true

  if $is_risky; then
    echo -e "  ${AISHA_COLOR_RED}⚠️  Risky command — requires explicit approval${AISHA_COLOR_RESET}"
    echo -n -e "  ${AISHA_COLOR_RED}Type YES to execute, or 'skip' to skip:${AISHA_COLOR_RESET} "
    read -r confirm
    if [[ "$confirm" == "skip" ]]; then
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "SKIPPED by user (risky)" "skipped"
      echo -e "  ${AISHA_COLOR_YELLOW}⏭  Skipped${AISHA_COLOR_RESET}"
      echo
      return 2
    elif [[ "$confirm" != "YES" ]]; then
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "ABORTED by user (risky)" "aborted"
      return 1
    fi
  elif [[ "$mode" == "safe" ]]; then
    echo -n -e "  ${AISHA_COLOR_GREEN}Execute? [Y/n/skip]:${AISHA_COLOR_RESET} "
    read -r confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[Ss] ]]; then
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "SKIPPED by user" "skipped"
      echo -e "  ${AISHA_COLOR_YELLOW}⏭  Skipped${AISHA_COLOR_RESET}"
      echo
      return 2
    elif [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "ABORTED by user" "aborted"
      return 1
    fi
  fi

  # Execute — interactive/curses commands run directly, others capture output
  local cmd_output cmd_exit step_status
  if echo "$cmd" | grep -qE "$_AISHA_INTERACTIVE_RE"; then
    eval "$cmd"
    cmd_exit=$?
    cmd_output="(interactive command — output not captured)"
  else
    cmd_output=$(eval "$cmd" 2>&1)
    cmd_exit=$?
  fi

  _ai_agent_show_output "$cmd_output" "$cmd_exit"

  step_status="ok"
  [[ $cmd_exit -ne 0 ]] && step_status="error"
  _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "$cmd_output" "$step_status"
  return 0
}


# ============================================================================
# 8. AGENT LOOP
# ============================================================================

# Build the system prompt sent to the LLM at each agent step.
_ai_agent_system_prompt() {
  local step="$1" max_steps="$2" total="$3"
  cat <<EOF
You are an autonomous shell agent working toward a goal.
The user's OS is: $AISHA_OS

The goal is in the attached goal.txt.

STEP: $step of $max_steps (total: $total)

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
- If stuck after 3 retries, mark as FAILED
EOF
}

_ai_agent() {
  local mode="$1"  # "auto" or "safe"
  shift
  local goal="$*"

  _ai_state_init
  local agentdir="$AISHA_SESSION_DIR/agent"
  local max_steps="${AISHA_AGENT_MAX_STEPS:-15}"

  # ---- Resume or fresh start ----
  local resume=false
  if [[ "$goal" == "--resume" ]]; then
    resume=true
    if [[ ! -f "$agentdir/goal.txt" ]]; then
      echo -e "${AISHA_COLOR_RED}No agent session to resume.${AISHA_COLOR_RESET}"
      return 1
    fi
    goal=$(cat "$agentdir/goal.txt")
    mode=$(cat "$agentdir/mode.txt" 2>/dev/null || echo "auto")
    echo -e "${AISHA_COLOR_CYAN}🔄 Resuming agent session...${AISHA_COLOR_RESET}"
  else
    rm -rf "$agentdir"
    mkdir -p "$agentdir/checkpoints"
    echo "$goal" > "$agentdir/goal.txt"
    echo "$mode" > "$agentdir/mode.txt"
  fi

  local start_step=0
  if $resume; then
    start_step=$(_ai_agent_load_checkpoint "$agentdir")
    echo -e "  ${AISHA_COLOR_DIM}Picking up from step $start_step${AISHA_COLOR_RESET}"
  fi

  _ai_agent_header "$mode" "$goal" "$max_steps"

  # Capture initial context
  local ctxdir="$AISHA_SESSION_DIR/last_context"
  _ai_capture_context "$ctxdir" 0

  # ---- Step loop ----
  # Outer loop: allows continuation after hitting max_steps
  # Inner loop: runs steps 1…max_steps, then breaks to the outer loop for the
  #             "continue for another N steps?" prompt
  local iteration=$start_step total_steps=0
  local _resp="" cmd="" exec_result=0 confirm=""

  while true; do          # ← continuation loop
    while [[ $iteration -lt $max_steps ]]; do   # ← step loop
      ((iteration++))
      ((total_steps++))

      # Build rolling history (last 5 steps)
      _ai_agent_get_history "$agentdir" 5 > "$agentdir/history_context.txt"

      echo -ne "${AISHA_COLOR_DIM}  ⏳ Thinking...${AISHA_COLOR_RESET}\r"

      # ---- Ask LLM for next action ----
      local _agent_prompt
      _agent_prompt=$(_ai_agent_system_prompt "$iteration" "$max_steps" "$total_steps")

      _resp=$(llm -m "$AISHA_MODEL_TASK" \
        -f "$ctxdir/pwd.txt" \
        -f "$ctxdir/git.txt" \
        -f "$agentdir/goal.txt" \
        -f "$agentdir/history_context.txt" \
        "$_agent_prompt")

      echo -ne "\033[2K\r"   # clear thinking indicator

      _resp=$(_ai_strip_response "$_resp")

      # ---- Handle: DONE ----
      if [[ "$_resp" == DONE:* ]]; then
        local summary="${_resp#DONE:}"
        summary="${summary#"${summary%%[![:space:]]*}"}"
        _ai_agent_save_checkpoint "$agentdir" "$iteration" "DONE" "$summary" "done"
        echo -e "${AISHA_COLOR_DIM}──────────────────────────────────────────────────────────${AISHA_COLOR_RESET}"
        echo
        echo -e "  ${AISHA_COLOR_GREEN}✅ Done!${AISHA_COLOR_RESET} ${AISHA_COLOR_DIM}Completed in $total_steps step(s)${AISHA_COLOR_RESET}"
        echo -e "  ${AISHA_COLOR_WHITE}$summary${AISHA_COLOR_RESET}"
        echo
        echo -e "  ${AISHA_COLOR_DIM}📋 Log: $agentdir/agent_log.txt${AISHA_COLOR_RESET}"
        echo
        return 0

      # ---- Handle: FAILED ----
      elif [[ "$_resp" == FAILED:* ]]; then
        local reason="${_resp#FAILED:}"
        reason="${reason#"${reason%%[![:space:]]*}"}"
        _ai_agent_save_checkpoint "$agentdir" "$iteration" "FAILED" "$reason" "failed"
        echo -e "${AISHA_COLOR_DIM}──────────────────────────────────────────────────────────${AISHA_COLOR_RESET}"
        echo
        echo -e "  ${AISHA_COLOR_RED}❌ Failed at step $iteration${AISHA_COLOR_RESET}"
        echo -e "  ${AISHA_COLOR_YELLOW}$reason${AISHA_COLOR_RESET}"
        echo
        echo -e "  ${AISHA_COLOR_DIM}💡 Resume with:${AISHA_COLOR_RESET} ${AISHA_COLOR_CYAN}ai --agent --resume${AISHA_COLOR_RESET}"
        echo
        return 1

      # ---- Handle: TOOL call ----
      elif [[ "$_resp" == TOOL:* ]]; then
        _ai_agent_step_header "$iteration" "$max_steps" "🔧 Tool" "$_resp"

        if [[ "$mode" == "safe" ]]; then
          echo -n -e "  ${AISHA_COLOR_GREEN}Allow? [Y/n/skip]:${AISHA_COLOR_RESET} "
          read -r confirm
          confirm=${confirm:-Y}
          if [[ "$confirm" =~ ^[Ss] ]]; then
            _ai_agent_save_checkpoint "$agentdir" "$iteration" "$_resp" "SKIPPED by user" "skipped"
            echo -e "  ${AISHA_COLOR_YELLOW}⏭  Skipped${AISHA_COLOR_RESET}"
            echo
            continue
          elif [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            _ai_agent_save_checkpoint "$agentdir" "$iteration" "$_resp" "ABORTED by user" "aborted"
            echo
            echo -e "  ${AISHA_COLOR_YELLOW}Agent paused.${AISHA_COLOR_RESET} ${AISHA_COLOR_DIM}Resume with:${AISHA_COLOR_RESET} ${AISHA_COLOR_CYAN}ai --agent --resume${AISHA_COLOR_RESET}"
            echo
            return 1
          fi
        fi

        local tool_output tool_exit step_status
        tool_output=$(_ai_agent_dispatch_tool "$_resp" 2>&1)
        tool_exit=$?
        _ai_agent_show_output "$tool_output" "$tool_exit"
        step_status="ok"
        [[ $tool_exit -ne 0 ]] && step_status="error"
        _ai_agent_save_checkpoint "$agentdir" "$iteration" "$_resp" "$tool_output" "$step_status"

      # ---- Handle: COMMAND (or bare command without prefix) ----
      else
        [[ "$_resp" == COMMAND:* ]] && _resp="${_resp#COMMAND:}"
        cmd="${_resp#"${_resp%%[![:space:]]*}"}"

        _ai_agent_step_header "$iteration" "$max_steps" "⚡ Run" "$cmd"

        _ai_agent_exec_cmd "$cmd" "$mode" "$agentdir" "$iteration"
        exec_result=$?
        if [[ $exec_result -eq 1 ]]; then
          echo
          echo -e "  ${AISHA_COLOR_YELLOW}Agent paused.${AISHA_COLOR_RESET} ${AISHA_COLOR_DIM}Resume with:${AISHA_COLOR_RESET} ${AISHA_COLOR_CYAN}ai --agent --resume${AISHA_COLOR_RESET}"
          echo
          return 1
        elif [[ $exec_result -eq 2 ]]; then
          continue
        fi
      fi
    done   # ← end step loop

    # ---- Max steps reached — offer continuation ----
    echo -e "${AISHA_COLOR_DIM}──────────────────────────────────────────────────────────${AISHA_COLOR_RESET}"
    echo
    echo -e "  ${AISHA_COLOR_YELLOW}⚠️  Reached max steps ($max_steps) without completing goal.${AISHA_COLOR_RESET}"
    echo -n -e "  ${AISHA_COLOR_GREEN}Continue for another $max_steps steps? [Y/n]:${AISHA_COLOR_RESET} "
    read -r confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      iteration=0
      echo
      echo -e "  ${AISHA_COLOR_CYAN}↻ Continuing...${AISHA_COLOR_RESET} ${AISHA_COLOR_DIM}(total steps so far: $total_steps)${AISHA_COLOR_RESET}"
      echo
    else
      echo
      echo -e "  ${AISHA_COLOR_DIM}Stopped after $total_steps total step(s).${AISHA_COLOR_RESET}"
      echo -e "  ${AISHA_COLOR_DIM}💡 Resume with:${AISHA_COLOR_RESET} ${AISHA_COLOR_CYAN}ai --agent --resume${AISHA_COLOR_RESET}"
      echo
      return 1
    fi
  done     # ← end continuation loop
}


# ============================================================================
# 9. HELP, TIPS & SUGGESTION DELIVERY
# ============================================================================

_ai_help() {
  _ai_render_markdown <<EOF
# aisha $AISHA_VERSION — AI shell assistant

**Usage:** ai [flags] <request in natural language>

### Subcommands
- \`ai redo\` — re-run the last suggested command
- \`ai rerun\` — re-run your last command, capture its output, diagnose failures
- \`ai explain\` — explain the last suggested command (thinking model)
- \`ai /help\` — this help
- \`ai /tips [topic]\` — power-user one-liners (curated, or generated for a topic)

### Flags
- \`--deep\` — use the thinking model for thorough analysis
- \`-n, --no-exec\` — print the suggested command only (for scripts and pipes)
- \`-c, --refine <feedback>\` — revise the last suggestion ("use ripgrep instead")
- \`--agent <goal>\` — autonomous multi-step mode (\`--agent --resume\` to continue)
- \`--agent-safe <goal>\` — agent mode, confirm every step
- \`--version\` — print version

### Piping
- \`docker logs app 2>&1 | ai why is this crashing\` — piped input becomes context
- \`ai -n list open ports | pbcopy\` — pipe the bare command anywhere

### How suggestions run
By default the suggested command is placed in your input line (zsh) or
history (bash: press ↑) so you can edit it before running. Set
\`AISHA_AUTORUN=1\` for the legacy confirm-and-run prompt. Risky commands
(rm, sudo, dd, ...) always get a red warning.

### Configuration
Config file: \`$AISHA_CONFIG_FILE\` (plain shell assignments).
Key knobs: \`AISHA_MODEL_TASK\`, \`AISHA_MODEL_THINKING\`, \`AISHA_AGENT_MAX_STEPS\`,
\`AISHA_AUTORUN\`, \`AISHA_STDIN_CONTEXT\`.

Bare \`ai\` right after a failed command diagnoses the failure.
EOF
}

_ai_tips() {
  # Topic mode: ask the task model for one-liners about the given topic
  if [[ $# -gt 0 ]]; then
    local topic="$*"
    _ai_llm_stream -m "$AISHA_MODEL_TASK" \
      "You are an expert Unix/Linux sysadmin. The user's OS is: $AISHA_OS
Give exactly 5 practical, non-obvious shell one-liners about: $topic
Format each as a markdown bullet: the command in backticks, then a dash and a one-sentence explanation.
No preamble, no closing remarks." | _ai_render_markdown
    return
  fi

  _ai_render_markdown <<'EOF'
# aisha tips & tricks

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
- `du -sh * | sort -h` — what's eating disk, sorted
EOF
}

# Hand a suggested command to the user according to the active mode:
#   -n flag                         → print the bare command
#   AISHA_AUTORUN=1                 → legacy confirm-and-eval
#   piped stdout / non-interactive  → print the bare command
#   interactive zsh/bash            → inject into the editable input line
_ai_deliver_suggestion() {
  local response="$1" no_exec="${2:-false}"

  echo "$response" > "$AISHA_SESSION_DIR/last_command.txt"

  if [[ "$no_exec" == true ]]; then
    echo "$response"
    return 0
  fi

  if [[ "$AISHA_AUTORUN" == "1" ]]; then
    echo
    echo -e "${AISHA_COLOR_CYAN}Suggested command:${AISHA_COLOR_RESET}"
    echo -e "  ${AISHA_COLOR_YELLOW}$response${AISHA_COLOR_RESET}"
    echo
    _ai_confirm_and_run "$response"
    return $?
  fi

  # Pipe-friendly: `ai find big files | pbcopy` gets just the command
  if [[ ! -t 1 ]] || ! _ai_shell_interactive; then
    echo "$response"
    return 0
  fi

  echo
  echo -e "${AISHA_COLOR_CYAN}Suggested command:${AISHA_COLOR_RESET}"
  echo -e "  ${AISHA_COLOR_YELLOW}$response${AISHA_COLOR_RESET}"
  if echo "$response" | grep -Eq "$_AISHA_RISKY_RE"; then
    echo -e "  ${AISHA_COLOR_RED}⚠️  Review carefully — this command can be destructive.${AISHA_COLOR_RESET}"
  fi

  if _ai_inject_buffer "$response"; then
    if [[ -n "$ZSH_VERSION" ]]; then
      echo -e "  ${AISHA_COLOR_DIM}↳ placed in your input line — edit if needed, Enter to run${AISHA_COLOR_RESET}"
    else
      echo -e "  ${AISHA_COLOR_DIM}↳ press ↑ to edit and run${AISHA_COLOR_RESET}"
    fi
    echo
    return 0
  fi

  # No buffer mechanism available — fall back to confirm-and-run
  echo
  _ai_confirm_and_run "$response"
}

# Diagnose a failed command: stream an explanation, then extract the model's
# corrected command (final "FIX: <cmd>" line) and deliver it like any other
# suggestion. Attaches last_output.txt when a command was run through aisha.
_ai_autofix() {
  local exit_code="${1:-1}"
  local tmpdir="$AISHA_SESSION_DIR"
  local ctxdir="$tmpdir/last_context"

  local -a out_ctx
  out_ctx=()
  [[ -s "$tmpdir/last_output.txt" ]] && out_ctx=(-f "$tmpdir/last_output.txt")

  _ai_llm_stream -m "$AISHA_MODEL_THINKING" \
    -f "$ctxdir/history.txt" \
    -f "$ctxdir/pwd.txt" \
    -f "$ctxdir/git.txt" \
    -f "$ctxdir/exit.txt" \
    "${out_ctx[@]}" \
    "$(_ai_system_prompt deep)

The user's last command failed (exit code $exit_code).
history.txt holds the recent commands. If last_output.txt is attached, it is
the captured output of the most recent command run through aisha — use it if
it matches the failure.
Explain briefly why the command failed and how to fix it.
Then, if there is a clear corrected command, END your reply with exactly one
final line in this form (no code fences, nothing after it):
FIX: <the corrected command>
If there is no single corrected command, omit the FIX line entirely." \
    | tee "$tmpdir/autofix.txt" | _ai_render_markdown

  local fix
  fix=$(grep '^FIX:' "$tmpdir/autofix.txt" 2>/dev/null | tail -1)
  rm -f "$tmpdir/autofix.txt"
  fix="${fix#FIX:}"
  fix="${fix#"${fix%%[![:space:]]*}"}"
  fix="${fix%"${fix##*[![:space:]]}"}"
  fix="${fix#\`}"; fix="${fix%\`}"

  [[ -n "$fix" ]] && _ai_deliver_suggestion "$fix" false
  return 0
}


# ============================================================================
# 10. MAIN ENTRY POINT
# ============================================================================

# $1 is the exit code of the user's previous command, forwarded by ai()
# before anything else can overwrite $?.
_ai() {
  local last_exit="${1:-0}"
  shift

  _ai_state_init
  local tmpdir="$AISHA_SESSION_DIR"
  local ctxdir="$tmpdir/last_context"
  _AISHA_STDIN_CONSUMED=false

  # ---- Flags (order-independent, may precede the prompt) ----
  local persona="sysadmin" no_exec=false refine=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deep)          persona="deep"; shift ;;
      -n|--no-exec)    no_exec=true; shift ;;
      -c|--refine)     refine=true; shift ;;
      -h|--help|/help) _ai_help; return 0 ;;
      /tips)           shift; _ai_tips "$@"; return $? ;;
      --version)       echo "aisha $AISHA_VERSION"; return 0 ;;
      -agent|--agent)           shift; _ai_agent "auto" "$@"; return $? ;;
      -agent-safe|--agent-safe) shift; _ai_agent "safe" "$@"; return $? ;;
      --) shift; break ;;
      *)  break ;;
    esac
  done

  # ---- Subcommand: redo ----
  if [[ "$1" == "redo" && $# -eq 1 ]]; then
    if [[ ! -f "$tmpdir/last_command.txt" ]]; then
      echo -e "${AISHA_COLOR_RED}No previous AI suggestion to redo.${AISHA_COLOR_RESET}"
      return 1
    fi
    local cmd; cmd=$(cat "$tmpdir/last_command.txt")
    echo -e "${AISHA_COLOR_CYAN}Redoing last suggested command:${AISHA_COLOR_RESET}"
    echo -e "  ${AISHA_COLOR_YELLOW}$cmd${AISHA_COLOR_RESET}"
    echo
    _ai_confirm_and_run "$cmd"
    return $?
  fi

  # ---- Subcommand: rerun (re-run last history command, capture, diagnose) ----
  if [[ "$1" == "rerun" && $# -eq 1 ]]; then
    # Most recent history entry that doesn't invoke ai anywhere (also after
    # |, ;, &&) — re-running an ai call would recurse.
    local prev
    prev=$(fc -ln -10 2>/dev/null | grep -vE '(^[[:space:]]*|[|;&][[:space:]]*)ai([[:space:]]|$)' | tail -1)
    prev="${prev#"${prev%%[![:space:]]*}"}"
    prev="${prev%"${prev##*[![:space:]]}"}"
    if [[ -z "$prev" ]]; then
      echo -e "${AISHA_COLOR_RED}No previous command found in history.${AISHA_COLOR_RESET}"
      return 1
    fi
    echo -e "${AISHA_COLOR_CYAN}Re-running to capture output:${AISHA_COLOR_RESET}"
    echo -e "  ${AISHA_COLOR_YELLOW}$prev${AISHA_COLOR_RESET}"
    echo
    local rerun_exit=0
    _ai_confirm_and_run "$prev" || rerun_exit=$?
    [[ "$_AISHA_RUN_STATUS" != "ran" ]] && return 0
    if [[ $rerun_exit -ne 0 ]]; then
      echo
      _ai_capture_context "$ctxdir" "$rerun_exit"
      _ai_autofix "$rerun_exit"
    else
      echo -e "${AISHA_COLOR_GREEN}✓ Command succeeded — nothing to fix.${AISHA_COLOR_RESET}"
    fi
    return 0
  fi

  # ---- Subcommand: explain (bare only — "explain <question>" falls through) ----
  if [[ "$1" == "explain" && $# -eq 1 ]]; then
    if [[ ! -f "$tmpdir/last_command.txt" ]]; then
      echo -e "${AISHA_COLOR_RED}No previous AI suggestion to explain.${AISHA_COLOR_RESET}"
      return 1
    fi
    _ai_llm_stream -m "$AISHA_MODEL_THINKING" \
      -f "$ctxdir/history.txt" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      -f "$ctxdir/exit.txt" \
      -f "$tmpdir/last_command.txt" \
      -f "$tmpdir/last_prompt.txt" \
      "You are an expert sysadmin. The user's OS is: $AISHA_OS
Explain why the command in last_command.txt was suggested, what it does, and any risks.
The original user intent is in last_prompt.txt." | _ai_render_markdown
    return
  fi

  # ---- Piped stdin becomes context (capped at 64 KB) ----
  local stdin_ctx=""
  if [[ ! -t 0 && "$AISHA_STDIN_CONTEXT" == "1" ]]; then
    head -c 65536 > "$ctxdir/stdin.txt" 2>/dev/null
    _AISHA_STDIN_CONSUMED=true
    if [[ -s "$ctxdir/stdin.txt" ]]; then
      stdin_ctx="$ctxdir/stdin.txt"
    else
      rm -f "$ctxdir/stdin.txt"
    fi
  fi
  local -a extra_ctx
  extra_ctx=()
  [[ -n "$stdin_ctx" ]] && extra_ctx=(-f "$stdin_ctx")

  # ---- Refinement: revise the previous suggestion with user feedback ----
  if [[ "$refine" == true ]]; then
    local feedback="$*"
    if [[ -z "$feedback" ]]; then
      echo -e "${AISHA_COLOR_RED}Usage: ai -c <feedback on the last suggestion>${AISHA_COLOR_RESET}"
      return 1
    fi
    if [[ ! -f "$tmpdir/last_command.txt" || ! -f "$tmpdir/last_prompt.txt" ]]; then
      echo -e "${AISHA_COLOR_RED}No previous suggestion to refine.${AISHA_COLOR_RESET}"
      return 1
    fi
    _ai_capture_context "$ctxdir" "$last_exit"
    _ai_thinking_start
    local revised
    revised=$(llm -m "$AISHA_MODEL_TASK" \
      -f "$tmpdir/last_prompt.txt" \
      -f "$tmpdir/last_command.txt" \
      "${extra_ctx[@]}" \
      "$(_ai_system_prompt sysadmin)

last_prompt.txt is the user's original request; last_command.txt is the command you previously suggested.
The user wants it revised: $feedback

Output ONLY the revised shell command — no explanation, no code fences.")
    _ai_thinking_end
    revised=$(_ai_strip_response "$revised")
    if [[ -z "$revised" ]]; then
      echo -e "${AISHA_COLOR_YELLOW}No response available.${AISHA_COLOR_RESET}"
      return 1
    fi
    # Append the feedback so further refinements see the whole conversation
    printf '%s\nRefinement: %s\n' "$(cat "$tmpdir/last_prompt.txt")" "$feedback" > "$tmpdir/last_prompt.txt"
    _ai_deliver_suggestion "$revised" "$no_exec"
    return $?
  fi

  # ---- Build prompt ----
  local prompt="$*"
  [[ -n "$prompt" ]] && echo "$prompt" > "$tmpdir/last_prompt.txt"

  # ---- Capture context ----
  _ai_capture_context "$ctxdir" "$last_exit"

  # ---- Piped input with no prompt → diagnose the piped data ----
  if [[ -z "$prompt" && -n "$stdin_ctx" ]]; then
    _ai_llm_stream -m "$AISHA_MODEL_THINKING" \
      -f "$stdin_ctx" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      "$(_ai_system_prompt deep)

The user piped data into aisha (attached stdin.txt) without a question.
Summarize what it shows and diagnose any errors or anomalies." | _ai_render_markdown
    return
  fi

  # ---- Auto-fix: empty prompt + previous command failed ----
  if [[ "$last_exit" -ne 0 && -z "$prompt" ]]; then
    _ai_autofix "$last_exit"
    return
  fi

  # ---- Interactive fallback (e.g. if apostrophes broke argument parsing) ----
  if [[ -z "$prompt" ]]; then
    echo -n -e "${AISHA_COLOR_CYAN}Ask: ${AISHA_COLOR_RESET}"
    _ai_read_reply
    prompt="$_AISHA_REPLY"
    [[ -z "$prompt" ]] && return 0
    echo "$prompt" > "$tmpdir/last_prompt.txt"
  fi

  # Auto-select deep persona for explanation queries
  if [[ "$prompt" =~ ^(how|why|what|explain|help)([[:space:]]|$) ]]; then
    persona="deep"
  fi

  local model; model=$(_ai_model_for "$persona")
  local system_prompt; system_prompt=$(_ai_system_prompt "$persona")

  # ---- Explanation mode (how/why/what/explain/help) ----
  if [[ "$prompt" =~ ^(how|why|what|explain|help)([[:space:]]|$) ]]; then
    _ai_llm_stream -m "$model" \
      -f "$ctxdir/history.txt" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      -f "$tmpdir/last_prompt.txt" \
      "${extra_ctx[@]}" \
      "$system_prompt

Explain clearly and include one concrete command example to illustrate if applicable, but do NOT prompt the user to execute anything.
The user's question is in the attached last_prompt.txt. If stdin.txt is attached, it is data the user piped in — treat it as the subject of the question." | _ai_render_markdown
    return
  fi

  # ---- Command suggestion mode ----
  _ai_thinking_start
  local response
  response=$(llm -m "$model" \
    -f "$ctxdir/history.txt" \
    -f "$ctxdir/pwd.txt" \
    -f "$ctxdir/git.txt" \
    -f "$tmpdir/last_prompt.txt" \
    "${extra_ctx[@]}" \
    "$system_prompt

The user's request is in the attached last_prompt.txt.

Rules:
- If the request is a shell/system task, output ONLY the command (no explanation). Most requests are tasks.
- ONLY if the request is clearly a greeting or chit-chat (like 'hello', 'what's up', 'how are you'), prefix your response with 'ANSWER:' followed by a brief, friendly reply
- When in doubt, treat it as a task and output a command
- If stdin.txt is attached, it is data the user piped in — treat it as the subject of the request
- Never use rm -rf
- Avoid destructive commands")
  _ai_thinking_end

  response=$(_ai_strip_response "$response")

  if [[ -z "$response" ]]; then
    echo
    echo -e "${AISHA_COLOR_YELLOW}No response available.${AISHA_COLOR_RESET}"
    return 0
  fi

  # ---- Informational answer (not a command) ----
  if [[ "$response" == ANSWER:* ]]; then
    local answer="${response#ANSWER:}"
    answer="${answer#"${answer%%[![:space:]]*}"}"
    echo
    echo -e "${AISHA_COLOR_CYAN}$answer${AISHA_COLOR_RESET}"
    return 0
  fi

  # ---- Command suggestion — deliver per mode (inject/confirm/print) ----
  echo "$persona" > "$tmpdir/last_persona.txt"
  _ai_deliver_suggestion "$response" "$no_exec"
}

# Public alias. Capturing $? here, before any other command runs, is the only
# way to see the exit code of the command the user ran before invoking ai.
ai() { _ai "$?" "$@"; }


# ============================================================================
# 11. SHELL INTEGRATION  (zsh ZLE + completion, bash completion)
# ============================================================================

_AISHA_COMPLETIONS="redo rerun explain /help /tips --deep --agent --agent-safe -n --no-exec -c --refine --help --version"

if [[ -n "$ZSH_VERSION" ]]; then
  # Pass unmatched globs (?, *) literally instead of erroring
  setopt nonomatch

  # ZLE widget: transparently replace ' with Unicode ʼ (U+02BC) in ai commands.
  # Visually identical, avoids shell quote-parsing issues. History stays clean.
  _ai_accept_line() {
    if [[ "$BUFFER" =~ ^ai[[:space:]] && "$BUFFER" == *"'"* ]]; then
      BUFFER="${BUFFER//\'/ʼ}"
      # shellcheck disable=SC2034  # CURSOR is read by zle
      CURSOR=${#BUFFER}
    fi
    zle .accept-line
  }
  zle -N accept-line _ai_accept_line

  # Completion: subcommands and flags in the first position only, so natural
  # language prompts are left alone (requires compinit to be loaded).
  _aisha_complete() {
    # shellcheck disable=SC2154  # CURRENT is set by the zsh completion system
    (( CURRENT == 2 )) || return 1
    # shellcheck disable=SC2086  # word splitting is intended
    compadd -- ${=_AISHA_COMPLETIONS}
  }
  command -v compdef >/dev/null 2>&1 && compdef _aisha_complete ai
fi

if [[ -n "$BASH_VERSION" ]]; then
  _aisha_complete_bash() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=()
    # Only offer completions for the first word or flag-like input
    if [[ $COMP_CWORD -eq 1 || "$cur" == -* || "$cur" == /* ]]; then
      while IFS= read -r c; do COMPREPLY+=("$c"); done \
        < <(compgen -W "$_AISHA_COMPLETIONS" -- "$cur")
    fi
  }
  complete -F _aisha_complete_bash ai 2>/dev/null
fi
