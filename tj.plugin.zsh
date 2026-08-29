# tj shell integration.
#
# Source this from ~/.zshrc:
#
#     source /path/to/tj.plugin.zsh
#
# Recording and reference expansion are inert outside a tj journal writer.
# `tjcd` remains available so qualified references can be used from an
# ordinary shell.
#
# Two jobs:
#
#   1. Mark command boundaries, because the proxy sees one undifferentiated
#      byte stream and cannot tell where one command ends and the next begins.
#   2. Give journal references a zsh dynamic named-directory namespace, so
#      ordinary programs receive paths without exposing them in command lines.

_tj_bin() { print -r -- "${TJ:-tj}" }

# Change the calling zsh process to the directory in which an entry ran. This
# must be a shell function: an external process cannot change its parent's cwd.
tjcd() {
  emulate -L zsh

  if (( $# != 1 )); then
    print -ru2 -- 'usage: tjcd @ref'
    return 2
  fi

  local entry destination=''
  entry=$(command "$(_tj_bin)" resolve "$1") || return
  if [[ ! -f $entry/cwd ]]; then
    print -ru2 -- 'tjcd: entry has no recorded cwd'
    return 1
  fi

  # A NUL cannot occur in a filesystem path. Reading to NUL therefore keeps
  # every byte through EOF, including whitespace and trailing newlines.
  IFS= read -r -d '' destination < "$entry/cwd" 2>/dev/null || true
  if [[ $destination != /* ]]; then
    print -ru2 -- 'tjcd: recorded cwd is not an absolute path'
    return 1
  fi
  if [[ ! -d $destination ]]; then
    print -ru2 -- "tjcd: recorded directory no longer exists: $destination"
    return 1
  fi
  builtin cd -- "$destination"
}

[[ -n $TJ_JOURNAL ]] || return 0

autoload -Uz add-zsh-hook

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
  # The journal records what was typed. $1 is the canonical line after the
  # accept-line widget rewrote shorthand, so the widget stashes the original.
  local typed=${_TJ_TYPED:-$1}
  _TJ_TYPED=

  _tj_emit "5107;tj;cmd;$(_tj_encode "$typed")"
  _tj_emit "5107;tj;cwd;$(_tj_encode "$PWD")"
  # preexec runs before filename expansion. $3 is the full executable form
  # (including aliases), but still contains dynamic named directories, so
  # resolve only those known tokens for diagnostic metadata.
  if _tj_expand_canonical_for_metadata "$3"; then
    _tj_emit "5107;tj;expanded;$(_tj_encode "$_tj_expanded")"
  fi
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

# zsh has rendered PROMPT and RPROMPT by the time it starts ZLE. Mark that
# boundary without modifying or re-expanding either prompt, so dynamic prompt
# engines such as Starship are captured exactly once as terminal bytes.
_tj_prompt_end() {
  _tj_emit "133;B"
}

# This helper preserves any existing zle-line-init widget, maintains an
# ordered hook list, and ignores duplicate registration when the plugin is
# sourced again.
autoload -Uz add-zle-hook-widget
add-zle-hook-widget zle-line-init _tj_prompt_end

# --- the journal namespace --------------------------------------------------

# Whether $1 is exactly a syntactically valid interaction-reference head. The
# resource suffix is deliberately not part of this check: ~[@10] names the
# interaction directory and zsh owns whatever filesystem path follows it.
_tj_valid_reference_head() {
  emulate -L zsh
  setopt extendedglob

  local head=$1 body qualifier target significant
  [[ $head == @- ]] && return 0
  [[ $head == @?* ]] || return 1
  body=${head#@}

  if [[ $body == *.* ]]; then
    qualifier=${body%.*}
    target=${body##*.}
    [[ $qualifier == [A-Za-z0-9]## && ${#qualifier} -le 26 ]] || return 1
  else
    target=$body
  fi

  if [[ $target == [0-9]## ]]; then
    significant=${target##0#}
    [[ -n $significant ]] || return 1
    (( ${#significant} < 10 )) && return 0
    (( ${#significant} == 10 )) || return 1
    [[ $significant == 4294967295 || $significant < 4294967295 ]]
    return
  fi

  # Interaction names are deliberately conservative and disjoint from
  # numbers. Zig remains authoritative; this mirror only decides whether a
  # shell word is worth asking `tj resolve` about.
  (( ${#target} >= 1 && ${#target} <= 63 )) || return 1
  [[ $target == [a-z]* && $target == [a-z0-9-]## && $target != *- ]]
}

_tj_reference_head_is_name() {
  local body=${1#@} target
  target=${body##*.}
  [[ $target != [0-9]## && $target != - ]]
}

# `tjcd` consumes an entry reference as data rather than as a filesystem
# argument. Keep its one literal target out of the dynamic-directory rewrite
# so the terminal and zsh history retain `tjcd @42`.
_tj_is_literal_tjcd() {
  emulate -L zsh
  setopt extendedglob

  local line=${1##[[:space:]]#} target
  line=${line%%[[:space:]]#}
  [[ $line == tjcd[[:space:]]##* ]] || return 1
  target=${line#tjcd}
  target=${target##[[:space:]]#}
  [[ -n $target && $target != *[[:space:]]* ]] || return 1
  _tj_valid_reference_head "$target"
}

# Rewrites valid unquoted shorthand in $1 into canonical ~[...] notation,
# leaving $_tj_expanded. Returns 0 only if something actually changed.
#
# A reference is canonicalized only when it starts a shell word, so user@host
# is untouched. Quoted text is copied through verbatim: the scan tracks quoting
# rather than pattern-matching the whole line.
_tj_canonicalize_shorthand() {
  emulate -L zsh

  local buf=$1 out='' word='' head='' suffix='' ch
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
        head=${word%%/*}
        suffix=${word#$head}
        if (( at_word_start )) && [[ $head == @* ]] &&
           _tj_valid_reference_head "$head"; then
          if ! _tj_reference_head_is_name "$head" ||
             command "$(_tj_bin)" resolve "$head" >/dev/null 2>&1; then
            out+="~[$head]$suffix"
            changed=1
          else
            # Unassigned names stay literal for commands that use @handles.
            out+=$word
          fi
        else
          # Never drop a word: malformed shorthand reaches the command
          # literally. A well-formed but missing name is rejected later by zsh.
          out+=$word
        fi
        at_word_start=0
        ;;
    esac
  done

  _tj_expanded=$out
  return $(( ! changed ))
}

# Resolves canonical TJ named-directory tokens in $1 for metadata only. This
# does not mutate BUFFER and never evaluates the command line. The suffix stays
# as shell text; only TJ's known directory component becomes a quoted path.
_tj_expand_canonical_for_metadata() {
  emulate -L zsh

  local buf=$1 out='' word='' head='' suffix='' resolved='' ch
  local -i i=1 n=${#buf} at_word_start=1 changed=0 close

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

        close=0
        if (( at_word_start )) && [[ ${word[1,2]} == '~[' ]]; then
          local -i j=3
          while (( j <= ${#word} )); do
            if [[ ${word[j]} == ']' ]]; then close=$j; break; fi
            (( j++ ))
          done
        fi

        if (( close > 3 )); then
          head=${word[3,close-1]}
          suffix=${word[close+1,-1]}
          if _tj_valid_reference_head "$head" &&
             resolved=$(command "$(_tj_bin)" resolve "$head" 2>/dev/null); then
            out+=${(q)resolved}$suffix
            changed=1
          else
            out+=$word
          fi
        else
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
  if ! _tj_is_literal_tjcd "$BUFFER" &&
     [[ $BUFFER == *@* ]] && _tj_canonicalize_shorthand "$BUFFER"; then
    _TJ_TYPED=$BUFFER
    BUFFER=$_tj_expanded
    zle redisplay
  fi
  zle _tj_accept_line_next -- "$@"
}

_tj_register_accept_line() {
  # Preserve the widget that was active when TJ was first sourced. The global
  # guard matters when a plugin manager reloads this file: replacing the saved
  # alias with TJ's own wrapper would make accept-line recurse forever.
  (( ${+_TJ_ACCEPT_LINE_REGISTERED} )) && return 0
  zle -A accept-line _tj_accept_line_next || return 1
  zle -N accept-line _tj_accept_line || return 1
  typeset -g _TJ_ACCEPT_LINE_REGISTERED=1
}

_tj_register_accept_line

# --- dynamic named directories ---------------------------------------------

_tj_directory_name() {
  emulate -L zsh

  case $1 in
    n)
      [[ $2 == @* ]] || return 1
      local resolved
      resolved=$(command "$(_tj_bin)" resolve "$2" 2>/dev/null) || return 1
      typeset -ga reply
      reply=("$resolved")
      ;;
    c)
      [[ $PREFIX == @* ]] || return 1
      local -a candidates
      candidates=(${(f)"$(command "$(_tj_bin)" complete "$PREFIX" 2>/dev/null)"})
      (( ${#candidates} )) || return 1
      _wanted dynamic-dirs expl 'tj journal reference' compadd -U -S\] -a candidates
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

_tj_register_directory_name() {
  typeset -ga zsh_directory_name_functions
  local handler
  for handler in "${zsh_directory_name_functions[@]}"; do
    [[ $handler == _tj_directory_name ]] && return 0
  done
  zsh_directory_name_functions+=(_tj_directory_name)
}

_tj_register_directory_name

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
  local -a existing updated
  local completer
  local -i inserted=0
  zstyle -a ':completion:*' completer existing
  (( ${#existing} )) || existing=(_complete _ignored)
  for completer in "${existing[@]}"; do
    [[ $completer == _tj_completer ]] && return 0
  done

  # Let zsh's native completion handle ~[...] and ordinary paths first. TJ's
  # shorthand is a fallback immediately after _complete, before _ignored or
  # any later policy the user configured.
  for completer in "${existing[@]}"; do
    updated+=("$completer")
    if (( ! inserted )) && [[ $completer == _complete ]]; then
      updated+=(_tj_completer)
      inserted=1
    fi
  done
  (( inserted )) || updated=(_tj_completer "${updated[@]}")
  zstyle ':completion:*' completer $updated
}

_tj_register_completion
