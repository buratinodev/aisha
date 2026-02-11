#!/usr/bin/env bash

# ---- Color definitions ----
COLOR_RED="\033[1;31m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[1;36m"
COLOR_DIM="\033[2m"
COLOR_BOLD="\033[1m"
COLOR_WHITE="\033[1;37m"
COLOR_RESET="\033[0m"

# ---- Model configuration ----
AI_MODEL_TASK="qwen3-coder:30b"       # Fast model for command suggestions & agent steps
AI_MODEL_THINKING="qwen3:32b"         # Reasoning model for deep analysis & explanations
AI_AGENT_MAX_STEPS=15

# ---- OS detection ----
AI_OS="$(uname -s)/$(uname -m)"
[[ -f /etc/os-release ]] && AI_OS="$AI_OS $(. /etc/os-release && echo "$NAME $VERSION_ID")"
[[ "$(uname -s)" == "Darwin" ]] && AI_OS="$AI_OS macOS $(sw_vers -productVersion 2>/dev/null)"

# ---- Agent configuration ----
AI_AGENT_TOOLS="command,read_file,write_file,search,web_fetch"

# ---- Installation procedure ----
if [[ "$1" == "--install" ]]; then
  # Detect user's default shell
  user_shell=$(basename "$SHELL")
  
  if [[ "$user_shell" == "bash" ]]; then
    rc_file="$HOME/.bashrc"
  elif [[ "$user_shell" == "zsh" ]]; then
    rc_file="$HOME/.zshrc"
  else
    echo -e "${COLOR_RED}Error: Unsupported shell '$user_shell'. Only bash and zsh are supported.${COLOR_RESET}"
    exit 1
  fi
  
  # Copy script to home directory
  script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  cp "$script_path" "$HOME/.airc"
  echo -e "${COLOR_GREEN}✓ Copied airc.sh to ~/.airc${COLOR_RESET}"
  
  # Check if already installed
  if grep -q "Load AI shell helpers" "$rc_file" 2>/dev/null; then
    echo -e "${COLOR_YELLOW}⚠ airc is already configured in $rc_file${COLOR_RESET}"
  else
    # Add to rc file
    echo "" >> "$rc_file"
    echo "# Load AI shell helpers" >> "$rc_file"
    echo 'if [[ -f "$HOME/.airc" ]]; then' >> "$rc_file"
    echo '  source "$HOME/.airc"' >> "$rc_file"
    echo 'fi' >> "$rc_file"
    echo -e "${COLOR_GREEN}✓ Added airc loader to $rc_file${COLOR_RESET}"
  fi
  
  echo ""
  echo -e "${COLOR_CYAN}Installation complete!${COLOR_RESET}"
  echo -e "Run: ${COLOR_YELLOW}source $rc_file${COLOR_RESET} to load airc in your current shell"
  echo -e "Or open a new terminal window."
  exit 0
fi

