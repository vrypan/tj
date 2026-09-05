# tj shell integration.
#
# Source this from ~/.zshrc:
#
#     source /path/to/tj.plugin.zsh
#
# Recording and reference completion are inert outside a tj journal writer.
# `tjcd` remains available so qualified references can be used from an
# ordinary shell.
#
# Three jobs:
#
#   1. Mark command boundaries, because the proxy sees one undifferentiated
#      byte stream and cannot tell where one command ends and the next begins.
#   2. Turn accepted bare references into quoted path expressions.
#   3. Open the journal browser from ZLE and insert a chosen detail value into
#      the command line.

_tj_bin() { print -r -- "${TJ:-tj}" }
_tjctl_bin() { print -r -- "${TJCTL:-tjctl}" }

# The generated command completers are installed beside this plugin under
# `share/zsh/site-functions`. Make them discoverable whether the plugin is
# sourced before or after the user's `compinit` call. A source checkout has no
# such sibling directory, so it remains convenient for development too.
typeset -g _TJ_PLUGIN_PATH=${${(%):-%N}:A}
_tj_register_command_completions() {
  emulate -L zsh
  local completion_dir=${_TJ_PLUGIN_PATH:h:h}/zsh/site-functions
  [[ -r $completion_dir/_tjctl ]] || return 0
  (( ${fpath[(Ie)$completion_dir]} )) || fpath=($completion_dir $fpath)

  # `compinit` has already defined compdef in configurations that load this
  # plugin late. Register now in that case; otherwise compinit finds the
  # directory above when it runs later.
  (( ${+functions[compdef]} )) || return 0
  autoload -Uz _tj _tjctl
  compdef _tj tj
  compdef _tjctl tjctl
}
_tj_register_command_completions

# These are the interactive journal lifecycle commands. Outside a writer they
# are ordinary wrappers around tjctl. Inside one they retain this zsh process,
# ask the proxy to change its recorder, then apply the confirmed journal state.
_tj_handoff() {
  emulate -L zsh
  local operation=$1
  shift
  if [[ -z ${TJ_JOURNAL:-} ]]; then
    command "$(_tjctl_bin)" "$operation" "$@"
    return
  fi
  local setup
  setup=$(TJ_SHELL_HANDOFF=1 command "$(_tjctl_bin)" "$operation" "$@") || return
  builtin eval -- "$setup"
  typeset -gi _tj_count=$(( TJ_NEXT - 1 ))
  _tj_publish
  _tj_update_title
}

tj-new() { _tj_handoff new "$@" }
tj-use() { _tj_handoff use "$@" }

