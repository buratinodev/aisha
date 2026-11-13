#!/usr/bin/env bash
# shellcheck shell=bash

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║  aisha — AI-Powered Shell Assistant (shell shim)                           ║
# ║  https://github.com/buratinodev/aisha                                      ║
# ╚════════════════════════════════════════════════════════════════════════════╝
#
# This file is a thin sourced shim. All logic lives in the Python core
# (aisha_core.py). The shim owns only the shell-integration surface — the
# things a child process cannot do:
#   - capture $? at ai() entry
#   - dump shell history (fc) for the core
#   - inject the suggested command into the input buffer (print -z / history -s)
#   - ZLE apostrophe widget, nonomatch, tab completion
#
# Configuration lives in ${XDG_CONFIG_HOME:-~/.config}/aisha/config (read by
# the core) or AISHA_* environment variables. See `ai /help`.

# ============================================================================
# Installer  (run as: ./aisha.sh --install)
# ============================================================================

if [[ "$1" == "--install" ]]; then
  user_shell=$(basename "$SHELL")

  if [[ "$user_shell" == "bash" ]]; then
    rc_file="$HOME/.bashrc"
  elif [[ "$user_shell" == "zsh" ]]; then
    rc_file="$HOME/.zshrc"
  else
    echo "Error: Unsupported shell '$user_shell'. Only bash and zsh are supported."
    exit 1
  fi

  script_dir="$(cd "$(dirname "$0")" && pwd)"
  if [[ ! -f "$script_dir/aisha_core.py" ]]; then
    echo "Error: aisha_core.py not found next to aisha.sh"
    exit 1
  fi
  cp "$script_dir/$(basename "$0")" "$HOME/.aisha"
  cp "$script_dir/aisha_core.py" "$HOME/.aisha-core.py"
  echo "✓ Copied aisha.sh to ~/.aisha and aisha_core.py to ~/.aisha-core.py"

  if grep -q "Load AI shell helpers" "$rc_file" 2>/dev/null; then
    echo "⚠ aisha is already configured in $rc_file"
  else
    {
      echo ""
      echo "# Load AI shell helpers"
      echo 'if [[ -f "$HOME/.aisha" ]]; then'
      echo '  source "$HOME/.aisha"'
      echo 'fi'
    } >> "$rc_file"
    echo "✓ Added aisha loader to $rc_file"
  fi

  echo ""
  echo "Installation complete!"
  echo "Run: source $rc_file (or open a new terminal window)"
  exit 0
fi

# ============================================================================
# Locate the Python core
# ============================================================================

if [[ -z "$AISHA_CORE" ]]; then
  if [[ -n "$ZSH_VERSION" ]]; then
    # %x expands to the file currently being sourced (hidden from bash's parser)
    eval '_aisha_src="${(%):-%x}"'
  else
    _aisha_src="${BASH_SOURCE[0]}"
  fi
  _aisha_dir="$(cd "$(dirname "$_aisha_src")" 2>/dev/null && pwd)"
  if [[ -f "$_aisha_dir/aisha_core.py" ]]; then
    AISHA_CORE="$_aisha_dir/aisha_core.py"
  elif [[ -f "$HOME/.aisha-core.py" ]]; then
    AISHA_CORE="$HOME/.aisha-core.py"
  fi
  unset _aisha_src _aisha_dir
fi

# ============================================================================
# Per-session state (XDG)
# ============================================================================

export AISHA_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/aisha"
export AISHA_SESSION_DIR="$AISHA_STATE_ROOT/session-$$"

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

# True when the current shell is interactive (a user is at the prompt).
_ai_shell_interactive() {
  if [[ -n "$ZSH_VERSION" ]]; then
    [[ -o interactive ]]
  else
    [[ $- == *i* ]]
  fi
}

# ============================================================================
# Entry point
# ============================================================================

ai() {
  # Capturing $? first, before any other command runs, is the only way to see
  # the exit code of the command the user ran before invoking ai.
  local _exit=$?

  if [[ -z "$AISHA_CORE" || ! -f "$AISHA_CORE" ]]; then
    echo "aisha: cannot find aisha_core.py (set AISHA_CORE to its path)" >&2
    return 1
  fi

  _ai_state_init
  fc -l -15 > "$AISHA_SESSION_DIR/last_context/history.txt" 2>/dev/null

  local _int=0
  _ai_shell_interactive && _int=1
  local _shell="bash"
  [[ -n "$ZSH_VERSION" ]] && _shell="zsh"
  rm -f "$AISHA_SESSION_DIR/inject.txt"

  AISHA_LAST_EXIT="$_exit" AISHA_INTERACTIVE="$_int" AISHA_SHELL="$_shell" \
    python3 "$AISHA_CORE" "$@"
  local _rc=$?

  # The core asks for buffer injection by writing inject.txt
  if [[ -s "$AISHA_SESSION_DIR/inject.txt" ]]; then
    local _cmd
    _cmd="$(cat "$AISHA_SESSION_DIR/inject.txt")"
    rm -f "$AISHA_SESSION_DIR/inject.txt"
    if [[ -n "$ZSH_VERSION" ]]; then
      print -rz -- "$_cmd"
      printf '  \033[2m↳ placed in your input line — edit if needed, Enter to run\033[0m\n\n'
    else
      history -s "$_cmd"
      printf '  \033[2m↳ press ↑ to edit and run\033[0m\n\n'
    fi
  fi
  return "$_rc"
}

# ============================================================================
# Shell integration  (zsh ZLE + completion, bash completion)
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
