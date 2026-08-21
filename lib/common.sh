# shellcheck shell=bash
# Shared helpers for install.sh, deploy.sh, install_claude_plugins.sh.
# Sourced, not executed. Callers must:
#   - run under bash (these use arrays and [[ ]])
#   - define FAILURES=() before sourcing if they want run_step tracking
#   - optionally set AUTO_YES=true to silence run_step's on-failure prompt
#
# Guard so repeated `source` inside one process is cheap.
if [ "${_DOTFILES_COMMON_SH:-}" = 1 ]; then
    return 0
fi
_DOTFILES_COMMON_SH=1

# Record a failure against $FAILURES if the command fails. If $AUTO_YES is
# unset/false AND stdin is a tty, prompt the caller to continue; otherwise
# fall through silently so non-interactive runs don't hang.
run_step() {
    local name="$1"; shift
    if [ "${DRY_RUN:-false}" = true ]; then
        echo "[dry-run] Would run: $name"
        return 0
    fi
    if ! "$@"; then
        FAILURES+=("$name")
        if [ "${AUTO_YES:-false}" != true ] && [ -t 0 ]; then
            local answer
            read -rep "  Step '$name' failed. Continue? [Y/n]: " answer
            case "${answer:-y}" in
                [Nn]*) exit 1 ;;
            esac
        fi
    fi
}

# Retry a command up to 3 times with exponential backoff (2, 4, 8s).
retry() {
    local attempts=3 delay=2 n=0
    while ! "$@"; do
        n=$((n + 1))
        if [ "$n" -ge "$attempts" ]; then return 1; fi
        echo "  Retrying ($n/$attempts) in ${delay}s..." >&2
        sleep "$delay"
        delay=$((delay * 2))
    done
}

os_name() {
    uname -s 2>/dev/null || printf unknown
}

is_macos() {
    [ "$(os_name)" = "Darwin" ]
}

is_chpc() {
    # Hostname is the most reliable signal — login/compute nodes always
    # present *.chpc.utah.edu.
    case "${HOSTNAME:-$(hostname 2>/dev/null)}" in
        *.chpc.utah.edu) return 0 ;;
    esac
    # Explicit override for ambiguous cases (sshfs/NFS mounts of CHPC home
    # on a personal machine, container images that ship the path, etc.).
    [ "${CHPC:-}" = 1 ] && return 0
    # Path-only detection turned out too eager: any laptop with /uufs
    # sshfs-mounted from CHPC would trigger CHPC mode. Require both a
    # CHPC-only path AND the `module` command, which are only co-present
    # on actual CHPC systems.
    [ -d "/uufs/chpc.utah.edu/sys" ] && command -v module &>/dev/null && return 0
    return 1
}

is_cloudlab() {
    # FQDN of testbed nodes: <node>.<exp>.<proj>.<cluster>.cloudlab.us
    # (the federation also uses *.emulab.net, which covers *.apt.emulab.net).
    case "${HOSTNAME:-$(hostname 2>/dev/null)}" in
        *.cloudlab.us|*.emulab.net) return 0 ;;
    esac
    # Explicit override (sshfs/NFS mount of a CloudLab home elsewhere).
    [ "${CLOUDLAB:-}" = 1 ] && return 0
    # Path markers: the short hostname (e.g. "node3") won't match the case
    # above, so this is the reliable signal. Both dirs are co-present only on
    # real Emulab/CloudLab testbed nodes.
    [ -d /usr/testbed ] && [ -d /var/emulab ] && return 0
    return 1
}

machine_arch() {
    local arch
    arch="$(uname -m 2>/dev/null || true)"
    case "$arch" in
        arm64) printf "aarch64" ;;
        *) printf "%s" "$arch" ;;
    esac
}

to_lower() {
    printf "%s" "$1" | tr '[:upper:]' '[:lower:]'
}

