# TJ shell integration for fish.
#
# Source this from ~/.config/fish/config.fish:
#
#     source /path/to/tj.plugin.fish
#
# Fish uses its native command substitution for entry paths:
#
#     cat (tj @42/out)

function _tj_bin
    if set -q TJ
        printf '%s\n' "$TJ"
    else
        printf '%s\n' tj
    end
end

function _tjctl_bin
    if set -q TJCTL
        printf '%s\n' "$TJCTL"
    else
        printf '%s\n' tjctl
    end
end

# These work both inside and outside a writer. Inside, the proxy changes its
# recorder and tjctl returns Fish source for the replacement environment.
function _tj_handoff
    set -l operation $argv[1]
    set -e argv[1]
    set -l tjctl_bin (_tjctl_bin)
    if not set -q TJ_JOURNAL
        command $tjctl_bin $operation $argv
        return
    end

    set -l setup (env TJ_SHELL_HANDOFF=fish $tjctl_bin $operation $argv | string collect)
    or return
    eval $setup
    _tj_publish_ref
end

function tj-new
    _tj_handoff new $argv
end

function tj-use
    _tj_handoff use $argv
end

# A subprocess cannot change Fish's current directory.
function tjcd
    if test (count $argv) -ne 1
        printf '%s\n' 'usage: tjcd @ref' >&2
        return 2
    end

    set -l tj_bin (_tj_bin)
    set -l entry
    if test -d "$argv[1]"
        set entry $argv[1]
    else
        set entry (command $tj_bin resolve $argv[1])
        or return
    end
    if not test -f "$entry/cwd"
        printf '%s\n' 'tjcd: entry has no recorded cwd' >&2
        return 1
    end

    set -l destination (string collect --no-trim-newlines <"$entry/cwd")
    if not string match -qr '^/' -- "$destination"
        printf '%s\n' 'tjcd: recorded cwd is not an absolute path' >&2
        return 1
    end
    if not test -d "$destination"
        printf 'tjcd: recorded directory no longer exists: %s\n' "$destination" >&2
        return 1
    end
    builtin cd -- "$destination"
end

if not set -q TJ_JOURNAL
    return
end

set -l _tj_fish_version (string split . -- $version)
if test (count $_tj_fish_version) -eq 0; or test $_tj_fish_version[1] -lt 4
    printf '%s\n' 'tj: Fish 4.0.0 or later is required; earlier Fish releases do not emit the OSC 133 markers TJ needs' >&2
    return
end

function _tj_publish_ref
    set -gx TJ_REF (string join '' @ "$TJ_JOURNAL" . "$TJ_NEXT")
end

function _tj_publish_next
    set -gx TJ_NEXT (math "$TJ_NEXT + 1")
    _tj_publish_ref
end

_tj_publish_ref

function _tj_preexec --on-event fish_preexec
    # Fish 4 emits OSC 133 command boundaries and OSC 7 working-directory
    # reports itself. TJ consumes those native markers; this hook only keeps
    # prompt variables aligned with the entry Fish has just started.
    if test -n "$argv[1]"
        _tj_publish_next
    end
end

function _tj_complete_reference
    set -l token (commandline -ct)
    if not string match -qr '^@' -- "$token"
        return
    end
    set -l tj_bin (_tj_bin)
    command $tj_bin complete "$token"
end

# The generated completion files handle TJ's command grammar. Add the
# journal-aware candidates here, where the active journal is available.
complete -c tj -f -n 'string match -qr "^@" -- (commandline -ct)' -a '(_tj_complete_reference)'
complete -c tjcd -f -a '(_tj_complete_reference)'

function _tj_tui
    set -l tj_bin (_tj_bin)
    # Keep stdin on the terminal inherited by Fish. Reopening /dev/tty here
    # produces a descriptor that poll() rejects on macOS. Stdout remains
    # captured for the selected detail text; the TUI paints through stderr.
    set -l selection (command $tj_bin tui <&2)
    set -l tui_status $status
    if test $tui_status -eq 0; and test -n "$selection"
        commandline --insert (string join \n $selection)
    end
    commandline -f repaint
    return $tui_status
end

# Ctrl-X Ctrl-T avoids Fish's common Ctrl-T fzf binding.
bind \cx\ct _tj_tui