# ---- AI helper (llm wrapper with memory + risk confirmation) ----
_ai() {
  local tmpdir="/tmp/ai"           # Stores last command, prompt, persona, and output for redo/explain
  local ctxdir="$tmpdir/last_context" # Stores shell context (history, pwd, git status, exit code) sent to the LLM
  mkdir -p "$tmpdir" "$ctxdir"

  local persona="sysadmin"

  # ---- Special commands ----
  if [[ "$1" == "redo" ]]; then
    if [[ ! -f "$tmpdir/last_command.txt" ]]; then
      echo -e "${COLOR_RED}No previous AI suggestion to redo.${COLOR_RESET}"
      return 1
    fi

    local cmd
    cmd=$(cat "$tmpdir/last_command.txt")

    echo -e "${COLOR_CYAN}Redoing last suggested command:${COLOR_RESET}"
    echo -e "  ${COLOR_YELLOW}$cmd${COLOR_RESET}"
    echo

    _ai_confirm_and_run "$cmd"
    return $?
  fi

  if [[ "$1" == "explain" ]]; then
    if [[ ! -f "$tmpdir/last_command.txt" ]]; then
      echo -e "${COLOR_RED}No previous AI suggestion to explain.${COLOR_RESET}"
      return 1
    fi

    llm -m "$AI_MODEL_THINKING" \
      -f "$ctxdir/history.txt" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      -f "$ctxdir/exit.txt" \
      -f "$tmpdir/last_command.txt" \
      -f "$tmpdir/last_prompt.txt" \
      "You are an expert sysadmin. The user's OS is: $AI_OS
Explain why the command in last_command.txt was suggested, what it does, and any risks.
The original user intent is in last_prompt.txt."
    return
  fi

  # ---- Persona flag ----
  if [[ "$1" == "--deep" ]]; then
    persona="deep"
    shift
  fi

  # ---- Agent mode ----
  if [[ "$1" == "--agent" ]]; then
    shift
    _ai_agent "auto" "$@"
    return $?
  fi

  if [[ "$1" == "--agent-safe" ]]; then
    shift
    _ai_agent "safe" "$@"
    return $?
  fi

  local prompt="$*"

  # ---- Save prompt to file (avoids shell quoting issues with apostrophes etc.) ----
  [[ -n "$prompt" ]] && echo "$prompt" > "$tmpdir/last_prompt.txt"

  # ---- Capture context ----
  fc -l -15 > "$ctxdir/history.txt" 2>/dev/null
  pwd > "$ctxdir/pwd.txt"
  git status --short 2>/dev/null > "$ctxdir/git.txt"

  local last_exit=$?
  echo "Last exit code: $last_exit" > "$ctxdir/exit.txt"

  # ---- Auto-fix failed command (empty prompt + nonzero exit) ----
  if [[ "$last_exit" -ne 0 && -z "$prompt" ]]; then
    local system_prompt_fix="You are a senior systems engineer. The user's OS is: $AI_OS
Think step-by-step, consider edge cases, tradeoffs, and failure modes.
Prefer correctness over speed."
    llm -m "$AI_MODEL_THINKING" \
      -f "$ctxdir/history.txt" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      -f "$ctxdir/exit.txt" \
      "$system_prompt_fix

The user's last command failed.
Explain why it failed and suggest a fix.
Do not execute commands."
    return
  fi

  # ---- Interactive prompt fallback (e.g. if quotes broke argument parsing) ----
  if [[ -z "$prompt" ]]; then
    echo -n -e "${COLOR_CYAN}Ask: ${COLOR_RESET}"
    read -r prompt
    [[ -z "$prompt" ]] && return 0
  fi

  # Force deep persona for explanation queries
  if [[ "$prompt" =~ ^(how|why|what|explain|help)(\s|$) ]]; then
    persona="deep"
  fi

  # ---- Persona system prompt ----
  local system_prompt=""
  local model="$AI_MODEL_TASK"
  if [[ "$persona" == "deep" ]]; then
    model="$AI_MODEL_THINKING"
    system_prompt="You are a senior systems engineer. The user's OS is: $AI_OS
Think step-by-step, consider edge cases, tradeoffs, and failure modes.
Prefer correctness over speed."
  else
    system_prompt="You are an expert Unix/Linux sysadmin. The user's OS is: $AI_OS
Be concise, practical, and production-safe."
  fi

  # ---- Explanation mode ----
  if [[ "$prompt" =~ ^(how|why|what|explain|help)(\s|$) ]]; then
    llm -m "$model" \
      -f "$ctxdir/history.txt" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      -f "$tmpdir/last_prompt.txt" \
      "$system_prompt

Explain and suggest, but do NOT give commands to execute.
The user's question is in the attached last_prompt.txt."
    return
  fi

  # ---- Command suggestion mode ----
  local response
  response=$(llm -m "$model" \
    -f "$ctxdir/history.txt" \
    -f "$ctxdir/pwd.txt" \
    -f "$ctxdir/git.txt" \
    -f "$tmpdir/last_prompt.txt" \
    "$system_prompt

The user's request is in the attached last_prompt.txt.

Rules:
- If the request is a shell/system task, output ONLY the command (no explanation)
- If the request is conversational or informational (like greetings, questions about concepts), prefix your response with 'ANSWER:' followed by a brief answer
- Never use rm -rf
- Avoid destructive commands")

  # ---- Strip thinking blocks and markdown code fences, trim whitespace ----
  response=$(echo "$response" | sed '/<think>/,/<\/think>/d' | sed 's/^```[a-z]*//g' | sed 's/```$//g' | sed '/^$/d' | head -1)
  response="${response#"${response%%[![:space:]]*}"}"  # trim leading whitespace
  response="${response%"${response##*[![:space:]]}"}"  # trim trailing whitespace

  # Only proceed if a response was returned
  if [[ -z "$response" ]]; then
    echo
    echo -e "${COLOR_YELLOW}No response available.${COLOR_RESET}"
    return 0
  fi

  # ---- Check if this is an informational answer (not a command) ----
  if [[ "$response" == ANSWER:* ]]; then
    local answer="${response#ANSWER:}"
    answer="${answer#"${answer%%[![:space:]]*}"}"  # trim leading whitespace
    echo
    echo -e "${COLOR_CYAN}$answer${COLOR_RESET}"
    return 0
  fi

  # ---- Persist memory ----
  echo "$response" > "$tmpdir/last_command.txt"
  echo "$persona" > "$tmpdir/last_persona.txt"

  echo
  echo -e "${COLOR_CYAN}Suggested command:${COLOR_RESET}"
  echo -e "  ${COLOR_YELLOW}$response${COLOR_RESET}"
  echo

  _ai_confirm_and_run "$response"
}

# ---- Agent tool implementations ----
_ai_tool_read_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "ERROR: File not found: $file"
    return 1
  fi
  cat "$file"
}

_ai_tool_write_file() {
  local file="$1"
  shift
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
    curl -sL "$url" | head -200
  else
    echo "ERROR: curl not available"
    return 1
  fi
}

_ai_tool_list_dir() {
  local dir="${1:-.}"
  ls -la "$dir" 2>/dev/null
}

# ---- Agent tool dispatcher ----
_ai_agent_dispatch_tool() {
  local tool_call="$1"
  local tool_name=""
  local tool_args=""

  # Parse TOOL:<name>(<args>) format using sed (works in both bash and zsh)
  local stripped="${tool_call#TOOL:}"
  tool_name=$(echo "$stripped" | sed 's/(.*//')
  tool_args=$(echo "$stripped" | sed 's/^[a-z_]*(\(.*\))$/\1/')

  if [[ -z "$tool_name" || -z "$tool_args" ]]; then
    echo "ERROR: Invalid tool call format: $tool_call"
    return 1
  fi

  case "$tool_name" in
    read_file)
      _ai_tool_read_file "$tool_args"
      ;;
    write_file)
      # First arg is file path, rest is content (separated by comma)
      local file="${tool_args%%,*}"
      local content="${tool_args#*,}"
      content="${content#"${content%%[![:space:]]*}"}"  # trim leading space
      _ai_tool_write_file "$file" "$content"
      ;;
    search)
      local pattern="${tool_args%%,*}"
      local dir="${tool_args#*,}"
      [[ "$dir" == "$tool_args" ]] && dir="."
      dir="${dir#"${dir%%[![:space:]]*}"}"
      _ai_tool_search "$pattern" "$dir"
      ;;
    web_fetch)
      _ai_tool_web_fetch "$tool_args"
      ;;
    list_dir)
      _ai_tool_list_dir "$tool_args"
      ;;
    command)
      eval "$tool_args" 2>&1
      ;;
    *)
      echo "ERROR: Unknown tool: $tool_name"
      return 1
      ;;
  esac
}

