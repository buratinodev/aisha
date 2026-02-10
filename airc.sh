#!/usr/bin/env bash

# ---- Color definitions ----
COLOR_RED="\033[1;31m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[1;36m"
COLOR_RESET="\033[0m"

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
ai() {
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

    llm -m qwen2.5-coder:14b \
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
    llm -m qwen2.5-coder:14b \
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
    llm -m qwen2.5-coder:14b \
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
  response=$(llm -m qwen2.5-coder:14b \
    -f "$ctxdir/history.txt" \
    -f "$ctxdir/pwd.txt" \
    -f "$ctxdir/git.txt" \
    "$system_prompt

Suggest ONE safe shell command to accomplish:
'$prompt'

Rules:
- Never use rm -rf
- Avoid destructive commands
- Output ONLY the command.")

  # ---- Strip markdown code blocks ----
  response=$(echo "$response" | sed 's/^```[a-z]*//g' | sed 's/```$//g' | sed '/^$/d' | head -1)

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
