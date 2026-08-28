# tj shell integration.
#
# Source this from ~/.zshrc:
#
#     source /path/to/tj.plugin.zsh
#
# Everything below is inert outside a tj journal writer, so loading it
# unconditionally is safe.
#
# Two jobs:
#
#   1. Mark command boundaries, because the proxy sees one undifferentiated
#      byte stream and cannot tell where one command ends and the next begins.
#   2. Turn journal references into paths, so ordinary programs can read them
#      without knowing tj exists.

[[ -n $TJ_JOURNAL ]] || return 0

autoload -Uz add-zsh-hook

_tj_bin() { print -r -- "${TJ:-tj}" }

# --- command boundaries -----------------------------------------------------

# Straight to the terminal, so the markers still work when a command's own
# output is redirected.
_tj_emit() {
  printf '\e]%s\e\\' "$1" > /dev/tty 2>/dev/null
}

_tj_encode() {
  # Base64 keeps arbitrary command lines - semicolons, newlines, escapes -
  # from colliding with the sequence framing.
  print -rn -- "${$(print -rn -- "$1" | base64)//$'\n'/}"
}

_tj_preexec() {
  # The journal records what was typed. $1 is the line after the accept-line
  # widget rewrote any references, so the widget stashes the original.
  local typed=${_TJ_TYPED:-$1}
  _TJ_TYPED=

  _tj_emit "5107;tj;cmd;$(_tj_encode "$typed")"
  # Only worth sending when expansion actually changed something.
  [[ $typed != $1 ]] && _tj_emit "5107;tj;expanded;$(_tj_encode "$1")"
  _tj_emit "133;C"

  (( _tj_count++ ))
  _tj_publish
}

# --- naming the command about to be typed -----------------------------------
#
# Exported rather than computed by the prompt, so showing any of this costs no
# process per prompt:
#
#   TJ_JOURNAL        the full journal id, exported by tj itself
#   TJ_JOURNAL_SHORT  the shortest suffix that names this journal
#   TJ_NEXT           the number the next command will get
#   TJ_REF            a reference to it that can be typed from anywhere
#
# tj computes the next unused number while holding the journal lock. Starting
# one behind keeps this counter aligned with the preexec event below, including
# after unfinished interactions and numbering gaps.
typeset -gi _tj_count=$(( TJ_NEXT - 1 ))

# Four characters of a ULID's random tail is plenty to tell a handful of
# journals apart. $TJ_JOURNAL holds the whole id when that is not enough.
export TJ_JOURNAL_SHORT=${TJ_JOURNAL: -4}

_tj_publish() {
  export TJ_NEXT=$(( _tj_count + 1 ))
  # Qualified by journal, so it still resolves from another pane.
  export TJ_REF="@${TJ_JOURNAL_SHORT}.${TJ_NEXT}"
}

_tj_publish

_tj_precmd() {
  # Must be the first thing read, before any command here disturbs it.
  # Not named `status`: that is a special parameter in zsh.
  local exit_code=$?
  _tj_emit "133;D;$exit_code"
  _tj_emit "133;A"
}

add-zsh-hook preexec _tj_preexec
add-zsh-hook precmd _tj_precmd

# --- the @ namespace --------------------------------------------------------

# Rewrites unquoted journal references in $1 into paths, leaving $_tj_expanded.
# Returns 0 only if something actually changed.
#
# A word is expanded only when it starts a shell word and begins with `@`, so
# `user@host` is untouched, and quoted text is copied through verbatim: the
# scan tracks quoting rather than pattern-matching the whole line.
_tj_expand() {
  local buf=$1 out='' word='' reference='' resolved ch
  local -i i=1 n=${#buf} at_word_start=1 changed=0

  while (( i <= n )); do
    ch=${buf[i]}
    case $ch in
      "'")
        out+=$ch; (( i++ ))
        while (( i <= n )) && [[ ${buf[i]} != "'" ]]; do out+=${buf[i]}; (( i++ )); done
        (( i <= n )) && { out+=${buf[i]}; (( i++ )) }
        at_word_start=0
        ;;
      '"')
        out+=$ch; (( i++ ))
        while (( i <= n )) && [[ ${buf[i]} != '"' ]]; do
          if [[ ${buf[i]} == '\' ]] && (( i < n )); then out+=${buf[i]}; (( i++ )); fi
          out+=${buf[i]}; (( i++ ))
        done
        (( i <= n )) && { out+=${buf[i]}; (( i++ )) }
        at_word_start=0
        ;;
      ' '|$'\t'|$'\n'|'|'|'&'|';'|'('|')'|'<'|'>')
        out+=$ch; (( i++ )); at_word_start=1
        ;;
      *)
        word=''
        while (( i <= n )); do
          if [[ ${buf[i]} == '\' ]] && (( i < n )); then
            word+=${buf[i]}; (( i++ ))
            word+=${buf[i]}; (( i++ ))
            continue
          fi
          case ${buf[i]} in
            (' '|$'\t'|$'\n'|'|'|'&'|';'|'('|')'|'<'|'>'|"'"|'"') break ;;
          esac
          word+=${buf[i]}; (( i++ ))
        done
        # Completion quotes special bytes with backslashes. Remove that one
        # lexical quoting layer before asking the shell-neutral resolver about
        # the reference; ${(Q)} does not evaluate the word as shell code.
        reference=${(Q)word}
        if (( at_word_start )) && [[ $reference == @* ]] &&
           resolved=$(command "$(_tj_bin)" resolve "$reference" 2>/dev/null); then
          # The resolver returns a filesystem path, not shell source. Quote it
          # with zsh's lexer so names containing spaces or metacharacters stay
          # one inert argument when the buffer is accepted.
          out+=${(q)resolved}
          changed=1
        else
          # Never drop a word: an unresolvable reference reaches the command
          # literally, and the command reports the error itself.
          out+=$word
        fi
        at_word_start=0
        ;;
    esac
  done

  _tj_expanded=$out
  return $(( ! changed ))
}

_tj_accept_line() {
  if [[ $BUFFER == *@* ]] && _tj_expand "$BUFFER"; then
    _TJ_TYPED=$BUFFER
    BUFFER=$_tj_expanded
  fi
  zle .accept-line
}

zle -N accept-line _tj_accept_line

# --- completion -------------------------------------------------------------

# The resolver knows what is on disk; this only formats what it prints.
_tj_completer() {
  [[ $PREFIX == @* ]] || return 1
  local -a candidates
  candidates=(${(f)"$(command "$(_tj_bin)" complete "$PREFIX" 2>/dev/null)"})
  (( ${#candidates} )) || return 1
  # Let zsh quote the match it inserts. `-Q` would turn a resource name into
  # active shell syntax when it contains a metacharacter.
  compadd -U -- $candidates
  return 0
}

# References can appear as an argument to any command, so this hooks the
# completer list rather than any one command's completion.
_tj_register_completion() {
  whence compdef > /dev/null 2>&1 || return 0
  local -a existing
  zstyle -a ':completion:*' completer existing
  (( ${#existing} )) || existing=(_complete _ignored)
  [[ ${existing[1]} == _tj_completer ]] && return 0
  zstyle ':completion:*' completer _tj_completer $existing
}

_tj_register_completion
