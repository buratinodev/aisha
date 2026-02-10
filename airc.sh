#!/usr/bin/env bash

# ---- Color definitions ----
COLOR_RED="\033[1;31m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[1;36m"
COLOR_RESET="\033[0m"

# ---- Model configuration ----
AI_MODEL="qwen2.5-coder:32b"
AI_AGENT_MAX_STEPS=15

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

    llm -m "$AI_MODEL" \
      -f "$ctxdir/history.txt" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      -f "$ctxdir/exit.txt" \
      "You are an expert sysadmin.
Explain why this command was suggested, what it does, and any risks.

Command:
$(cat "$tmpdir/last_command.txt")

Original intent:
$(cat "$tmpdir/last_prompt.txt")"
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

  # ---- Capture context ----
  history | tail -15 > "$ctxdir/history.txt"
  pwd > "$ctxdir/pwd.txt"
  git status --short 2>/dev/null > "$ctxdir/git.txt"

  local last_exit=$?
  echo "Last exit code: $last_exit" > "$ctxdir/exit.txt"

  # ---- Persona system prompt ----
  local system_prompt=""
  if [[ "$persona" == "deep" ]]; then
    system_prompt="You are a senior systems engineer.
Think step-by-step, consider edge cases, tradeoffs, and failure modes.
Prefer correctness over speed."
  else
    system_prompt="You are an expert Unix/Linux sysadmin.
Be concise, practical, and production-safe."
  fi

  # ---- Auto-fix failed command ----
  if [[ "$last_exit" -ne 0 && -z "$prompt" ]]; then
    llm -m "$AI_MODEL" \
      -f "$ctxdir/history.txt" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      -f "$ctxdir/exit.txt" \
      "$system_prompt

The user's last command failed.
Explain why it failed and suggest a fix.
Do not execute commands."
    return
  fi

  # ---- Explanation mode ----
  if [[ "$prompt" =~ ^(how|why|what|explain|help)(\s|$) ]]; then
    llm -m "$AI_MODEL" \
      -f "$ctxdir/history.txt" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      "$system_prompt