# ---- Agent checkpoint system ----
_ai_agent_save_checkpoint() {
  local agentdir="$1"
  local step="$2"
  local cmd="$3"
  local output="$4"
  local step_status="$5"

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

  # Save cumulative log
  echo "[$step] ($step_status) $cmd" >> "$agentdir/agent_log.txt"
}

_ai_agent_load_checkpoint() {
  local agentdir="$1"
  local cpdir="$agentdir/checkpoints"

  if [[ ! -d "$cpdir" ]]; then
    echo "0"
    return
  fi

  # Find highest step number
  local last_step=0
  for f in "$cpdir"/step_*.json; do
    [[ -f "$f" ]] || continue
    local step_num
    step_num=$(basename "$f" | sed 's/step_//;s/\.json//')
    [[ "$step_num" -gt "$last_step" ]] && last_step="$step_num"
  done
  echo "$last_step"
}

_ai_agent_get_history() {
  local agentdir="$1"
  local max_history="${2:-5}"  # Only send last N steps to keep prompt small
  local cpdir="$agentdir/checkpoints"
  local step_log=""

  if [[ ! -d "$cpdir" ]]; then
    echo ""
    return
  fi

  # Get step files, take only the last N
  local all_files
  all_files=$(ls "$cpdir"/step_*.json 2>/dev/null | sort -V)
  local total
  total=$(echo "$all_files" | grep -c .)

  if [[ $total -gt $max_history ]]; then
    local skipped=$((total - max_history))
    step_log="(Steps 1-$skipped omitted for brevity)"$'\n'
  fi

  local _f _sn _act _ss _out
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
  echo "$step_log"
}