# Change the calling zsh process to the directory in which an entry ran. This
# must be a shell function: an external process cannot change its parent's cwd.
tjcd() {
  emulate -L zsh

  if (( $# != 1 )); then
    print -ru2 -- 'usage: tjcd @ref'
    return 2
  fi

  local entry destination=''
  # `tjcd` keeps its reference literal even in a compound command. It consumes
  # the reference as data rather than passing a filesystem path to a program.
  if [[ -d $1 ]]; then
    entry=$1
  else
    entry=$(command "$(_tj_bin)" resolve "$1") || return
  fi
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

_tj_encode_context() {
  emulate -L zsh
  unsetopt multibyte
  # One encoded payload keeps cmd, cwd, and optional expanded text from
  # colliding with the OSC framing without starting base64 for each field.
  # Byte lengths make arbitrary command text unambiguous; disabling multibyte
  # locally makes zsh's lengths match the decoded byte slices in Zig.
  local header="1;${#1};${#2};${3};${#4};"
  print -rn -- "${$(print -rn -- "${header}${1}${2}${4}" | base64)//$'\n'/}"
}

_tj_preexec() {
  # The journal records the line the user entered, before accept-line expands
  # an explicit bare reference into a command substitution.
  local typed=${_TJ_TYPED:-$1}
  _TJ_TYPED=

  # Match the terminal convention: the configured format describes the idle
  # prompt, while a running command gets a short, immediately useful title.
  # Programs remain free to replace this with a more specific title.
  _tj_update_running_title "$typed"

  local expanded='' expanded_flag=0
  # $3 includes alias expansion. Command substitutions deliberately remain
  # visible here: their result is an implementation detail, not command text.
  if [[ $3 != "$typed" ]]; then
    expanded=$3
    expanded_flag=1
  fi
  _tj_emit "3110;CONTEXT;$(_tj_encode_context "$typed" "$PWD" "$expanded_flag" "$expanded")"
  _tj_emit "133;C"

  (( _tj_count++ ))
  _tj_publish
}

# --- naming the command about to be typed -----------------------------------
#
# Exported rather than computed by the prompt, so showing any of this costs no
# process per prompt:
#
#   TJ_JOURNAL        the full journal id, exported by tjctl
#   TJ_NEXT           the number the next command will get
#   TJ_REF            a reference to it that can be typed from anywhere
#
# tjctl computes the next unused number while holding the journal lock. Starting
# one behind keeps this counter aligned with the preexec event below, including
# after unfinished entries and numbering gaps.
typeset -gi _tj_count=$(( TJ_NEXT - 1 ))

_tj_publish() {
  export TJ_NEXT=$(( _tj_count + 1 ))
  # Qualified by journal, so it still resolves from another pane.
  export TJ_REF="@${TJ_JOURNAL}.${TJ_NEXT}"
}

_tj_publish

_tj_update_running_title() {
  emulate -L zsh
  local format=${TJ_TITLE:-'TJ | %3~'}
  [[ $format == none ]] && return 0

  # The command is terminal data, not a format: remove control bytes rather
  # than evaluating parameters, substitutions, or prompt escapes within it.
  local rendered=${1//[[:cntrl:]]/}
  _tj_emit "0;$rendered"
}

_tj_update_title() {
  emulate -L zsh
  local format=${TJ_TITLE:-'TJ | %3~'}
  [[ $format == none ]] && return 0

  # The format is deliberately shell-evaluated: users may use parameters,
  # arithmetic, command substitutions, and zsh prompt escapes such as %3~.
  # Remove the bytes that can terminate an OSC string before enclosing the
  # result in one.
  local rendered="${(e)format}"
  rendered="${(%)rendered}"
  rendered=${rendered//$'\e'/}
  rendered=${rendered//$'\a'/}
  rendered=${rendered//$'\x9c'/}
  _tj_emit "0;$rendered"
}

_tj_precmd() {
  # Must be the first thing read, before any command here disturbs it.
  # Not named `status`: that is a special parameter in zsh.
  local exit_code=$?
  _tj_emit "133;D;$exit_code"
  _tj_emit "133;A"
  _tj_update_title
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

# Open the journal browser from the current prompt. The TUI owns the terminal
# until it exits; ZLE then redraws the command line that was being edited.
_tj_tui_widget() {
  emulate -L zsh

  zle -I
  # ZLE does not reliably expose its terminal on stdin. Duplicate stderr,
  # which is the inherited terminal descriptor, rather than reopening
  # /dev/tty: poll() rejects freshly-opened /dev/tty descriptors on macOS.
  # stdout is intentionally captured: the TUI paints through stderr when
  # stdout is a pipe, and writes the chosen detail value to stdout on exit.
  local selection
  selection=$(command "$(_tj_bin)" tui <&2)
  local tui_status=$?
  if (( tui_status == 0 )) && [[ -n $selection ]]; then
    LBUFFER+=$selection
  fi
  zle reset-prompt
  return $tui_status
}

_tj_register_tui_widget() {
  (( ${+_TJ_TUI_WIDGET_REGISTERED} )) && return 0

  zle -N _tj_tui_widget || return 1
  local key=${TJ_TUI_KEY-'^X^T'}
  if [[ -n $key && $key != none ]]; then
    bindkey "$key" _tj_tui_widget || return 1
  fi
  typeset -g _TJ_TUI_WIDGET_REGISTERED=1
}

_tj_register_tui_widget

# --- accepted reference expansion ------------------------------------------

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
    (( ${#qualifier} >= 1 && ${#qualifier} <= 63 )) || return 1
    [[ $qualifier == [a-z0-9] || $qualifier == [a-z0-9][a-z0-9-]#[a-z0-9] ]] || return 1
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

  (( ${#target} >= 1 && ${#target} <= 63 )) || return 1
  [[ $target == [a-z]* && $target == [a-z0-9-]## && $target != *- ]]
}

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

# TJ already accepts references as data. Do not turn its own arguments into
# paths, particularly the bare `tj @REF` resolver shorthand.
_tj_is_tj_command_line() {
  emulate -L zsh
  local line=${1##[[:space:]]#}
  [[ $line == tj' '* || $line == tj$'\t'* ]]
}

# Scan one command line without evaluating it. The transformer only receives
# unquoted shell words and may replace the dynamically scoped `_tj_scan_word`.
_tj_transform_command_line() {
  emulate -L zsh

  local transformer=$1 buf=$2 out='' word='' ch _tj_scan_word
  local -i i=1 n=${#buf} at_word_start=1 changed=0

  while (( i <= n )); do
    ch=${buf[i]}
    case $ch in
      "'")
        out+=$ch; (( i++ ))
        while (( i <= n )) && [[ ${buf[i]} != "'" ]]; do out+=${buf[i]}; (( i++ )); done
        (( i <= n )) && { out+=${buf[i]}; (( i++ )); }
        at_word_start=0
        ;;
      '"')
        out+=$ch; (( i++ ))
        while (( i <= n )) && [[ ${buf[i]} != '"' ]]; do
          if [[ ${buf[i]} == '\\' ]] && (( i < n )); then out+=${buf[i]}; (( i++ )); fi
          out+=${buf[i]}; (( i++ ))
        done
        (( i <= n )) && { out+=${buf[i]}; (( i++ )); }
        at_word_start=0
        ;;
      ' '|$'\t'|$'\n'|'|'|'&'|';'|'('|')'|'<'|'>')
        out+=$ch; (( i++ )); at_word_start=1
        ;;
      *)
        word=''
        while (( i <= n )); do
          if [[ ${buf[i]} == '\\' ]] && (( i < n )); then
            word+=${buf[i]}; (( i++ ))
            word+=${buf[i]}; (( i++ ))
            continue
          fi
          case ${buf[i]} in
            (' '|$'\t'|$'\n'|'|'|'&'|';'|'('|')'|'<'|'>'|"'"|'"') break ;;
          esac
          word+=${buf[i]}; (( i++ ))
        done
        _tj_scan_word=$word
        "$transformer" "$word" "$at_word_start"
        [[ $_tj_scan_word != $word ]] && changed=1
        out+=$_tj_scan_word
        at_word_start=0
        ;;
    esac
  done

  _tj_expanded=$out
  return $(( ! changed ))
}

_tj_transform_reference_word() {
  local word=$1 at_word_start=$2 head suffix
  (( at_word_start )) || return 0
  head=${word%%/*}
  suffix=${word#$head}
  [[ $head == @* ]] && _tj_valid_reference_head "$head" || return 0

  # The resolver remains authoritative for both reference heads and resource
  # suffixes. Unknown handles and missing paths stay literal.
  command "$(_tj_bin)" resolve "$word" >/dev/null 2>&1 || return 0
  _tj_scan_word="\"\$(tj ${(q)word})\""
}

_tj_rewrite_references() {
  _tj_transform_command_line _tj_transform_reference_word "$1"
}

_tj_accept_line() {
  if ! _tj_is_literal_tjcd "$BUFFER" && ! _tj_is_tj_command_line "$BUFFER" &&
     [[ $BUFFER == *@* ]] && _tj_rewrite_references "$BUFFER"; then
    _TJ_TYPED=$BUFFER
    BUFFER=$_tj_expanded
    zle redisplay
  fi
  zle _tj_accept_line_next -- "$@"
}

_tj_register_accept_line() {
  (( ${+_TJ_ACCEPT_LINE_REGISTERED} )) && return 0
  zle -A accept-line _tj_accept_line_next || return 1
  zle -N accept-line _tj_accept_line || return 1
  typeset -g _TJ_ACCEPT_LINE_REGISTERED=1
}

_tj_register_accept_line

typeset -ga _tj_completion_candidates

_tj_load_completion_candidates() {
  emulate -L zsh
  _tj_completion_candidates=(${(f)"$(command "$(_tj_bin)" complete "$1" 2>/dev/null)"})
  (( ${#_tj_completion_candidates} ))
}

# --- completion -------------------------------------------------------------

# The resolver knows what is on disk; this only formats what it prints.
_tj_completer() {
  [[ $PREFIX == @* ]] || return 1
  _tj_load_completion_candidates "$PREFIX" || return 1
  # Let zsh quote the match it inserts. `-Q` would turn a resource name into
  # active shell syntax when it contains a metacharacter.
  compadd -U -- $_tj_completion_candidates
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

  # TJ's shorthand is a fallback immediately after _complete, before _ignored
  # or any later policy the user configured.
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