Explain and suggest, but do NOT give commands to execute.
User question: $prompt"
    return
  fi

  # ---- Command suggestion mode ----
  local response
  response=$(llm -m "$AI_MODEL" \
    -f "$ctxdir/history.txt" \
    -f "$ctxdir/pwd.txt" \
    -f "$ctxdir/git.txt" \
    "$system_prompt

User request: '$prompt'

Rules:
- If the request is a shell/system task, output ONLY the command (no explanation)
- If the request is conversational or informational (like greetings, questions about concepts), prefix your response with 'ANSWER:' followed by a brief answer
- Never use rm -rf
- Avoid destructive commands")

  # ---- Strip markdown code blocks and trim whitespace ----
  response=$(echo "$response" | sed 's/^```[a-z]*//g' | sed 's/```$//g' | sed '/^$/d' | head -1)
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
  echo "$prompt" > "$tmpdir/last_prompt.txt"
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

  # Parse TOOL:<name>(<args>) format
  if [[ "$tool_call" =~ ^TOOL:([a-z_]+)\((.+)\)$ ]]; then
    tool_name="${BASH_REMATCH[1]}"
    tool_args="${BASH_REMATCH[2]}"
    # zsh uses match array
    if [[ -n "$ZSH_VERSION" ]]; then
      tool_name="${match[1]}"
      tool_args="${match[2]}"
    fi
  else
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
  local status="$5"

  local cpdir="$agentdir/checkpoints"
  mkdir -p "$cpdir"

  cat > "$cpdir/step_${step}.json" <<EOF
{
  "step": $step,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pwd": "$(pwd)",
  "action": $(echo "$cmd" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo "\"$cmd\""),
  "status": "$status",
  "output_file": "step_${step}_output.txt"
}
EOF
  echo "$output" > "$cpdir/step_${step}_output.txt"

  # Save cumulative log
  echo "[$step] ($status) $cmd" >> "$agentdir/agent_log.txt"
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
  local cpdir="$agentdir/checkpoints"
  local history=""

  if [[ ! -d "$cpdir" ]]; then
    echo ""
    return
  fi

  for f in $(ls "$cpdir"/step_*.json 2>/dev/null | sort -V); do
    local step_num
    step_num=$(basename "$f" | sed 's/step_//;s/\.json//')
    local action
    action=$(grep '"action"' "$f" | sed 's/.*"action": *"//;s/",*//')
    local status
    status=$(grep '"status"' "$f" | sed 's/.*"status": *"//;s/".*//')
    local output=""
    [[ -f "$cpdir/step_${step_num}_output.txt" ]] && output=$(head -20 "$cpdir/step_${step_num}_output.txt")

    history+="
--- Step $step_num ($status) ---
Action: $action
Output (first 20 lines):
$output
"
  done
  echo "$history"
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
    echo -e "${COLOR_CYAN}🔄 Resuming agent session: $goal${COLOR_RESET}"
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
    echo -e "${COLOR_CYAN}Resuming from step $start_step${COLOR_RESET}"
  fi

  echo
  echo -e "${COLOR_CYAN}🤖 Agent mode ($mode): $goal${COLOR_RESET}"
  echo -e "${COLOR_CYAN}   Max steps: $max_steps | Tools: $AI_AGENT_TOOLS${COLOR_RESET}"
  echo

  # Capture initial context
  local ctxdir="/tmp/ai/last_context"
  history | tail -15 > "$ctxdir/history.txt"
  pwd > "$ctxdir/pwd.txt"
  git status --short 2>/dev/null > "$ctxdir/git.txt"

  local iteration=$start_step
  while [[ $iteration -lt $max_steps ]]; do
    ((iteration++))

    # Build agent history from checkpoints
    local agent_history
    agent_history=$(_ai_agent_get_history "$agentdir")

    # Ask LLM for next action
    local agent_response
    agent_response=$(llm -m "$AI_MODEL" \
      -f "$ctxdir/pwd.txt" \
      -f "$ctxdir/git.txt" \
      "You are an autonomous shell agent working toward a goal.

GOAL: $goal

STEP: $iteration of $max_steps

PREVIOUS STEPS:
$agent_history

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

    # Trim response
    agent_response=$(echo "$agent_response" | sed 's/^```[a-z]*//g' | sed 's/```$//g' | sed '/^$/d' | head -1)
    agent_response="${agent_response#"${agent_response%%[![:space:]]*}"}"
    agent_response="${agent_response%"${agent_response##*[![:space:]]}"}"

    # ---- Parse response ----
    if [[ "$agent_response" == DONE:* ]]; then
      local summary="${agent_response#DONE:}"
      summary="${summary#"${summary%%[![:space:]]*}"}"
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "DONE" "$summary" "done"
      echo
      echo -e "${COLOR_GREEN}✅ Goal achieved in $iteration steps!${COLOR_RESET}"
      echo -e "${COLOR_CYAN}$summary${COLOR_RESET}"
      echo
      echo -e "Checkpoint log: ${COLOR_YELLOW}$agentdir/agent_log.txt${COLOR_RESET}"
      return 0

    elif [[ "$agent_response" == FAILED:* ]]; then
      local reason="${agent_response#FAILED:}"
      reason="${reason#"${reason%%[![:space:]]*}"}"
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "FAILED" "$reason" "failed"
      echo
      echo -e "${COLOR_RED}❌ Agent failed at step $iteration${COLOR_RESET}"
      echo -e "${COLOR_YELLOW}$reason${COLOR_RESET}"
      echo
      echo -e "Resume with: ${COLOR_YELLOW}ai --agent --resume${COLOR_RESET}"
      return 1

    elif [[ "$agent_response" == TOOL:* ]]; then
      echo -e "${COLOR_CYAN}[$iteration/$max_steps]${COLOR_RESET} ${COLOR_YELLOW}$agent_response${COLOR_RESET}"

      # Safe mode: confirm tool calls
      if [[ "$mode" == "safe" ]]; then
        echo -n -e "${COLOR_GREEN}Allow this tool call? [Y/n/skip]:${COLOR_RESET} "
        read -r confirm
        confirm=${confirm:-Y}
        if [[ "$confirm" =~ ^[Ss] ]]; then
          _ai_agent_save_checkpoint "$agentdir" "$iteration" "$agent_response" "SKIPPED by user" "skipped"
          echo -e "${COLOR_YELLOW}Skipped.${COLOR_RESET}"
          continue
        elif [[ ! "$confirm" =~ ^[Yy]$ ]]; then
          _ai_agent_save_checkpoint "$agentdir" "$iteration" "$agent_response" "ABORTED by user" "aborted"
          echo -e "${COLOR_YELLOW}Agent aborted. Resume with: ai --agent --resume${COLOR_RESET}"
          return 1
        fi
      fi

      local tool_output
      tool_output=$(_ai_agent_dispatch_tool "$agent_response" 2>&1)
      local tool_exit=$?

      echo "$tool_output" | head -10
      [[ $(echo "$tool_output" | wc -l) -gt 10 ]] && echo -e "${COLOR_YELLOW}... (output truncated)${COLOR_RESET}"
      echo

      local status="ok"
      [[ $tool_exit -ne 0 ]] && status="error"
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$agent_response" "$tool_output" "$status"

    elif [[ "$agent_response" == COMMAND:* ]]; then
      local cmd="${agent_response#COMMAND:}"
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"

      echo -e "${COLOR_CYAN}[$iteration/$max_steps]${COLOR_RESET} ${COLOR_YELLOW}$cmd${COLOR_RESET}"

      # Safety check for risky commands (always confirm, regardless of mode)
      local is_risky=false
      if echo "$cmd" | grep -Eq \
        '(^|\s)(sudo|rm|dd|mkfs|shred|find.*(rm|shred)|mv.*deleted|kubectl delete|terraform (apply|destroy)|gcloud delete)(\s|$)'; then
        is_risky=true
      fi

      if $is_risky; then
        echo -e "${COLOR_RED}⚠️  Risky command detected.${COLOR_RESET}"
        echo -n "Type YES to execute, or 'skip' to skip: "
        read -r confirm
        if [[ "$confirm" == "skip" ]]; then
          _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "SKIPPED by user (risky)" "skipped"
          echo -e "${COLOR_YELLOW}Skipped.${COLOR_RESET}"
          continue
        elif [[ "$confirm" != "YES" ]]; then
          _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "ABORTED by user (risky)" "aborted"
          echo -e "${COLOR_YELLOW}Agent aborted. Resume with: ai --agent --resume${COLOR_RESET}"
          return 1
        fi
      elif [[ "$mode" == "safe" ]]; then
        echo -n -e "${COLOR_GREEN}Execute? [Y/n/skip]:${COLOR_RESET} "
        read -r confirm
        confirm=${confirm:-Y}
        if [[ "$confirm" =~ ^[Ss] ]]; then
          _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "SKIPPED by user" "skipped"
          echo -e "${COLOR_YELLOW}Skipped.${COLOR_RESET}"
          continue
        elif [[ ! "$confirm" =~ ^[Yy]$ ]]; then
          _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "ABORTED by user" "aborted"
          echo -e "${COLOR_YELLOW}Agent aborted. Resume with: ai --agent --resume${COLOR_RESET}"
          return 1
        fi
      fi

      # Execute
      local cmd_output
      cmd_output=$(eval "$cmd" 2>&1)
      local cmd_exit=$?

      echo "$cmd_output" | head -10
      [[ $(echo "$cmd_output" | wc -l) -gt 10 ]] && echo -e "${COLOR_YELLOW}... (output truncated)${COLOR_RESET}"
      echo

      local status="ok"
      [[ $cmd_exit -ne 0 ]] && status="error"
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "$cmd" "$cmd_output" "$status"

    else
      echo -e "${COLOR_RED}Unexpected response: $agent_response${COLOR_RESET}"
      _ai_agent_save_checkpoint "$agentdir" "$iteration" "UNEXPECTED" "$agent_response" "error"
    fi
  done

  echo
  echo -e "${COLOR_YELLOW}⚠️  Max steps ($max_steps) reached without completing goal.${COLOR_RESET}"
  echo -e "Resume with: ${COLOR_YELLOW}ai --agent --resume${COLOR_RESET}"
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

# Enable nonomatch in zsh so unmatched globs (like ?) are passed literally
if [[ -n "$ZSH_VERSION" ]]; then
  setopt nonomatch
fi