portable_realpath() {
    local path="$1" dir base

    if command -v realpath >/dev/null 2>&1; then
        realpath "$path" 2>/dev/null && return 0
    fi

    if [ -L "$path" ]; then
        path="$(readlink "$path" 2>/dev/null || printf "%s" "$path")"
    fi

    dir="$(dirname "$path")"
    base="$(basename "$path")"
    if dir="$(cd "$dir" 2>/dev/null && pwd -P)"; then
        printf "%s/%s\n" "$dir" "$base"
        return 0
    fi

    return 1
}

# True iff $1 is a symlink whose target resolves into this repo ($DIR).
# Callers must have $DIR set (every script that sources common.sh does).
# Matches both the literal $DIR and its canonical form, since macOS
# portable_realpath resolves /var → /private/var while $DIR stays logical.
is_managed_symlink() {
    [ -L "$1" ] || return 1
    local target dir_canon
    target="$(portable_realpath "$1" 2>/dev/null || true)"
    dir_canon="$(portable_realpath "$DIR" 2>/dev/null || printf '%s' "$DIR")"
    case "$target" in
        "$DIR"|"$DIR"/*|"$dir_canon"|"$dir_canon"/*) return 0 ;;
        *) return 1 ;;
    esac
}

sha256_file() {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        return 1
    fi
}

base64_decode_cmd() {
    if printf "" | base64 -d >/dev/null 2>&1; then
        printf "base64 -d"
    elif printf "" | base64 -D >/dev/null 2>&1; then
        printf "base64 -D"
    else
        return 1
    fi
}

# Resolve the rclone config location without requiring rclone itself. Prefer an
# explicit override, then the XDG/default locations used by current rclone,
# and finally the legacy ~/.rclone.conf when it already exists.
rclone_config_file() {
    if [ -n "${RCLONE_CONFIG:-}" ]; then
        printf '%s\n' "$RCLONE_CONFIG"
    elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
        printf '%s/rclone/rclone.conf\n' "$XDG_CONFIG_HOME"
    elif [ -f "$HOME/.config/rclone/rclone.conf" ] || [ ! -f "$HOME/.rclone.conf" ]; then
        printf '%s/.config/rclone/rclone.conf\n' "$HOME"
    else
        printf '%s/.rclone.conf\n' "$HOME"
    fi
}

# Print one INI section verbatim. Callers must treat stdout as secret material:
# an rclone remote section contains OAuth tokens and client credentials.
rclone_extract_remote_section() {
    local config_file="$1" remote_name="$2"

    awk -v wanted="[$remote_name]" '
        /^\[[^]]+\][[:space:]]*$/ {
            if (inside && $0 != wanted) exit
            inside = ($0 == wanted)
        }
        inside { print }
    ' "$config_file"
}

# Validate the exact Google Drive profile this repo deploys. Requiring an
# explicit full-drive scope and client credentials prevents accidentally
# propagating the retiring shared-client or restricted drive.file setup.
rclone_gdrive_profile_valid() {
    local config_file="$1"

    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^\[[^]]+\][[:space:]]*$/ {
            inside = ($0 == "[gdrive]")
            if (inside) found = 1
            next
        }
        inside && /^[[:space:]]*[^#;][^=]*=/ {
            line = $0
            key = line
            sub(/=.*/, "", key)
            key = trim(key)
            sub(/^[^=]*=/, "", line)
            value = trim(line)
            if (key == "type" && value == "drive") type_ok = 1
            if (key == "scope" && value == "drive") scope_ok = 1
            if (key == "client_id" && value != "") client_id_ok = 1
            if (key == "client_secret" && value != "") client_secret_ok = 1
            if (key == "token" && value != "") token_ok = 1
        }
        END {
            exit !(found && type_ok && scope_ok && client_id_ok && client_secret_ok && token_ok)
        }
    ' "$config_file"
}

