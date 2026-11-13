#!/usr/bin/env bats
# Tests for aisha.sh. The `llm` CLI is stubbed via tests/stubs/llm, which
# echoes $AISHA_TEST_LLM_RESPONSE and logs its argv to $AISHA_TEST_LLM_LOG.

setup() {
  TEST_TMP="$(mktemp -d)"
  export HOME="$TEST_TMP/home"
  export XDG_STATE_HOME="$TEST_TMP/state"
  mkdir -p "$HOME"

  export AISHA_SH="$BATS_TEST_DIRNAME/../aisha.sh"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export AISHA_TEST_LLM_LOG="$TEST_TMP/llm.log"
  export AISHA_MODEL_TASK="task-model"
  export AISHA_MODEL_THINKING="think-model"

  # Run outside any git repo so git-status context is the "no repo" case
  cd "$TEST_TMP"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---- _ai_strip_response ----------------------------------------------------

@test "strip_response removes single-line think block" {
  run bash -c 'source "$AISHA_SH"; _ai_strip_response "<think>hmm</think>ls -la"'
  [ "$status" -eq 0 ]
  [ "$output" = "ls -la" ]
}

@test "strip_response removes multi-line think block and code fences" {
  run bash -c 'source "$AISHA_SH"; _ai_strip_response "$(printf "<think>\nreasoning\n</think>\n\`\`\`bash\nls -la\n\`\`\`\n")"'
  [ "$status" -eq 0 ]
  [ "$output" = "ls -la" ]
}

@test "strip_response trims whitespace and takes first meaningful line" {
  run bash -c 'source "$AISHA_SH"; _ai_strip_response "$(printf "\n\n   df -h   \nsecond line\n")"'
  [ "$status" -eq 0 ]
  [ "$output" = "df -h" ]
}

# ---- risky-command detection -----------------------------------------------

@test "risky regex matches sudo, rm, terraform apply, kubectl delete" {
  for cmd in "sudo apt install x" "rm file.txt" "terraform apply" "kubectl delete pod web"; do
    bash -c 'source "$AISHA_SH"; echo "$1" | grep -Eq "$_AISHA_RISKY_RE"' _ "$cmd" \
      || { echo "expected risky: $cmd"; return 1; }
  done
}

@test "risky regex does not match everyday commands" {
  for cmd in "ls -la" "git status" "grep -r foo ." "df -h"; do
    if bash -c 'source "$AISHA_SH"; echo "$1" | grep -Eq "$_AISHA_RISKY_RE"' _ "$cmd"; then
      echo "false positive: $cmd"; return 1
    fi
  done
}

# ---- subcommand routing ----------------------------------------------------

@test "ai redo with no prior suggestion reports an error" {
  run bash -c 'source "$AISHA_SH"; ai redo'
  [ "$status" -eq 1 ]
  [[ "$output" == *"No previous AI suggestion"* ]]
}

@test "ai explain (bare) with no prior suggestion reports an error" {
  run bash -c 'source "$AISHA_SH"; ai explain'
  [ "$status" -eq 1 ]
  [[ "$output" == *"No previous AI suggestion"* ]]
}

@test "ai explain <question> is answered, not treated as the explain subcommand" {
  export AISHA_TEST_LLM_RESPONSE="cron runs scheduled jobs"
  run bash -c 'source "$AISHA_SH"; ai explain what cron does'
  [ "$status" -eq 0 ]
  [[ "$output" != *"No previous AI suggestion"* ]]
  [[ "$output" == *"cron runs scheduled jobs"* ]]
}

# ---- auto-fix trigger (last exit code capture) -------------------------------

@test "bare ai after a failing command triggers auto-fix with the thinking model" {
  export AISHA_TEST_LLM_RESPONSE="diagnosis: command not found"
  run bash -c 'source "$AISHA_SH"; false; ai'
  [ "$status" -eq 0 ]
  [[ "$output" == *"diagnosis: command not found"* ]]
  grep -q "think-model" "$AISHA_TEST_LLM_LOG"
}

@test "bare ai after a successful command falls back to the Ask prompt" {
  run bash -c 'source "$AISHA_SH"; true; ai < /dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ask:"* ]]
}

@test "auto-fix does not fire outside a git repo when last command succeeded" {
  # Regression: last_exit used to capture git-status's exit code (128 outside
  # a repo), so bare ai always entered auto-fix mode in non-repo directories.
  run bash -c 'source "$AISHA_SH"; true; ai < /dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" != *"failed"* ]]
}

# ---- suggestion flow ---------------------------------------------------------

@test "suggestion flow: shows command, uses task model, aborts on n" {
  export AISHA_TEST_LLM_RESPONSE="ls -la"
  run bash -c 'source "$AISHA_SH"; printf "n\n" | ai list all files'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Suggested command"* ]]
  [[ "$output" == *"ls -la"* ]]
  [[ "$output" == *"Aborted"* ]]
  grep -q "task-model" "$AISHA_TEST_LLM_LOG"
}

@test "risky suggestion requires YES and aborts otherwise" {
  export AISHA_TEST_LLM_RESPONSE="rm old.txt"
  run bash -c 'source "$AISHA_SH"; printf "no\n" | ai delete the old file'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Risky command detected"* ]]
  [[ "$output" == *"Aborted"* ]]
}

@test "suggestion is saved to the session state dir (latest symlink)" {
  export AISHA_TEST_LLM_RESPONSE="ls -la"
  bash -c 'source "$AISHA_SH"; printf "n\n" | ai list all files' > /dev/null
  [ -L "$XDG_STATE_HOME/aisha/latest" ]
  [ -f "$XDG_STATE_HOME/aisha/latest/last_command.txt" ]
  [ "$(cat "$XDG_STATE_HOME/aisha/latest/last_command.txt")" = "ls -la" ]
}

# ---- ANSWER: path ------------------------------------------------------------

@test "ANSWER: responses are shown directly without a confirm prompt" {
  export AISHA_TEST_LLM_RESPONSE="ANSWER: doing great, thanks"
  run bash -c 'source "$AISHA_SH"; ai hows it going'
  [ "$status" -eq 0 ]
  [[ "$output" == *"doing great, thanks"* ]]
  [[ "$output" != *"Execute this command"* ]]
}

# ---- markdown renderer -------------------------------------------------------

@test "render_markdown renders headings, bullets and strips think blocks" {
  run bash -c 'source "$AISHA_SH"; printf "<think>secret</think>\n# Title\n- first bullet\n" | _ai_render_markdown'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Title"* ]]
  [[ "$output" == *"first bullet"* ]]
  [[ "$output" != *"secret"* ]]
}
