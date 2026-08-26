# tj shell integration.
#
# Source this from ~/.zshrc:
#
#     source /path/to/tj.plugin.zsh
#
# Everything below is inert outside a tj session, so loading it
# unconditionally is safe.
#
# The proxy sees a single byte stream and cannot tell where one command ends
# and the next begins. This plugin marks those boundaries in band, using the
# OSC 133 convention plus one tj sequence carrying the command line itself.
# tj strips its own sequence before the terminal ever sees it.

[[ -n $TJ_SESSION ]] || return 0

autoload -Uz add-zsh-hook

# Straight to the terminal, so the markers still work when a command's own
# output is redirected.
_tj_emit() {
  printf '\e]%s\e\\' "$1" > /dev/tty 2>/dev/null
}

_tj_preexec() {
  # Base64 keeps arbitrary command lines - semicolons, newlines, escapes -
  # from colliding with the sequence framing. tj records what was typed, so
  # this is $1, before any expansion tj itself performs.
  local encoded
  encoded="${$(print -rn -- "$1" | base64)//$'\n'/}"
  _tj_emit "5107;tj;cmd;$encoded"
  _tj_emit "133;C"
}

_tj_precmd() {
  # Must be the first thing read, before any command here disturbs it.
  # Not named `status`: that is a special parameter in zsh.
  local exit_code=$?
  _tj_emit "133;D;$exit_code"
  _tj_emit "133;A"
}

add-zsh-hook preexec _tj_preexec
add-zsh-hook precmd _tj_precmd
