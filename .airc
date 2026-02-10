# ---- AI helper (llm wrapper with memory + risk confirmation) ----
ai() {
  local tmpdir="/tmp/ai"
  local ctxdir="$tmpdir/last_context"
  mkdir -p "$tmpdir" "$ctxdir"

  local persona="sysadmin"

  # ---- Special commands ----
  if [[ "$1" == "redo" ]]; then
    if [[ ! -f "$tmpdir/last_command.txt" ]]; then
      echo "No previous AI suggestion to redo."
      return 1
    fi

    local cmd
    cmd=$(cat "$tmpdir/last_command.txt")

    echo "Redoing last suggested command:"
    echo "  $cmd"
    echo

    _ai_confirm_and_run "$cmd"
    return $?
  fi

  if [[ "$1" == "explain" ]]; then
    if [[ ! -f "$tmpdir/last_command.txt" ]]; then
      echo "No previous AI suggestion to explain."
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
  if [[ "$prompt" =~ ^(how|why|what|explain|help)\  ]]; then
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

  # ---- Hard block rm -rf ----
  if echo "$response" | grep -Eq 'rm\s+-rf'; then
    echo "❌ Blocked unsafe command: rm -rf"
    return 1
  fi

  # ---- Persist memory ----
  echo "$response" > "$tmpdir/last_command.txt"
  echo "$prompt" > "$tmpdir/last_prompt.txt"
  echo "$persona" > "$tmpdir/last_persona.txt"

  echo
  echo "Suggested command:"
  echo "  $response"
  echo

  _ai_confirm_and_run "$response"
}

# ---- Confirmation + execution helper ----
_ai_confirm_and_run() {
  local cmd="$1"

  # Detect risky commands
  if echo "$cmd" | grep -Eq \
    '(^|\s)(sudo|rm|dd|mkfs|kubectl delete|terraform (apply|destroy)|gcloud delete)(\s|$)'; then
    echo "⚠️  Risky command detected."
    read "?Type YES to execute: " confirm
    if [[ "$confirm" != "YES" ]]; then
      echo "Aborted."
      return 0
    fi
  else
    read "?Execute this command? [Y/n]: " confirm
    confirm=${confirm:-Y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      return 0
    fi
  fi

  eval "$cmd" 2>&1 | tee "/tmp/ai/last_output.txt"
  local exit_code
  if [[ -n "$ZSH_VERSION" ]]; then
    exit_code=${pipestatus[1]}
  else
    exit_code=${PIPESTATUS[0]}
  fi
  return $exit_code
}