rclone_gdrive_auth_state() {
    local config_file="${1:-$(rclone_config_file)}"

    if [ ! -e "$config_file" ]; then
        printf 'missing|rclone config not found at %s' "$config_file"
    elif [ ! -f "$config_file" ]; then
        printf 'blocked|rclone config is not a regular file: %s' "$config_file"
    elif [ ! -r "$config_file" ]; then
        printf 'blocked|rclone config is not readable by the current user: %s' "$config_file"
    elif grep -q '^RCLONE_ENCRYPT_V0:' "$config_file" 2>/dev/null; then
        printf 'blocked|encrypted rclone configs require per-host setup and cannot be section-merged'
    elif rclone_gdrive_profile_valid "$config_file"; then
        printf 'deployable|%s [gdrive] -> remote rclone config' "$config_file"
    else
        printf 'blocked|gdrive must use type=drive, scope=drive, a personal client ID/secret, and an OAuth token'
    fi
}

# Atomically add/replace [gdrive] while preserving every other remote. Both
# inputs contain credentials, so this helper never prints their contents and
# creates all intermediate state with user-only permissions.
rclone_merge_gdrive_section() {
    local section_file="$1" config_file="$2" config_dir tmp

    [ -f "$section_file" ] && [ -r "$section_file" ] || return 1
    rclone_gdrive_profile_valid "$section_file" || return 1
    config_dir="$(dirname "$config_file")"
    mkdir -p "$config_dir" || return 1
    chmod 700 "$config_dir" 2>/dev/null || true

    if [ -e "$config_file" ]; then
        [ -f "$config_file" ] && [ ! -L "$config_file" ] && [ -r "$config_file" ] || {
            echo "Existing rclone config is not a readable regular file: $config_file" >&2
            return 1
        }
        if grep -q '^RCLONE_ENCRYPT_V0:' "$config_file" 2>/dev/null; then
            echo "Cannot section-merge an encrypted rclone config" >&2
            return 1
        fi
    fi

    tmp="$(umask 077 && mktemp "$config_dir/.rclone.deploy.XXXXXX")" || return 1
    if [ -f "$config_file" ]; then
        awk '
            /^\[[^]]+\][[:space:]]*$/ { inside = ($0 == "[gdrive]") }
            !inside { print }
        ' "$config_file" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    if [ -s "$tmp" ]; then
        # Keep the appended section separate even when the original file had
        # no trailing newline. A harmless extra blank line is preferable to
        # joining a comment or setting onto the section header.
        printf '\n' >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    cat "$section_file" >> "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$config_file" || { rm -f "$tmp"; return 1; }
}

delete_matching_lines() {
    local file="$1" pattern="$2" tmp

    [ -f "$file" ] || return 0
    tmp="$(mktemp "${TMPDIR:-/tmp}/dotfiles.XXXXXX")" || return 1
    grep -v -E "$pattern" "$file" > "$tmp" || true
    cat "$tmp" > "$file" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
}

# rmdir $1 only if it's an empty directory. Silent no-op if missing or
# non-empty. Used by install/uninstall to tidy directories the repo
# previously created (e.g. one-shot legacy cleanup paths).
remove_dir_if_empty() {
    local path="$1" label="${2:-}"
    label="${label:-$(display_path "$path")}"
    if [ -d "$path" ]; then
        rmdir "$path" 2>/dev/null && echo "  Removed $label"
    fi
}

# Strip every line matching $2 (extended regex) from $1. Refuses to write
# through symlinks so we don't accidentally edit a repo-tracked file via
# a managed link. Quiet no-op when the file is absent.
clean_line_from_file() {
    local file="$1" pattern="$2"
    if [ -L "$file" ]; then
        return 0
    fi
    if [ -f "$file" ]; then
        delete_matching_lines "$file" "$pattern" || return 1
        echo "  Cleaned $file"
    fi
}

# Quote a command string so it can be passed as the single payload to
# `bash -lc ...` without losing shell metacharacters.
quote_for_bash_lc() {
    local cmd="$1"
    printf '%q' "$cmd"
}