# ---- Agent display helpers ----
_ai_agent_header() {
  local mode="$1" goal="$2" max_steps="$3"
  local mode_label="auto"
  [[ "$mode" == "safe" ]] && mode_label="safe 🔒"
  echo
  echo -e "${COLOR_CYAN}╔══════════════════════════════════════════════════════════╗${COLOR_RESET}"
  echo -e "${COLOR_CYAN}║${COLOR_RESET}  ${COLOR_WHITE}🤖 Agent Mode${COLOR_RESET} ${COLOR_DIM}($mode_label)${COLOR_RESET}"
  echo -e "${COLOR_CYAN}║${COLOR_RESET}  ${COLOR_BOLD}$goal${COLOR_RESET}"
  echo -e "${COLOR_CYAN}║${COLOR_RESET}  ${COLOR_DIM}Max steps: $max_steps │ Ctrl+C to abort${COLOR_RESET}"
  echo -e "${COLOR_CYAN}╚══════════════════════════════════════════════════════════╝${COLOR_RESET}"
  echo
}

_ai_agent_step_header() {
  local iteration="$1" max_steps="$2" label="$3" action="$4"
  # Progress bar
  local pct=$((iteration * 100 / max_steps))
  local filled=$((pct / 5))
  local empty=$((20 - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  echo -e "${COLOR_DIM}──────────────────────────────────────────────────────────${COLOR_RESET}"
  echo -e "${COLOR_CYAN}  $label${COLOR_RESET} ${COLOR_DIM}step $iteration/$max_steps${COLOR_RESET}  ${COLOR_DIM}[$bar]${COLOR_RESET} ${COLOR_DIM}${pct}%${COLOR_RESET}"
  echo -e "  ${COLOR_YELLOW}❯ $action${COLOR_RESET}"
}

_ai_agent_show_output() {
  local output="$1" exit_code="$2"
  local line_count
  line_count=$(echo "$output" | wc -l | tr -d ' ')

  if [[ -n "$output" ]]; then
    echo -e "${COLOR_DIM}  ┌─ output ──────────────────────────────────────────────${COLOR_RESET}"
    echo "$output" | head -10 | sed 's/^/  │ /'
    if [[ "$line_count" -gt 10 ]]; then
      echo -e "  │ ${COLOR_DIM}... ($((line_count - 10)) more lines)${COLOR_RESET}"
    fi
    echo -e "${COLOR_DIM}  └──────────────────────────────────────────────────────${COLOR_RESET}"
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    echo -e "  ${COLOR_RED}✗ exit code $exit_code${COLOR_RESET}"
  else
    echo -e "  ${COLOR_GREEN}✓ ok${COLOR_RESET}"
  fi
  echo
}

# ---- Agent command executor (handles confirmation + execution) ----
# Returns: 0=executed, 1=aborted, 2=skipped
_ai_agent_exec_cmd() {
  local cmd="$1" mode="$2" agentdir="$3" iteration="$4"

  # Safety check for risky commands (always confirm, regardless of mode)
  local is_risky=false
  if echo "$cmd" | grep -Eq \
    '(^|\s)(sudo|rm|dd|mkfs|shred|find.*(rm|shred)|mv.*deleted|kubectl delete|terraform (apply|destroy)|gcloud delete)(\s|$)'; then
    is_risky=true
  fi

  if $is_risky; then
    echo -e "  ${COLOR_RED}⚠️  Risky command — requires explicit approval${COLOR_RESET}"
    echo -n -e "  ${COLOR_RED}Type YES to execute, or 'skip' to skip:${COLOR_RESET} "
    read -r confirm
    if [[ "$confirm" == "skip" ]]; then
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "SKIPPED by user (risky)" "skipped"
      echo -e "  ${COLOR_YELLOW}⏭  Skipped${COLOR_RESET}"
      echo
      return 2
    elif [[ "$confirm" != "YES" ]]; then
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "ABORTED by user (risky)" "aborted"
      return 1
    fi
  elif [[ "$mode" == "safe" ]]; then
    echo -n -e "  ${COLOR_GREEN}Execute? [Y/n/skip]:${COLOR_RESET} "
    read -r confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[Ss] ]]; then
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "SKIPPED by user" "skipped"
      echo -e "  ${COLOR_YELLOW}⏭  Skipped${COLOR_RESET}"
      echo
      return 2
    elif [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "ABORTED by user" "aborted"
      return 1
    fi
  fi

  # Execute
  local cmd_output
  cmd_output=$(eval "$cmd" 2>&1)
  local cmd_exit=$?

  _ai_agent_show_output "$cmd_output" "$cmd_exit"

  local step_status="ok"
  [[ $cmd_exit -ne 0 ]] && step_status="error"
  _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "$cmd_output" "$step_status"
  return 0
}

# ---- Agent mode ----
_ai_agent() {
  local mode="$1"  # "auto" or "safe"
  shift
  local goal="$*"

  local agentdir="/tmp/ai/agent"
  local max_steps="${AI_AGENT_MAX_STEPS:-15}"

  # Check for --resume flag
  local resume=false
  if [[ "$goal" == "--resume" ]]; then
    resume=true
    if [[ ! -f "$agentdir/goal.txt" ]]; then
      echo -e "${COLOR_RED}No agent session to resume.${COLOR_RESET}"
      return 1
    fi
    goal=$(cat "$agentdir/goal.txt")
    mode=$(cat "$agentdir/mode.txt" 2>/dev/null || echo "auto")
    echo -e "${COLOR_CYAN}🔄 Resuming agent session...${COLOR_RESET}"
  else
    # Fresh session - clean state
    rm -rf "$agentdir"
    mkdir -p "$agentdir/checkpoints"
    echo "$goal" > "$agentdir/goal.txt"
    echo "$mode" > "$agentdir/mode.txt"
  fi

  local start_step=0
  if $resume; then
    start_step=$(_ai_agent_load_checkpoint "$agentdir")
    echo -e "  ${COLOR_DIM}Picking up from step $start_step${COLOR_RESET}"
  fi

  _ai_agent_header "$mode" "$goal" "$max_steps"

  # Capture initial context
  local ctxdir="/tmp/ai/last_context"
  fc -l -15 > "$ctxdir/history.txt" 2>/dev/null
  pwd > "$ctxdir/pwd.txt"
  git status --short 2>/dev/null > "$ctxdir/git.txt"

  local iteration=$start_step
  local total_steps=0
  local _resp="" tool_output="" tool_exit=0 step_status="" cmd="" exec_result=0 summary="" reason="" confirm=""
  while true; do
  while [[ $iteration -lt $max_steps ]]; do
    ((iteration++))
    ((total_steps++))

    # Build agent history from checkpoints (last 5 steps to keep prompt small)
    _ai_agent_get_history "$agentdir" 5 > "$agentdir/history_context.txt"

    # Thinking indicator
    echo -ne "${COLOR_DIM}  ⏳ Thinking...${COLOR_RESET}\r"

    # Ask LLM for next action
    _resp=$(llm -m "$AI_MODEL_TASK" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      -f "$agentdir/goal.txt" \
      -f "$agentdir/history_context.txt" \
      "You are an autonomous shell agent working toward a goal.
The user's OS is: $AI_OS

The goal is in the attached goal.txt.

STEP: $iteration of $max_steps (total: $total_steps)

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
- If stuck after 3 retries, mark as FAILED")

    # Clear thinking indicator
    echo -ne "\033[2K\r"

    # Trim response (strip <think> blocks from reasoning models, then code fences)
    _resp=$(echo "$_resp" | sed '/<think>/,/<\/think>/d' | sed 's/^```[a-z]*//g' | sed 's/```$//g' | sed '/^$/d' | head -1)
    _resp="${_resp#"${_resp%%[![:space:]]*}"}"
    _resp="${_resp%"${_resp##*[![:space:]]}"}"

    # ---- Parse response ----
    if [[ "$_resp" == DONE:* ]]; then
      summary="${_resp#DONE:}"
      summary="${summary#"${summary%%[![:space:]]*}"}"
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "DONE" "$summary" "done"
      echo -e "${COLOR_DIM}──────────────────────────────────────────────────────────${COLOR_RESET}"
      echo
      echo -e "  ${COLOR_GREEN}✅ Done!${COLOR_RESET} ${COLOR_DIM}Completed in $total_steps step(s)${COLOR_RESET}"
      echo -e "  ${COLOR_WHITE}$summary${COLOR_RESET}"
      echo
      echo -e "  ${COLOR_DIM}📋 Log: $agentdir/agent_log.txt${COLOR_RESET}"
      echo
      return 0

    elif [[ "$_resp" == FAILED:* ]]; then
      reason="${_resp#FAILED:}"
      reason="${reason#"${reason%%[![:space:]]*}"}"
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "FAILED" "$reason" "failed"
      echo -e "${COLOR_DIM}──────────────────────────────────────────────────────────${COLOR_RESET}"
      echo
      echo -e "  ${COLOR_RED}❌ Failed at step $iteration${COLOR_RESET}"
      echo -e "  ${COLOR_YELLOW}$reason${COLOR_RESET}"
      echo
      echo -e "  ${COLOR_DIM}💡 Resume with:${COLOR_RESET} ${COLOR_CYAN}ai --agent --resume${COLOR_RESET}"
      echo
      return 1

    elif [[ "$_resp" == TOOL:* ]]; then
      _ai_agent_step_header "$iteration" "$max_steps" "🔧 Tool" "$_resp"

      # Safe mode: confirm tool calls
      if [[ "$mode" == "safe" ]]; then
        echo -n -e "  ${COLOR_GREEN}Allow? [Y/n/skip]:${COLOR_RESET} "
        read -r confirm
        confirm=${confirm:-Y}
        if [[ "$confirm" =~ ^[Ss] ]]; then
          _ai_agent_save_checkpoint "$agentdir" "$iteration" "$_resp" "SKIPPED by user" "skipped"
          echo -e "  ${COLOR_YELLOW}⏭  Skipped${COLOR_RESET}"
          echo
          continue
        elif [[ ! "$confirm" =~ ^[Yy]$ ]]; then
          _ai_agent_save_checkpoint "$agentdir" "$iteration" "$_resp" "ABORTED by user" "aborted"
          echo
          echo -e "  ${COLOR_YELLOW}Agent paused.${COLOR_RESET} ${COLOR_DIM}Resume with:${COLOR_RESET} ${COLOR_CYAN}ai --agent --resume${COLOR_RESET}"
          echo
          return 1
        fi
      fi

      tool_output=$(_ai_agent_dispatch_tool "$_resp" 2>&1)
      tool_exit=$?

      _ai_agent_show_output "$tool_output" "$tool_exit"

      step_status="ok"
      [[ $tool_exit -ne 0 ]] && step_status="error"
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$_resp" "$tool_output" "$step_status"

    elif [[ "$_resp" == COMMAND:* ]]; then
      cmd="${_resp#COMMAND:}"
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"

      _ai_agent_step_header "$iteration" "$max_steps" "⚡ Run" "$cmd"

      _ai_agent_exec_cmd "$cmd" "$mode" "$agentdir" "$iteration"
      exec_result=$?
      if [[ $exec_result -eq 1 ]]; then
        echo
        echo -e "  ${COLOR_YELLOW}Agent paused.${COLOR_RESET} ${COLOR_DIM}Resume with:${COLOR_RESET} ${COLOR_CYAN}ai --agent --resume${COLOR_RESET}"
        echo
        return 1
      elif [[ $exec_result -eq 2 ]]; then
        continue
      fi

    else
      # Treat unrecognized responses as commands (LLM may omit COMMAND: prefix)
      cmd="$_resp"

      _ai_agent_step_header "$iteration" "$max_steps" "⚡ Run" "$cmd"

      _ai_agent_exec_cmd "$cmd" "$mode" "$agentdir" "$iteration"
      exec_result=$?
      if [[ $exec_result -eq 1 ]]; then
        echo
        echo -e "  ${COLOR_YELLOW}Agent paused.${COLOR_RESET} ${COLOR_DIM}Resume with:${COLOR_RESET} ${COLOR_CYAN}ai --agent --resume${COLOR_RESET}"
        echo
        return 1
      elif [[ $exec_result -eq 2 ]]; then
        continue
      fi
    fi
  done

    echo -e "${COLOR_DIM}──────────────────────────────────────────────────────────${COLOR_RESET}"
    echo
    echo -e "  ${COLOR_YELLOW}⚠️  Reached max steps ($max_steps) without completing goal.${COLOR_RESET}"
    echo -n -e "  ${COLOR_GREEN}Continue for another $max_steps steps? [Y/n]:${COLOR_RESET} "
    read -r confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      iteration=0
      echo
      echo -e "  ${COLOR_CYAN}↻ Continuing...${COLOR_RESET} ${COLOR_DIM}(total steps so far: $total_steps)${COLOR_RESET}"
      echo
    else
      echo
      echo -e "  ${COLOR_DIM}Stopped after $total_steps total step(s).${COLOR_RESET}"
      echo -e "  ${COLOR_DIM}💡 Resume with:${COLOR_RESET} ${COLOR_CYAN}ai --agent --resume${COLOR_RESET}"
      echo
      return 1
    fi
  done

  # This point is unreachable due to the infinite outer loop,
  # but kept for safety
  return 1
}

# ---- Confirmation + execution helper ----
_ai_confirm_and_run() {
  local cmd="$1"

  # Detect risky commands
  if echo "$cmd" | grep -Eq \
    '(^|\s)(sudo|rm|dd|mkfs|shred|find.*(rm|shred)|mv.*deleted|kubectl delete|terraform (apply|destroy)|gcloud delete)(\s|$)'; then
    echo -e "${COLOR_RED}⚠️  Risky command detected.${COLOR_RESET}"
    echo -n "Type YES to execute (Ctrl+C to abort): "
    read -r confirm
    if [[ "$confirm" != "YES" ]]; then
      echo -e "${COLOR_YELLOW}Aborted.${COLOR_RESET}"
      return 0
    fi
  else
    echo -n -e "${COLOR_GREEN}Execute this command? [Y/n]:${COLOR_RESET} "
    read -r confirm
    confirm=${confirm:-Y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo -e "${COLOR_YELLOW}Aborted.${COLOR_RESET}"
      return 0
    fi
  fi

  # Force color output for common commands
  if echo "$cmd" | grep -qE '^(ls|grep|diff|tree)'; then
    export CLICOLOR_FORCE=1
  fi
  
  eval "$cmd" 2>&1 | tee "/tmp/ai/last_output.txt"
  local exit_code
  if [[ -n "$ZSH_VERSION" ]]; then
    exit_code=${pipestatus[1]}
  else
    exit_code=${PIPESTATUS[0]}
  fi
  
  unset CLICOLOR_FORCE
  return $exit_code
}

# Re-export the function as 'ai' for convenience  
ai() { _ai "$@"; }

# ---- Zsh integration ----
if [[ -n "$ZSH_VERSION" ]]; then
  # Enable nonomatch so unmatched globs (like ?) are passed literally
  setopt nonomatch

  # ZLE widget: replace apostrophes in ai commands with Unicode equivalent (ʼ U+02BC)
  # Visually identical, but doesn't break shell parsing. History stays clean.
  _ai_accept_line() {
    if [[ "$BUFFER" =~ ^ai[[:space:]] && "$BUFFER" == *"'"* ]]; then
      BUFFER="${BUFFER//\'/ʼ}"
      CURSOR=${#BUFFER}
    fi
    zle .accept-line
  }
  zle -N accept-line _ai_accept_line
fi
