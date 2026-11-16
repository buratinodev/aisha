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
# the core) or AISHA_* environment variables. See `ai --help`.

# ============================================================================
# Installer bootstrap  (run as: ./aisha.sh --install | --uninstall)
# ============================================================================
# The real installer lives in the Python core (dependency checks, upgrades,
# rc-file management). The shim only bootstraps it — and only when this file
# is executed, never when sourced.

_aisha_executed=0
if [[ -n "$BASH_VERSION" && "${BASH_SOURCE[0]}" == "$0" ]]; then
  _aisha_executed=1
elif [[ -n "$ZSH_VERSION" ]]; then
  case "$ZSH_EVAL_CONTEXT" in *:file*) ;; *) _aisha_executed=1 ;; esac
fi

if [[ "$_aisha_executed" == 1 && ( "$1" == "--install" || "$1" == "--uninstall" ) ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required to install aisha." >&2
    exit 1
  fi
  _aisha_dir="$(cd "$(dirname "$0")" && pwd)"
  _aisha_core="$_aisha_dir/aisha_core.py"
  [[ -f "$_aisha_core" ]] || _aisha_core="$HOME/.aisha-core.py"
  if [[ ! -f "$_aisha_core" ]]; then
    echo "Error: aisha_core.py not found next to aisha.sh" >&2
    exit 1
  fi
  python3 "$_aisha_core" "$1" --shim "$_aisha_dir/$(basename "$0")"
  exit $?
fi
unset _aisha_executed

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

_AISHA_COMPLETIONS="redo rerun explain --config --selftest --tips --deep --agent --agent-safe -n --no-exec -c --refine --json -h --help --version --install --upgrade --uninstall"

if [[ -n "$ZSH_VERSION" ]]; then
  # Pass unmatched globs (?, *) literally instead of erroring
  setopt nonomatch

  # ZLE widget: replace contraction apostrophes (whatʼs, U+02BC — visually
  # identical) in ai commands so quote parsing isn't broken. Only apostrophes
  # between letters are touched, so quoted args like 'find x' are left alone.
  # Wraps any previously-installed accept-line widget instead of replacing
  # it, so plugins like zsh-autosuggestions keep working.
  _ai_accept_line() {
    if [[ "$BUFFER" =~ ^ai[[:space:]] && "$BUFFER" == *"'"* ]]; then
      setopt localoptions extendedglob
      # shellcheck disable=SC2154  # match is set by zsh (#b) backrefs
      BUFFER="${BUFFER//(#b)([a-zA-Z])\'([a-zA-Z])/${match[1]}ʼ${match[2]}}"
      # shellcheck disable=SC2034  # CURSOR is read by zle
      CURSOR=${#BUFFER}
    fi
    # Unset when re-sourced over a pre-0.5 aisha that used the same widget name
    zle "${_AISHA_ORIG_ACCEPT_LINE:-.accept-line}" -- "$@"
  }
  # shellcheck disable=SC2154  # widgets is zsh's widget registry
  case "${widgets[accept-line]:-builtin}" in
    user:_ai_accept_line) ;;  # already installed (re-sourced)
    user:*)
      zle -N _ai_orig_accept_line "${widgets[accept-line]#user:}"
      _AISHA_ORIG_ACCEPT_LINE="_ai_orig_accept_line"
      zle -N accept-line _ai_accept_line
      ;;
    *)
      _AISHA_ORIG_ACCEPT_LINE=".accept-line"
      zle -N accept-line _ai_accept_line
      ;;
  esac

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