path_is_manifest_managed() {
    # Only paths under $HOME are eligible for manifest tracking. /usr/local/bin
    # was historically allowed too, but that opened a footgun on shared Linux
    # hosts: install.sh installing into /usr/local/bin (when writable) would
    # record system binaries that uninstall.sh would later sudo-remove.
    local path="$1"
    case "$path" in
        "$HOME"/*) return 0 ;;
        *) return 1 ;;
    esac
}

manifest_contains_path() {
    local path="$1"
    [ -n "${INSTALL_MANIFEST:-}" ] || return 1
    [ -f "$INSTALL_MANIFEST" ] || return 1
    grep -Fqx "$path" "$INSTALL_MANIFEST"
}

manifest_add_path() {
    local path="$1"
    [ -n "${INSTALL_MANIFEST:-}" ] || return 1
    path_is_manifest_managed "$path" || return 0
    mkdir -p "$(dirname "$INSTALL_MANIFEST")" || return 1
    touch "$INSTALL_MANIFEST" || return 1
    manifest_contains_path "$path" || printf '%s\n' "$path" >> "$INSTALL_MANIFEST"
}

# Internal: rotate an existing $dst.bak to a timestamped name unless it is
# byte-identical to $dst (in which case the existing backup already captures
# the same state and can be safely overwritten). Protects against
# destroying a backup the user has edited by hand between setup runs.
_rotate_backup() {
    local dst="$1"
    local bak="${dst}.bak" rotated ts
    [ -e "$bak" ] || return 0
    if [ -f "$bak" ] && [ -f "$dst" ] && cmp -s "$bak" "$dst" 2>/dev/null; then
        rm -f "$bak"
        return 0
    fi
    # Prefer nanosecond granularity (GNU date) so back-to-back rotations
    # within the same second don't all collide and produce `.bak.<ts>~~~`
    # chains. BSD date doesn't support %N; fall back to second granularity.
    ts="$(date +%Y%m%d-%H%M%S.%N 2>/dev/null || true)"
    case "$ts" in
        *N*|"") ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || printf '%s' "$$")" ;;
    esac
    rotated="${bak}.${ts}"
    while [ -e "$rotated" ]; do rotated="${rotated}~"; done
    if mv -f "$bak" "$rotated"; then
        echo "  Preserved edited backup as $rotated"
    fi
}

# Internal: back up $dst to ${dst}.bak if it exists and isn't already a link
# to $src. Leaves the slot empty on return.
_backup_existing() {
    local src="$1" dst="$2" current_target=""
    if [ -L "$dst" ]; then
        current_target="$(portable_realpath "$dst" 2>/dev/null || true)"
        if [ "$current_target" = "$src" ]; then
            rm -f "$dst"
            return 0
        fi
        _rotate_backup "$dst"
        echo "  Backing up $dst -> ${dst}.bak"
        mv -f "$dst" "${dst}.bak"
    elif [ -e "$dst" ]; then
        # For copies, skip the backup if content matches; for links, always back up.
        if [ "${3:-link}" = "copy" ] && cmp -s "$src" "$dst" 2>/dev/null; then
            return 0
        fi
        _rotate_backup "$dst"
        echo "  Backing up $dst -> ${dst}.bak"
        mv -f "$dst" "${dst}.bak"
    fi
}

# Replace $dst with a symlink to $src, backing up any existing real file/dir.
backup_and_link() {
    local src="$1" dst="$2"
    _backup_existing "$src" "$dst" link || return 1
    mkdir -p "$(dirname "$dst")"
    ln -sf "$src" "$dst" || return 1
    echo "  $src -> $dst"
}

# Replace $dst with a copy of $src, backing up any existing real file.
# No-op when the existing content matches, to keep re-runs quiet.
backup_and_copy() {
    local src="$1" dst="$2"
    if [ -e "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst" 2>/dev/null; then
        echo "  $dst already up to date"
        return 0
    fi
    _backup_existing "$src" "$dst" copy || return 1
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst" || return 1
    echo "  Copied $src -> $dst"
}

# Single source of truth for the upstream-skill clone cache. Consumed by
# scripts/install_claude_skills.sh (writer) and uninstall.sh (cleaner).
# shellcheck disable=SC2034  # used by sourcing scripts
EXTERNAL_SKILLS_CACHE="$HOME/.local/share/claude-skills"

# Collapse $HOME to a leading ~ for display. The ~ is a literal character
# in the output, never a shell tilde-expansion.
display_path() {
    local path="$1" tilde='~'
    case "$path" in
        "$HOME") printf '%s' "$tilde" ;;
        "$HOME"/*) printf '%s/%s' "$tilde" "${path#"$HOME"/}" ;;
        *) printf '%s' "$path" ;;
    esac
}

# ----- Interactive (TUI) helpers ---------------------------------------------
#
# All helpers degrade to plain `read -rp` prompts when gum is unavailable,
# NO_TUI=1 is set, or stdout is not a tty. AUTO_YES=true short-circuits
# tui_confirm to "yes" and is otherwise the caller's responsibility.

if [ -n "${NO_COLOR:-}" ]; then
    export GUM_INPUT_PROMPT_FOREGROUND="" GUM_INPUT_CURSOR_FOREGROUND=""
    export GUM_CHOOSE_CURSOR_FOREGROUND="" GUM_CHOOSE_SELECTED_FOREGROUND=""
    export GUM_CHOOSE_HEADER_FOREGROUND=""
    export GUM_CONFIRM_PROMPT_FOREGROUND="" GUM_CONFIRM_SELECTED_FOREGROUND=""
fi

tui_available() {
    [ "${NO_TUI:-0}" != 1 ] && [ -t 1 ] && command -v gum >/dev/null 2>&1
}

# tui_input PROMPT [DEFAULT] [PLACEHOLDER] — writes the value to stdout.
tui_input() {
    local prompt="$1" default="${2:-}" placeholder="${3:-}"
    if tui_available; then
        gum input --prompt "$prompt: " --value "$default" --placeholder "$placeholder"
    else
        local hint="" answer
        [ -n "$default" ] && hint=" [$default]"
        read -rep "$prompt$hint: " answer
        printf "%s" "${answer:-$default}"
    fi
}

# tui_choose HEADER OPT1 OPT2 ... — writes the chosen option to stdout.
tui_choose() {
    local header="$1"; shift
    if tui_available; then
        gum choose --header "$header" "$@"
    elif [ -t 0 ] && [ -t 1 ]; then
        _tui_arrow_choose "$header" "$@"
    else
        printf "%s" "$1"
    fi
}

# tui_multi HEADER PRESELECTED_CSV OPT1 OPT2 ... — newline-separated picks to
# stdout. Always returns a result: gum choose if available, the bash-native
# arrow multi-select if we have a tty, or the preselected set otherwise.
tui_multi() {
    local header="$1" preselected="$2"; shift 2
    if tui_available; then
        gum choose --no-limit --header "$header" --selected "$preselected" "$@"
    elif [ -t 0 ] && [ -t 1 ]; then
        _tui_arrow_multi "$header" "$preselected" "$@"
    else
        local IFSorig="$IFS" item
        IFS=,
        for item in $preselected; do printf "%s\n" "$item"; done
        IFS="$IFSorig"
    fi
}

# tui_confirm PROMPT [yes|no] — exit 0 = yes. Respects AUTO_YES=true.
tui_confirm() {
    local prompt="$1" default="${2:-yes}"
    if [ "${AUTO_YES:-false}" = true ]; then return 0; fi
    if tui_available; then
        if [ "$default" = "no" ]; then
            gum confirm --default=false "$prompt"
        else
            gum confirm "$prompt"
        fi
    else
        local hint answer
        [ "$default" = "yes" ] && hint="[Y/n]" || hint="[y/N]"
        read -rep "  $prompt $hint: " answer
        answer="${answer:-${default:0:1}}"
        [[ "$answer" =~ ^[Yy] ]]
    fi
}

# ----- Bash-native arrow-key menus -------------------------------------------
#
# Used by tui_choose / tui_multi when gum isn't available. Render to stderr,
# return the result on stdout. Bash 3.2 compatible: arrow detection uses
# `read -rsn2 -t 1` (the smallest integer timeout 3.2 accepts), so plain Esc
# has up to a 1-second delay before it's treated as cancel — `q` / `Q` is the
# documented instant cancel.

# _tui_read_key — one keystroke → mnemonic ("up" / "down" / "left" / "right"
# / "enter" / "space" / "quit") or the raw char.
_tui_read_key() {
    local k rest
    IFS= read -rsn1 k </dev/tty || return 1
    case "$k" in
        $'\e')
            IFS= read -rsn2 -t 1 rest </dev/tty 2>/dev/null || rest=""
            case "$rest" in
                '[A') printf "up" ;;
                '[B') printf "down" ;;
                '[C') printf "right" ;;
                '[D') printf "left" ;;
                *)    printf "quit" ;;
            esac
            ;;
        "")  printf "enter" ;;
        " ") printf "space" ;;
        q|Q) printf "quit" ;;
        *)   printf "%s" "$k" ;;
    esac
}

# _tui_arrow_choose HEADER OPT1 OPT2 … — single-select. Exit 1 = cancelled.
_tui_arrow_choose() {
    local header="$1"; shift
    local options=("$@") n=$# sel=0 i k
    [ "$n" -gt 0 ] || return 1

    tput civis 2>/dev/null || true
    printf "%s\n" "$header" >&2
    for ((i = 0; i < n; i++)); do printf "\n" >&2; done

    while :; do
        printf "\e[%dA" "$n" >&2
        for ((i = 0; i < n; i++)); do
            if [ "$i" -eq "$sel" ]; then
                printf "\e[K\e[36m> %s\e[0m\n" "${options[$i]}" >&2
            else
                printf "\e[K  %s\n" "${options[$i]}" >&2
            fi
        done
        k="$(_tui_read_key)"
        case "$k" in
            up)    sel=$(( (sel - 1 + n) % n )) ;;
            down)  sel=$(( (sel + 1) % n )) ;;
            enter) break ;;
            quit)  tput cnorm 2>/dev/null || true; return 1 ;;
        esac
    done
    tput cnorm 2>/dev/null || true
    printf "%s" "${options[$sel]}"
}

# _tui_arrow_multi HEADER PRESELECTED_CSV OPT1 OPT2 … — multi-select.
# Space toggles, Enter confirms. Exit 1 = cancelled.
_tui_arrow_multi() {
    local header="$1" preselected="$2"; shift 2
    local options=("$@") n=$# sel=0 i k
    [ "$n" -gt 0 ] || return 1
    local picked=()
    for ((i = 0; i < n; i++)); do picked[$i]=0; done
    local IFSorig="$IFS" item
    IFS=,
    for item in $preselected; do
        for ((i = 0; i < n; i++)); do
            [ "${options[$i]}" = "$item" ] && picked[$i]=1
        done
    done
    IFS="$IFSorig"

    tput civis 2>/dev/null || true
    printf "%s\n" "$header" >&2
    printf "  (Up/Down to move, Space to toggle, Enter to confirm, q to cancel)\n" >&2
    for ((i = 0; i < n; i++)); do printf "\n" >&2; done

    while :; do
        printf "\e[%dA" "$n" >&2
        for ((i = 0; i < n; i++)); do
            local mark="[ ]"; [ "${picked[$i]}" = 1 ] && mark="[x]"
            if [ "$i" -eq "$sel" ]; then
                printf "\e[K\e[36m> %s %s\e[0m\n" "$mark" "${options[$i]}" >&2
            else
                printf "\e[K  %s %s\n" "$mark" "${options[$i]}" >&2
            fi
        done
        k="$(_tui_read_key)"
        case "$k" in
            up)    sel=$(( (sel - 1 + n) % n )) ;;
            down)  sel=$(( (sel + 1) % n )) ;;
            space) picked[$sel]=$(( 1 - picked[$sel] )) ;;
            enter) break ;;
            quit)  tput cnorm 2>/dev/null || true; return 1 ;;
        esac
    done
    tput cnorm 2>/dev/null || true
    for ((i = 0; i < n; i++)); do
        [ "${picked[$i]}" = 1 ] && printf "%s\n" "${options[$i]}"
    done
}
