#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIR

# --- Flags ---
AUTO_YES="${AUTO_YES:-false}"
FORCE_COPY="${FORCE_COPY:-0}"

usage() {
    echo "Usage: deploy.sh [-y|--yes] [--force-copy] [-h|--help]"
    echo "  -y, --yes     Skip all interactive confirmations"
    echo "  --force-copy  Re-copy files even when the remote already matches"
    echo "  -h, --help    Show this help"
}

parse_args() {
    local arg

    AUTO_YES=false
    FORCE_COPY=0
    for arg in "$@"; do
        case "$arg" in
            -y|--yes) AUTO_YES=true ;;
            --force-copy) FORCE_COPY=1 ;;
            -h|--help) usage; return 2 ;;
            *)
                echo "Unknown option: $arg"
                usage
                return 1
                ;;
        esac
    done
    export FORCE_COPY
}

check_prereqs() {
    local missing=() cmd

    for cmd in ssh scp git base64; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: missing required commands: ${missing[*]}"
        return 1
    fi
}

# --- Colors (respect NO_COLOR and non-tty) ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'
    BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; BOLD=''; DIM=''; RESET=''
fi

# --- Output helpers ---
info()    { printf "${BOLD}%s${RESET}\n" "$*"; }
success() { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn()    { printf "  ${YELLOW}⚠${RESET} %s\n" "$*"; }
error()   { printf "  ${RED}✗${RESET} %s\n" "$*"; }
section() { printf "\n${BOLD}--- %s ---${RESET}\n" "$*"; }

# --- Error tracking ---
FAILURES=()

# --- Shared helpers (run_step, retry) ---
# Export AUTO_YES so the library's run_step sees it.
export AUTO_YES
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

local_claude_credentials_file() {
    printf "%s/.credentials.json" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

local_codex_auth_file() {
    printf "%s/auth.json" "${CODEX_HOME:-$HOME/.codex}"
}

local_gh_config_dir() {
    if [ -n "${GH_CONFIG_DIR:-}" ]; then
        printf "%s" "$GH_CONFIG_DIR"
    elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
        printf "%s/gh" "$XDG_CONFIG_HOME"
    else
        printf "%s/.config/gh" "$HOME"
    fi
}

local_gh_hosts_file() {
    printf "%s/hosts.yml" "$(local_gh_config_dir)"
}

local_rclone_config_file() {
    rclone_config_file
}

local_gh_hosts_has_token() {
    local hosts_file="$1"

    [ -f "$hosts_file" ] || return 1
    grep -q '^[[:space:]]*oauth_token:' "$hosts_file"
}

local_gh_token_available() {
    command -v gh >/dev/null 2>&1 || return 1
    [ -n "$(gh auth token 2>/dev/null || true)" ]
}

auth_state_gh() {
    local hosts_file="${1:-$(local_gh_hosts_file)}"

    if ! command -v gh >/dev/null 2>&1; then
        printf "missing|gh CLI not installed locally"
    elif ! gh auth status >/dev/null 2>&1; then
        printf "missing|gh CLI is not authenticated locally"
    elif local_gh_token_available; then
        printf "deployable|token from gh auth token -> gh auth login --with-token on remote"
    elif local_gh_hosts_has_token "$hosts_file"; then
        printf "deployable|plaintext hosts.yml -> \$HOME/.config/gh/hosts.yml"
    else
        printf "blocked|gh is authenticated, but no readable token or plaintext hosts.yml token is available"
    fi
}

auth_state_claude() {
    local credentials_file="${1:-$(local_claude_credentials_file)}"

    if [ -f "$credentials_file" ]; then
        printf "deployable|%s -> \$HOME/.claude/.credentials.json" "$credentials_file"
    elif command -v claude >/dev/null 2>&1 && claude auth status >/dev/null 2>&1; then
        printf "blocked|Claude is logged in locally, but auth is not in a copyable credentials file; run 'claude auth login' or 'claude setup-token' on the remote"
    else
        printf "missing|Claude credentials file not found at %s" "$credentials_file"
    fi
}

auth_state_codex() {
    local auth_file="${1:-$(local_codex_auth_file)}"

    if [ -f "$auth_file" ]; then
        printf "deployable|%s -> \$HOME/.codex/auth.json" "$auth_file"
    else
        printf "missing|Codex auth file not found at %s" "$auth_file"
    fi
}

auth_state_api_keys() {
    local names=()

    [ -n "${ANTHROPIC_API_KEY:-}" ] && names+=("ANTHROPIC_API_KEY")
    [ -n "${OPENAI_API_KEY:-}" ] && names+=("OPENAI_API_KEY")
    if [ ${#names[@]} -gt 0 ]; then
        printf "deployable|%s -> \$HOME/.env_keys" "${names[*]}"
    else
        printf "missing|ANTHROPIC_API_KEY and OPENAI_API_KEY are not set"
    fi
}

auth_state_rclone() {
    rclone_gdrive_auth_state "${1:-$(local_rclone_config_file)}"
}

auth_state_status() {
    printf "%s" "$1" | cut -d '|' -f 1
}

auth_state_detail() {
    printf "%s" "$1" | cut -d '|' -f 2-
}

shell_quote_env_value() {
    printf "'"
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

copy_local_file_to_remote() {
    local local_path="$1"
    local remote_path="$2"
    local mode="${3:-600}"

    if [ ! -f "$local_path" ]; then
        error "Local file not found: $local_path"
        return 1
    fi

    # Computed once: drives both the idempotency pre-check and the
    # post-transfer content verification below.
    local local_sum
    local_sum="$(sha256_file "$local_path" 2>/dev/null || true)"

    # Idempotency: skip copy if remote file is byte-identical. FORCE_COPY=1
    # bypasses this (e.g. to rewrite permissions).
    if [ "${FORCE_COPY:-0}" != 1 ] && [ -n "$local_sum" ]; then
        if [ "$local_sum" = "$(remote_file_sha256 "$remote_path")" ]; then
            echo "    (unchanged — skipping)"
            return 0
        fi
    fi

    # Capture the remote leg's stdout+stderr so we can replay it on failure.
    # Without this, callers only see a vague "Failed to copy …" and the
    # actual cause (perm denied, mktemp failure, etc.) is silently dropped.
    # If local mktemp fails (unwritable TMPDIR), fall back to letting the
    # remote leg stream inline — losing capture beats redirect-to-"" eating
    # the diagnostic.
    local remote_log="" rc=0
    if ! remote_log="$(mktemp "${TMPDIR:-/tmp}/deploy.copy.$$.XXXXXX" 2>/dev/null)"; then
        warn "Local mktemp failed; remote output will stream inline"
        remote_log=""
    fi

    local remote_cmd
    remote_cmd="
        set -eu
        umask 077
        dest=\"$remote_path\"
        dest_dir=\$(dirname \"\$dest\")
        mkdir -p \"\$dest_dir\" || exit 1
        tmp=\$(mktemp \"\$dest_dir/.deploy.XXXXXX\") || exit 1
        cleanup_tmp() { rm -f \"\$tmp\"; }
        trap cleanup_tmp EXIT HUP INT TERM
        if printf '' | base64 -d >/dev/null 2>&1; then
            base64_decode='base64 -d'
        elif printf '' | base64 -D >/dev/null 2>&1; then
            base64_decode='base64 -D'
        else
            echo 'base64 decode is unavailable' >&2
            exit 1
        fi
        \$base64_decode > \"\$tmp\" &&
        chmod $mode \"\$tmp\" &&
        mv -f \"\$tmp\" \"\$dest\"
        status=\$?
        [ \$status -eq 0 ] || cleanup_tmp
        trap - EXIT HUP INT TERM
        exit \$status
    "
    # Run the write in a non-login shell: a login shell sources ~/.bash_logout
    # on the `exit` builtin, and on some hosts its trailing command fails with
    # no tty, which under the remote `set -e` masks an otherwise-successful
    # copy with a non-zero exit (see remote_exec_nologin).
    if [ -n "$remote_log" ]; then
        base64 < "$local_path" | remote_exec_nologin "$remote_cmd" >"$remote_log" 2>&1 || rc=$?
    else
        base64 < "$local_path" | remote_exec_nologin "$remote_cmd" || rc=$?
    fi

    # Trust the bytes on disk, not the exit code. The non-login shell above
    # makes rc reliable, but verifying the destination by sha256 is the
    # durable guarantee: a benign non-zero from any remote-shell quirk can
    # never mask a copy that landed, and a real failure is still caught.
    local verify_sum ok=0
    verify_sum="$(remote_file_sha256 "$remote_path")"
    if [ -n "$local_sum" ] && [ -n "$verify_sum" ]; then
        [ "$local_sum" = "$verify_sum" ] && ok=1
    elif [ "$rc" -eq 0 ]; then
        # No sha tool to compare with; fall back to the (now reliable) rc.
        ok=1
    fi

    # On genuine failure, replay captured remote output if any, else print
    # rc/host/dest so the user has a starting point.
    if [ "$ok" -ne 1 ]; then
        if [ -n "$remote_log" ] && [ -s "$remote_log" ]; then
            sed 's/^/    [remote] /' "$remote_log" >&2
        else
            printf "    [remote] (no output captured — rc=%s host=%s dest=%s)\n" \
                "$rc" "$REMOTE_HOST" "$remote_path" >&2
        fi
    fi
    [ -n "$remote_log" ] && rm -f "$remote_log"
    [ "$ok" -eq 1 ] && return 0
    return 1
}

copy_gdrive_auth_to_remote() {
    local local_config="$1" tmp section_file local_sum remote_sum remote_stage
    local profile_fn merge_fn extract_fn

    tmp="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/deploy.rclone.$$.XXXXXX")" || return 1
    section_file="$tmp/gdrive.conf"
    if ! rclone_extract_remote_section "$local_config" gdrive > "$section_file" || \
        [ ! -s "$section_file" ] || ! rclone_gdrive_profile_valid "$section_file"
    then
        rm -rf "$tmp"
        error "Local gdrive profile is missing or invalid"
        return 1
    fi
    chmod 600 "$section_file" || { rm -rf "$tmp"; return 1; }
    local_sum="$(sha256_file "$section_file" 2>/dev/null || true)"

    extract_fn="$(declare -f rclone_extract_remote_section)"
    remote_sum="$(remote_capture "
        $extract_fn
        config=\"\$HOME/.config/rclone/rclone.conf\"
        if [ -r \"\$config\" ] && [ ! -L \"\$config\" ]; then
            if command -v sha256sum >/dev/null 2>&1; then
                rclone_extract_remote_section \"\$config\" gdrive | sha256sum | awk '{print \$1}'
            elif command -v shasum >/dev/null 2>&1; then
                rclone_extract_remote_section \"\$config\" gdrive | shasum -a 256 | awk '{print \$1}'
            fi
        fi
    " 2>/dev/null || true)"
    if [ "${FORCE_COPY:-0}" != 1 ] && [ -n "$local_sum" ] && [ "$local_sum" = "$remote_sum" ]; then
        echo "    (unchanged — skipping gdrive auth)"
        rm -rf "$tmp"
        return 0
    fi

    remote_stage="\$HOME/.config/rclone/.gdrive.deploy.$$"
    if ! remote_exec 'mkdir -p "$HOME/.config/rclone" && chmod 700 "$HOME/.config/rclone"'; then
        rm -rf "$tmp"
        return 1
    fi
    if ! copy_local_file_to_remote "$section_file" "$remote_stage" 600; then
        remote_exec "rm -f \"$remote_stage\"" >/dev/null 2>&1 || true
        rm -rf "$tmp"
        return 1
    fi

    profile_fn="$(declare -f rclone_gdrive_profile_valid)"
    merge_fn="$(declare -f rclone_merge_gdrive_section)"
    if ! remote_exec "
        $profile_fn
        $merge_fn
        rclone_merge_gdrive_section \"$remote_stage\" \"\$HOME/.config/rclone/rclone.conf\"
        rc=\$?
        rm -f \"$remote_stage\"
        exit \$rc
    "; then
        remote_exec "rm -f \"$remote_stage\"" >/dev/null 2>&1 || true
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
}

ensure_remote_env_keys_loader() {
    remote_exec "
        touch ~/.env_keys && chmod 600 ~/.env_keys
        line='[ -f ~/.env_keys ] && . ~/.env_keys'
        ensure_line() { grep -qF \"\$line\" \"\$1\" 2>/dev/null || echo \"\$line\" >> \"\$1\"; }
        ensure_line ~/.bashrc
        ensure_line ~/.profile
        # ~/.zshrc only if it already exists; install.sh creates it on macOS.
        [ -f ~/.zshrc ] && ensure_line ~/.zshrc
        true
    "
}

remote_upsert_env_exports() {
    printf "%s" "$1" | base64 | remote_exec '
        set -eu
        umask 077
        dest="$HOME/.env_keys"
        dest_dir=$(dirname "$dest")
        mkdir -p "$dest_dir"
        tmp_in=$(mktemp "$dest_dir/.env_keys.in.XXXXXX")
        tmp_out=$(mktemp "$dest_dir/.env_keys.out.XXXXXX")
        cleanup_tmp() { rm -f "$tmp_in" "$tmp_out" "${tmp_out}.next"; }
        trap cleanup_tmp EXIT HUP INT TERM
        if printf "" | base64 -d >/dev/null 2>&1; then
            base64_decode="base64 -d"
        elif printf "" | base64 -D >/dev/null 2>&1; then
            base64_decode="base64 -D"
        else
            echo "base64 decode is unavailable" >&2
            exit 1
        fi
        $base64_decode > "$tmp_in"
        touch "$dest"
        chmod 600 "$dest"
        cp "$dest" "$tmp_out"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            var=${line#export }
            var=${var%%=*}
            grep -v "^export ${var}=" "$tmp_out" > "${tmp_out}.next" || true
            mv "${tmp_out}.next" "$tmp_out"
            printf "%s\n" "$line" >> "$tmp_out"
        done < "$tmp_in"
        chmod 600 "$tmp_out"
        mv "$tmp_out" "$dest"
        status=$?
        [ $status -eq 0 ] || cleanup_tmp
        trap - EXIT HUP INT TERM
        exit $status
    '
}

# --- SSH helpers ---
SSH_OPTS=()
SSH_SOCKET=""
SSH_SOCKET_DIR=""
REMOTE_HOST=""

_remote_exec() {
    local shellflag="$1" cmd="$2" quoted_cmd
    if [ -n "$SSH_SOCKET" ] && ! ssh -O check -o "ControlPath=$SSH_SOCKET" "$REMOTE_HOST" </dev/null &>/dev/null; then
        error "SSH connection dropped. Try re-running the script."
        return 1
    fi
    quoted_cmd="$(quote_for_bash_lc "$cmd")"
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "export TERM=dumb PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"; bash $shellflag $quoted_cmd"
}

# Run a remote command in a login shell. Login shells source the user's
# profile, so PATH picks up tools like claude/codex/gh. This is the default
# for almost every caller.
remote_exec() { _remote_exec -lc "$1"; }

# Run a remote command in a NON-login shell. Use for self-contained commands
# that only need coreutils (already on the default sshd PATH) and must not
# inherit the login shell's exit-time behavior: a login shell sources
# ~/.bash_logout when the `exit` builtin runs, and on some hosts (e.g.
# Ubuntu/CloudLab) its trailing `clear_console -q` returns non-zero with no
# tty. Under `set -e` that logout status becomes the command's exit status
# and masks an otherwise-successful run (see copy_local_file_to_remote).
remote_exec_nologin() { _remote_exec -c "$1"; }

# Echo the sha256 of a file on the remote, or nothing if it is absent or no
# sha tool is available. Runs in a non-login shell (sha256sum/shasum/awk are
# all on the default PATH) so its exit status stays trustworthy.
remote_file_sha256() {
    local remote_path="$1"
    remote_exec_nologin "
        dest=\"$remote_path\"
        if [ -f \"\$dest\" ]; then
            if command -v sha256sum >/dev/null 2>&1; then
                sha256sum \"\$dest\" 2>/dev/null | awk '{print \$1}'
            elif command -v shasum >/dev/null 2>&1; then
                shasum -a 256 \"\$dest\" 2>/dev/null | awk '{print \$1}'
            fi
        fi
    " 2>/dev/null || true
}

# Like remote_exec, but captures stdout reliably even when the remote's login
# shell prints an MOTD or `~/.profile` echoes before our command runs. The
# remote command runs under `bash -c` (no login) and is bracketed by sentinel
# markers; we extract the lines between them locally. Banner noise printed by
# the outer login shell ends up outside the markers and is stripped.
remote_capture() {
    if [ -n "$SSH_SOCKET" ] && ! ssh -O check -o "ControlPath=$SSH_SOCKET" "$REMOTE_HOST" </dev/null &>/dev/null; then
        error "SSH connection dropped. Try re-running the script."
        return 1
    fi
    local cmd="$1" quoted_cmd raw
    # Per-call nonce: a remote command that legitimately echoes a static
    # marker can't misalign the extractor.
    local nonce="$$_${RANDOM}_${RANDOM}"
    local begin="__DEPLOY_CAPTURE_${nonce}_BEGIN__"
    local end="__DEPLOY_CAPTURE_${nonce}_END__"
    quoted_cmd="$(quote_for_bash_lc "$cmd")"
    raw="$(ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "
        export TERM=dumb PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"
        printf '%s\n' '$begin'
        bash -c $quoted_cmd
        printf '%s\n' '$end'
    " 2>/dev/null)" || return 1
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { inside = 1; next }
        $0 == end   { found_end = 1; inside = 0; next }
        inside      { print }
        END         { exit (found_end ? 0 : 2) }
    ' <<<"$raw"
}

remote_copy() {
    retry scp -r "${SSH_OPTS[@]}" "$@"
}

# Like remote_copy, but skips the transfer if the single local file already
# matches the remote at $remote_path (by sha256). Respects FORCE_COPY=1.
# Usage: remote_copy_if_changed <local_file> <remote_path>
remote_copy_if_changed() {
    local local_path="$1" remote_path="$2"
    if [ "${FORCE_COPY:-0}" != 1 ] && [ -f "$local_path" ]; then
        local local_sum remote_sum
        local_sum="$(sha256_file "$local_path" 2>/dev/null || true)"
        # Use remote_capture so any login banner/MOTD on the remote shell
        # cannot pollute the captured sha (which is then string-compared).
        remote_sum="$(remote_capture "
            if [ -f \"$remote_path\" ]; then
                if command -v sha256sum >/dev/null 2>&1; then
                    sha256sum \"$remote_path\" 2>/dev/null | awk '{print \$1}'
                elif command -v shasum >/dev/null 2>&1; then
                    shasum -a 256 \"$remote_path\" 2>/dev/null | awk '{print \$1}'
                fi
            fi
        " 2>/dev/null || true)"
        if [ -n "$local_sum" ] && [ "$local_sum" = "$remote_sum" ]; then
            echo "    (unchanged — skipping $remote_path)"
            return 0
        fi
    fi
    remote_copy "$local_path" "$REMOTE_HOST:$remote_path"
}

# Dump remote state for a dotfile-style dir + a sentinel file inside it.
# Used by step_{claude,codex}_auth to (a) preflight the destination before
# the copy and (b) explain what went wrong after a copy failure. Hostile
# ownership/perms on the dest dir or an existing root-owned target file is
# the most common real-world cause of an opaque "Failed to copy …" report.
remote_dump_dir_state() {
    local dir="$1" file="$2"
    remote_exec "
        if [ -e $dir ]; then
            ls -ld $dir 2>/dev/null
            stat -c '%U:%G %a' $dir 2>/dev/null || stat -f '%Su:%Sg %p' $dir 2>/dev/null
        else
            echo 'no $dir directory'
        fi
        if [ -e $dir/$file ]; then
            ls -la $dir/$file 2>/dev/null
        else
            echo 'no existing $dir/$file'
        fi
    " 2>&1 | sed 's/^/    /'
}

remote_claude_supports_print() {
    remote_exec "claude --help 2>/dev/null | grep -q -- '-p, --print'"
}

remote_codex_supports_login_status() {
    remote_exec "codex login --help 2>/dev/null | grep -q '^[[:space:]]*status[[:space:]]'"
}

bootstrap_remote_gh_cli() {
    remote_exec '
        if command -v gh >/dev/null 2>&1; then
            exit 0
        fi

        if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
            echo "curl and tar are required to bootstrap gh" >&2
            exit 1
        fi

        os="$(uname -s 2>/dev/null || true)"
        arch="$(uname -m 2>/dev/null || true)"
        case "$os:$arch" in
            Linux:x86_64|Linux:amd64) gh_arch=amd64 ;;
            Linux:aarch64|Linux:arm64) gh_arch=arm64 ;;
            *) echo "unsupported remote platform for gh bootstrap: $os $arch" >&2; exit 1 ;;
        esac

        tmp="$(mktemp -d)"
        trap '\''rm -rf "$tmp"'\'' EXIT
        latest_url="$(curl -fsIL -o /dev/null -w "%{url_effective}" https://github.com/cli/cli/releases/latest)"
        version="${latest_url##*/v}"
        case "$version" in
            ""|"$latest_url") echo "could not determine latest gh version" >&2; exit 1 ;;
        esac

        mkdir -p "$HOME/.local/bin"
        curl -sfL -o "$tmp/gh.tar.gz" "https://github.com/cli/cli/releases/download/v${version}/gh_${version}_linux_${gh_arch}.tar.gz"
        tar -xzf "$tmp/gh.tar.gz" -C "$tmp"
        bin="$(find "$tmp" -type f -path "*/bin/gh" | head -1)"
        [ -n "$bin" ] || { echo "gh binary not found in archive" >&2; exit 1; }
        cp "$bin" "$HOME/.local/bin/gh"
        chmod 755 "$HOME/.local/bin/gh"
    '
}

# --- Remote git health ---
#
# On some remotes the login shell exports a stale GIT_EXEC_PATH/GIT_TEMPLATE_DIR
# (conda hooks, `module load`, a manual export) that no longer matches the git
# binary actually on PATH, or git itself is a partial install missing its
# git-core helpers. Either way `git-remote-https` can't be found and every
# HTTPS clone/pull dies with "git: 'remote-https' is not a git command". These
# helpers detect a git that can actually do HTTPS, and bootstrap one when none
# can.

# Print a self-contained POSIX-sh snippet that echoes the first git whose
# git-remote-https helper resolves (after clearing GIT_EXEC_PATH/
# GIT_TEMPLATE_DIR), or exits non-zero if none work. Kept as a string so it can
# run on the remote via remote_capture AND be eval'd locally by the test suite.
# The candidate list is overridable via DOTFILES_GIT_CANDIDATES purely as a
# test seam; production leaves it unset and uses the default list.
remote_git_probe_snippet() {
    cat <<'SNIPPET'
unset GIT_EXEC_PATH GIT_TEMPLATE_DIR
candidates="${DOTFILES_GIT_CANDIDATES:-$(command -v git 2>/dev/null) /usr/bin/git /usr/local/bin/git $HOME/.local/bin/git /bin/git}"
for g in $candidates; do
    [ -n "$g" ] && [ -x "$g" ] || continue
    ep="$("$g" --exec-path 2>/dev/null)" || continue
    if [ -n "$ep" ] && [ -x "$ep/git-remote-https" ]; then
        printf '%s\n' "$g"
        exit 0
    fi
    if command -v git-remote-https >/dev/null 2>&1; then
        printf '%s\n' "$g"
        exit 0
    fi
done
exit 1
SNIPPET
}

# Echo the remote git that can do HTTPS (or empty). remote_capture strips any
# login banner so the returned path is clean.
remote_usable_git() {
    remote_capture "$(remote_git_probe_snippet)" 2>/dev/null || true
}

# Best-effort, no-root portable git install for Debian/Ubuntu remotes whose git
# is missing its git-core files. Downloads the .debs, extracts them under
# ~/.local/git-portable, and drops a ~/.local/bin/git wrapper that points
# GIT_EXEC_PATH/GIT_TEMPLATE_DIR at the extracted tree. Returns non-zero on any
# non-Debian host or if the result still can't resolve git-remote-https, so the
# caller can fall back to a clear diagnostic.
bootstrap_remote_git() {
    remote_exec '
        set -u
        if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
            echo "portable git bootstrap only supports Debian/Ubuntu remotes" >&2
            exit 1
        fi

        prefix="$HOME/.local/git-portable"
        wrapper="$HOME/.local/bin/git"
        tmp="$(mktemp -d)" || exit 1
        trap '\''rm -rf "$tmp"'\'' EXIT

        rm -rf "$prefix"
        mkdir -p "$prefix" "$HOME/.local/bin"

        ( cd "$tmp" && apt-get download git git-man liberror-perl >/dev/null 2>&1 ) || {
            echo "apt-get download failed (no package index or offline?)" >&2
            exit 1
        }
        found=0
        for deb in "$tmp"/*.deb; do
            [ -f "$deb" ] || continue
            found=1
            dpkg -x "$deb" "$prefix" || { echo "dpkg -x failed for $deb" >&2; exit 1; }
        done
        [ "$found" = 1 ] || { echo "no .deb files downloaded" >&2; exit 1; }

        [ -x "$prefix/usr/bin/git" ] || { echo "extracted tree has no usr/bin/git" >&2; exit 1; }

        cat > "$wrapper" <<WRAP
#!/bin/sh
export GIT_EXEC_PATH="$prefix/usr/lib/git-core"
export GIT_TEMPLATE_DIR="$prefix/usr/share/git-core/templates"
exec "$prefix/usr/bin/git" "\$@"
WRAP
        chmod 755 "$wrapper"

        ep="$("$wrapper" --exec-path 2>/dev/null)" || { echo "bootstrapped git failed to run" >&2; exit 1; }
        [ -n "$ep" ] && [ -x "$ep/git-remote-https" ] || {
            echo "bootstrapped git still lacks git-remote-https" >&2
            exit 1
        }
    '
}

# Dump remote git state so an unrecoverable failure is actionable instead of an
# opaque "exit status 128".
remote_git_diagnose() {
    remote_exec '
        echo "git on PATH: $(command -v git 2>/dev/null || echo none)"
        git --version 2>&1 | head -1
        echo "exec-path:   $(git --exec-path 2>/dev/null || echo unknown)"
        ep="$(git --exec-path 2>/dev/null || true)"
        if [ -n "$ep" ] && [ -x "$ep/git-remote-https" ]; then
            echo "git-remote-https: present"
        else
            echo "git-remote-https: MISSING"
        fi
        echo "os: $(uname -srm 2>/dev/null || echo unknown)"
    ' 2>&1 | sed 's/^/    /'
}

remote_dotfiles_preflight_snippet() {
    cat <<'SNIPPET'
set -u
target="${DOTFILES_REMOTE_DIR:-$HOME/.dotfiles}"
if [ ! -d "$HOME" ] || [ ! -w "$HOME" ]; then
    echo "Remote HOME is not writable: $HOME" >&2
    ls -ld "$HOME" >&2 || true
    exit 1
fi
if [ -e "$target" ] && [ ! -d "$target" ]; then
    echo "Remote $target exists but is not a directory" >&2
    ls -la "$target" >&2 || true
    exit 1
fi
if [ -d "$target" ] && [ ! -d "$target/.git" ]; then
    if rmdir "$target" 2>/dev/null; then
        echo "  Removed empty non-git $target"
    else
        echo "Remote $target exists but is not a git repo and is not empty" >&2
        ls -la "$target" >&2 || true
        exit 1
    fi
fi
SNIPPET
}

remote_prepare_dotfiles_dir() {
    local remote_dir="$1"

    remote_exec "DOTFILES_REMOTE_DIR=\"$remote_dir\"; $(remote_dotfiles_preflight_snippet)"
}

remote_git_clone_cmd() {
    local git_env="$1" gdir="$2" good_git="$3" repo_url="$4" remote_dir="$5" use_gh="${6:-false}"

    if [ "$use_gh" = true ]; then
        printf "%s PATH='%s':\$PATH; '%s' -c credential.helper= -c credential.https://github.com.helper='!gh auth git-credential' clone %s %s" \
            "$git_env" "$gdir" "$good_git" "$repo_url" "$remote_dir"
    else
        printf "%s '%s' clone %s %s" "$git_env" "$good_git" "$repo_url" "$remote_dir"
    fi
}

remote_clone_diagnose() {
    local remote_dir="$1" good_git="$2"

    remote_exec "
        target=\"$remote_dir\"
        echo 'Remote clone diagnostics:'
        printf 'HOME=%s\n' \"\$HOME\"
        printf 'PWD=%s\n' \"\$PWD\"
        ls -ld \"\$HOME\" \"\$target\" 2>&1 || true
        stat -c '%U:%G %a %n' \"\$HOME\" \"\$target\" 2>/dev/null || \
            stat -f '%Su:%Sg %p %N' \"\$HOME\" \"\$target\" 2>/dev/null || true
        df -h \"\$HOME\" 2>/dev/null || true
        echo \"git: $good_git\"
        '$good_git' --version 2>&1 | head -1 || true
        if command -v gh >/dev/null 2>&1; then
            gh_path=\$(command -v gh)
            echo \"gh: \$gh_path\"
            gh --version 2>&1 | head -1 || true
            gh auth status 2>&1 | sed -n '1,8p' || true
            case \"\$gh_path\" in
                /snap/bin/*) echo 'note: gh is installed via Snap; deploy uses git clone to avoid Snap filesystem restrictions.' ;;
            esac
        else
            echo 'gh: none'
        fi
    " 2>&1 | sed 's/^/    /'
}

cleanup() {
    if [ -n "$SSH_SOCKET" ]; then
        ssh -O exit -o "ControlPath=$SSH_SOCKET" "$REMOTE_HOST" &>/dev/null || true
        rm -f "$SSH_SOCKET"
    fi
    if [ -n "$SSH_SOCKET_DIR" ]; then
        rmdir "$SSH_SOCKET_DIR" 2>/dev/null || rm -rf "$SSH_SOCKET_DIR" 2>/dev/null || true
    fi
}

# ============================================================
# Connection Setup
# ============================================================

deploy_main() {
parse_args "$@"
case "$?" in
    0) ;;
    2) return 0 ;;
    *) return 1 ;;
esac
export AUTO_YES
check_prereqs || return 1
trap cleanup EXIT

printf "\n${BOLD}=== Remote Server Deploy ===${RESET}\n\n"

# Offer to install gum (the TUI front-end) when missing and the session is
# interactive; declining falls back to the same read -rp flow used today.
if [ "$AUTO_YES" = false ] && [ -t 1 ] && [ "${NO_TUI:-0}" != 1 ] && ! command -v gum >/dev/null 2>&1; then
    info "Install 'gum' for nicer interactive prompts?"
    echo "  (charmbracelet/gum is a small static Go binary; falls back gracefully if you skip.)"
    if tui_confirm "Install gum now?" "yes"; then
        # shellcheck source=install.sh disable=SC1091
        if ( . "$DIR/install.sh" && install_gum ); then
            case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
            hash -r
        else
            warn "gum install failed; continuing with text prompts"
        fi
    fi
    echo ""
fi

# --- Host ---
REMOTE_HOST="$(tui_input "Remote host" "" "user@hostname or SSH config alias")"
if [ -z "$REMOTE_HOST" ]; then
    echo "Error: host is required"; exit 1
fi
if [[ "$REMOTE_HOST" =~ [[:space:]] ]]; then
    echo "Error: invalid host (contains spaces)"; exit 1
fi

# --- Auth method ---
AUTH_LABELS=(
    "Password (fresh server, no key yet)"
    "SSH key (already authorized)"
    "SSH key at custom path"
    "Password + 2FA/DUO (university/HPC systems)"
    "SSH config alias (Host entry in ~/.ssh/config)"
)
echo ""
AUTH_CHOICE="$(tui_choose "How do you connect to this server?" "${AUTH_LABELS[@]}")"
AUTH_METHOD=""
for i in "${!AUTH_LABELS[@]}"; do
    if [ "${AUTH_LABELS[$i]}" = "$AUTH_CHOICE" ]; then
        AUTH_METHOD=$((i + 1)); break
    fi
done
if [ -z "$AUTH_METHOD" ]; then
    echo "Error: no auth method selected"; exit 1
fi

SSH_PORT="22"
IDENTITY_FILE=""
CONNECT_TIMEOUT=15

# Method 3 (custom key) needs the key path before the port; method 5 (SSH
# config alias) skips the port prompt entirely and uses the alias as-is.
if [ "$AUTH_METHOD" = 3 ]; then
    # shellcheck disable=SC2088 # Placeholder text, not a path to expand.
    IDENTITY_FILE="$(tui_input "Path to SSH key" "" "~/.ssh/id_ed25519")"
    # Tilde-expand a leading ~ since gum/read both pass it through literally.
    # shellcheck disable=SC2088 # Literal pattern match on a leading "~/".
    case "$IDENTITY_FILE" in "~/"*) IDENTITY_FILE="$HOME/${IDENTITY_FILE#~/}" ;; esac
    if [ ! -f "$IDENTITY_FILE" ]; then
        echo "Error: key file not found: $IDENTITY_FILE"; exit 1
    fi
fi
if [ "$AUTH_METHOD" != 5 ]; then
    SSH_PORT="$(tui_input "SSH port" "22")"
fi

case "$AUTH_METHOD" in
    1|2)
        SSH_OPTS=(-o ConnectTimeout="$CONNECT_TIMEOUT" -o Port="$SSH_PORT")
        ;;
    3)
        SSH_OPTS=(-o ConnectTimeout="$CONNECT_TIMEOUT" -o Port="$SSH_PORT" -i "$IDENTITY_FILE")
        ;;
    4)
        # Keyboard-interactive auth (password + 2FA push) needs a longer
        # window for the user to approve the DUO prompt on their phone.
        CONNECT_TIMEOUT=90
        SSH_OPTS=(-o ConnectTimeout="$CONNECT_TIMEOUT" -o "PreferredAuthentications=keyboard-interactive,password" -o NumberOfPasswordPrompts=3 -o Port="$SSH_PORT")
        echo ""
        warn "2FA/DUO mode: you will be prompted for password + 2FA approval."
        echo "    Approve the push when prompted. Timeout: ${CONNECT_TIMEOUT}s."
        ;;
    5)
        SSH_OPTS=(-o ConnectTimeout=30)
        ;;
    *)
        echo "Error: invalid choice"; exit 1
        ;;
esac

# --- Jump host ---
echo ""
JUMP_HOST=""
if tui_confirm "Use a jump/bastion host?" "no"; then
    JUMP_HOST="$(tui_input "Jump host" "" "user@bastion")"
fi
if [ -n "$JUMP_HOST" ]; then
    SSH_OPTS+=(-J "$JUMP_HOST")
fi

# --- Establish ControlMaster (authenticates once, reuses for all commands) ---
# mktemp -d creates a mode-700 dir with a random suffix; the socket lives
# inside it so other users on the box can't predict the path or race the
# bind. cleanup() removes the dir on exit.
SSH_SOCKET_DIR="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/deploy.XXXXXX")" || {
    error "Failed to create SSH socket directory under ${TMPDIR:-/tmp}"
    exit 1
}
SSH_SOCKET="$SSH_SOCKET_DIR/socket"

echo ""
info "Connecting to $REMOTE_HOST..."
echo "  (Authenticate now — this is the only time you'll be prompted)"
echo ""

# ControlMaster runs in background after auth. User interacts with password/DUO here.
if ssh -fNM -o "ControlPath=$SSH_SOCKET" \
    -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
    "${SSH_OPTS[@]}" "$REMOTE_HOST"; then

    # Switch to multiplexed mode — no more interactive auth needed
    SSH_OPTS+=(-o "ControlPath=$SSH_SOCKET" -o BatchMode=yes)

    # Verify we can actually run commands
    if ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "echo ok" &>/dev/null; then
        success "Connected (session multiplexed — no more auth prompts)"
    else
        error "Connection established but cannot run commands on remote"
        echo "    The server may restrict non-interactive command execution."
        echo "    Try: ssh $REMOTE_HOST 'echo test' — manually to diagnose."
        cleanup
        exit 1
    fi
else
    SSH_SOCKET=""
    error "Cannot connect to $REMOTE_HOST"
    echo ""
    echo "  Troubleshooting:"
    if [ "$AUTH_METHOD" = "5" ]; then
        echo "    • Can you SSH manually?  ssh $REMOTE_HOST"
    else
        echo "    • Can you SSH manually?  ssh -p $SSH_PORT $REMOTE_HOST"
    fi
    echo "    • Is the hostname/port correct?"
    case "$AUTH_METHOD" in
        4) echo "    • Did you approve the DUO/2FA push in time? (timeout: ${CONNECT_TIMEOUT}s)" ;;
        1) echo "    • Is the password correct?" ;;
        2|3) echo "    • Is your SSH key authorized on the server?" ;;
        5) echo "    • Is your SSH config (~/.ssh/config) correct for this host?" ;;
    esac
    echo "    • Are you on the right network/VPN?"
    [ -n "$JUMP_HOST" ] && echo "    • Is the jump host ($JUMP_HOST) reachable?"
    echo ""
    if [ "$AUTH_METHOD" = "5" ]; then
        echo "  To debug: ssh -v $REMOTE_HOST"
    else
        echo "  To debug: ssh -v -p $SSH_PORT $REMOTE_HOST"
    fi
    exit 1
fi

# ============================================================
# Detect Available Items
# ============================================================

section "Scanning local credentials"

# SSH keys
LOCAL_SSH_KEYS=()
for f in ~/.ssh/id_*.pub; do
    [ -f "$f" ] && LOCAL_SSH_KEYS+=("${f%.pub}")
done

# GitHub CLI
LOCAL_GH_HOSTS_FILE="$(local_gh_hosts_file)"
GH_AUTH_STATE="$(auth_state_gh "$LOCAL_GH_HOSTS_FILE")"
GH_AUTH_STATUS="$(auth_state_status "$GH_AUTH_STATE")"
GH_AUTH_DETAIL="$(auth_state_detail "$GH_AUTH_STATE")"
HAS_GH_AUTH=false
[ "$GH_AUTH_STATUS" = "deployable" ] && HAS_GH_AUTH=true

# Claude Code
LOCAL_CLAUDE_CREDENTIALS_FILE="$(local_claude_credentials_file)"
CLAUDE_AUTH_STATE="$(auth_state_claude "$LOCAL_CLAUDE_CREDENTIALS_FILE")"
CLAUDE_AUTH_STATUS="$(auth_state_status "$CLAUDE_AUTH_STATE")"
CLAUDE_AUTH_DETAIL="$(auth_state_detail "$CLAUDE_AUTH_STATE")"
HAS_CLAUDE_AUTH=false
[ "$CLAUDE_AUTH_STATUS" = "deployable" ] && HAS_CLAUDE_AUTH=true

# Codex
LOCAL_CODEX_AUTH_FILE="$(local_codex_auth_file)"
CODEX_AUTH_STATE="$(auth_state_codex "$LOCAL_CODEX_AUTH_FILE")"
CODEX_AUTH_STATUS="$(auth_state_status "$CODEX_AUTH_STATE")"
CODEX_AUTH_DETAIL="$(auth_state_detail "$CODEX_AUTH_STATE")"
HAS_CODEX_AUTH=false
[ "$CODEX_AUTH_STATUS" = "deployable" ] && HAS_CODEX_AUTH=true

# API keys
API_KEYS_STATE="$(auth_state_api_keys)"
API_KEYS_STATUS="$(auth_state_status "$API_KEYS_STATE")"
API_KEYS_DETAIL="$(auth_state_detail "$API_KEYS_STATE")"
HAS_API_KEYS=false
[ "$API_KEYS_STATUS" = "deployable" ] && HAS_API_KEYS=true

# Google Drive (rclone)
LOCAL_RCLONE_CONFIG_FILE="$(local_rclone_config_file)"
RCLONE_AUTH_STATE="$(auth_state_rclone "$LOCAL_RCLONE_CONFIG_FILE")"
RCLONE_AUTH_STATUS="$(auth_state_status "$RCLONE_AUTH_STATE")"
RCLONE_AUTH_DETAIL="$(auth_state_detail "$RCLONE_AUTH_STATE")"
HAS_RCLONE_AUTH=false
[ "$RCLONE_AUTH_STATUS" = "deployable" ] && HAS_RCLONE_AUTH=true

# Print scan results
[ ${#LOCAL_SSH_KEYS[@]} -gt 0 ] && success "${#LOCAL_SSH_KEYS[@]} SSH key pair(s) found" || warn "No SSH keys found"
case "$GH_AUTH_STATUS" in
    deployable) success "GitHub CLI auth deployable ($GH_AUTH_DETAIL)" ;;
    blocked) warn "GitHub CLI auth not transferable: $GH_AUTH_DETAIL" ;;
    *) printf "  ${DIM}- GitHub CLI auth: %s${RESET}\n" "$GH_AUTH_DETAIL" ;;
esac
case "$RCLONE_AUTH_STATUS" in
    deployable) success "Google Drive auth deployable ($RCLONE_AUTH_DETAIL)" ;;
    blocked) warn "Google Drive auth not transferable: $RCLONE_AUTH_DETAIL" ;;
    *) printf "  ${DIM}- Google Drive auth: %s${RESET}\n" "$RCLONE_AUTH_DETAIL" ;;
esac
case "$CLAUDE_AUTH_STATUS" in
    deployable) success "Claude Code auth deployable ($CLAUDE_AUTH_DETAIL)" ;;
    blocked) warn "Claude Code auth not transferable: $CLAUDE_AUTH_DETAIL" ;;
    *) printf "  ${DIM}- Claude Code auth: %s${RESET}\n" "$CLAUDE_AUTH_DETAIL" ;;
esac
case "$CODEX_AUTH_STATUS" in
    deployable) success "Codex auth deployable ($CODEX_AUTH_DETAIL)" ;;
    blocked) warn "Codex auth not transferable: $CODEX_AUTH_DETAIL" ;;
    *) printf "  ${DIM}- Codex auth: %s${RESET}\n" "$CODEX_AUTH_DETAIL" ;;
esac
case "$API_KEYS_STATUS" in
    deployable) success "API keys deployable ($API_KEYS_DETAIL)" ;;
    blocked) warn "API keys not transferable: $API_KEYS_DETAIL" ;;
    *) printf "  ${DIM}- API keys: %s${RESET}\n" "$API_KEYS_DETAIL" ;;
esac

# ============================================================
# Step Selection Menu
# ============================================================

# Define steps: name, available, default-on
STEPS=()
STEPS_AVAILABLE=()
STEPS_SELECTED=()

add_step() {
    STEPS+=("$1")
    STEPS_AVAILABLE+=("$2")     # "yes" or "no"
    STEPS_SELECTED+=("$3")      # "on" or "off"
}

add_step "SSH keys"              "$([ ${#LOCAL_SSH_KEYS[@]} -gt 0 ] && echo yes || echo no)" "off"
add_step "GitHub CLI auth"       "$([ "$HAS_GH_AUTH" = true ] && echo yes || echo no)"      "on"
add_step "Clone repo & install.sh" "yes"                                                      "on"
add_step "Google Drive auth"     "$([ "$HAS_RCLONE_AUTH" = true ] && echo yes || echo no)"  "on"
add_step "Claude Code auth"      "$([ "$HAS_CLAUDE_AUTH" = true ] && echo yes || echo no)"  "on"
add_step "Codex auth"            "$([ "$HAS_CODEX_AUTH" = true ] && echo yes || echo no)"   "on"
add_step "API keys (env vars)"   "$([ "$HAS_API_KEYS" = true ] && echo yes || echo no)"    "on"

# Auto-deselect unavailable items
for i in "${!STEPS[@]}"; do
    if [ "${STEPS_AVAILABLE[$i]}" = "no" ]; then
        STEPS_SELECTED[$i]="off"
    fi
done

if [ "$AUTO_YES" = false ]; then
    echo ""
    info "What would you like to deploy?"
    echo ""

    available_steps=()
    preselected_csv=""
    unavailable_steps=()
    for i in "${!STEPS[@]}"; do
        if [ "${STEPS_AVAILABLE[$i]}" = "yes" ]; then
            available_steps+=("${STEPS[$i]}")
            if [ "${STEPS_SELECTED[$i]}" = "on" ]; then
                [ -n "$preselected_csv" ] && preselected_csv+=","
                preselected_csv+="${STEPS[$i]}"
            fi
        else
            unavailable_steps+=("${STEPS[$i]}")
        fi
    done

    if [ ${#available_steps[@]} -gt 0 ]; then
        if [ ${#unavailable_steps[@]} -gt 0 ]; then
            printf "  ${DIM}(skipping unavailable: %s)${RESET}\n" "$(IFS='|'; tmp="${unavailable_steps[*]}"; echo "${tmp//|/, }")"
            echo ""
        fi
        # tui_multi: gum when available, bash-native arrow multi-select when
        # not, or echoes the preselected set on a non-tty. On cancel (q / Esc
        # / Ctrl-C) it exits non-zero and we leave STEPS_SELECTED at defaults.
        if tui_result="$(tui_multi "Space toggles, Enter confirms" "$preselected_csv" "${available_steps[@]}")"; then
            for i in "${!STEPS[@]}"; do STEPS_SELECTED[$i]="off"; done
            while IFS= read -r picked; do
                [ -n "$picked" ] || continue
                for i in "${!STEPS[@]}"; do
                    if [ "${STEPS[$i]}" = "$picked" ]; then
                        STEPS_SELECTED[$i]="on"; break
                    fi
                done
            done <<< "$tui_result"
        fi
    fi
fi

# ============================================================
# Pre-flight Summary
# ============================================================

selected_names=()
for i in "${!STEPS[@]}"; do
    [ "${STEPS_SELECTED[$i]}" = "on" ] && selected_names+=("${STEPS[$i]}")
done

if [ ${#selected_names[@]} -eq 0 ]; then
    echo ""
    warn "Nothing selected. Exiting."
    exit 0
fi

printf "${BOLD}=== Deploy Summary ===${RESET}\n"
printf "  Target:  %s" "$REMOTE_HOST"
[ "$AUTH_METHOD" != "5" ] && printf ":%s" "$SSH_PORT"
echo ""
[ -n "$JUMP_HOST" ] && echo "  Jump:    $JUMP_HOST"
printf "  Auth:    "
case "$AUTH_METHOD" in
    1) echo "password (session multiplexed)" ;;
    2) echo "SSH key" ;;
    3) echo "SSH key ($IDENTITY_FILE)" ;;
    4) echo "password + 2FA/DUO (session multiplexed)" ;;
    5) echo "SSH config alias" ;;
esac
echo "  Steps:   ${selected_names[*]}"
echo "  Auth transfer:"
auth_transfer_count=0
if [ "${STEPS_SELECTED[0]}" = "on" ]; then
    echo "    - SSH public key authorization via ssh-copy-id"
    if [ -f ~/.ssh/known_hosts ]; then
        echo "    - ~/.ssh/known_hosts -> \$HOME/.ssh/known_hosts"
    fi
    echo "    - Private SSH keys: never copied"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "${STEPS_SELECTED[1]}" = "on" ]; then
    echo "    - GitHub CLI: $GH_AUTH_DETAIL"
    echo "      verify: gh auth status"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "${STEPS_SELECTED[3]}" = "on" ]; then
    echo "    - Google Drive: $RCLONE_AUTH_DETAIL"
    echo "      verify: rclone lsd gdrive:"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "${STEPS_SELECTED[4]}" = "on" ]; then
    echo "    - Claude Code: $CLAUDE_AUTH_DETAIL"
    echo "      verify: claude auth status / claude -p 'ping'"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "${STEPS_SELECTED[5]}" = "on" ]; then
    echo "    - Codex: $CODEX_AUTH_DETAIL"
    echo "      verify: codex login status"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "${STEPS_SELECTED[6]}" = "on" ]; then
    echo "    - API keys: $API_KEYS_DETAIL"
    echo "      values are never printed"
    auth_transfer_count=$((auth_transfer_count + 1))
fi
if [ "$auth_transfer_count" -eq 0 ]; then
    echo "    - none selected"
fi
echo ""

if ! tui_confirm "Proceed?" "yes"; then
    echo "Aborted."; exit 0
fi

# ============================================================
# Step Implementations
# ============================================================

step_ssh_keys() {
    section "SSH Keys"

    if ! command -v ssh-copy-id &>/dev/null; then
        error "ssh-copy-id is required for this step"
        echo "    Install openssh-client tools locally or skip the SSH keys step."
        return 1
    fi

    # Authorize local public key on remote
    echo "  Authorizing local public key on remote..."
    ssh-copy-id "${SSH_OPTS[@]}" "$REMOTE_HOST" 2>&1 | grep -v "^$" || warn "ssh-copy-id failed (key may already be authorized)"

    # Copy known_hosts so remote trusts github.com etc.
    if [ -f ~/.ssh/known_hosts ]; then
        remote_exec "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
        # shellcheck disable=SC2088 # Remote scp target; tilde expands on the server.
        if remote_copy_if_changed ~/.ssh/known_hosts '~/.ssh/known_hosts'; then
            remote_exec "chmod 644 ~/.ssh/known_hosts"
        else
            warn "Failed to copy known_hosts"
        fi
    fi

    echo "  Private SSH key copying is intentionally disabled."
    echo "    Use agent forwarding or generate a dedicated key on the remote if needed."
    success "Public key authorized"
}

step_gh_auth() {
    section "GitHub CLI Auth"
    local gh_token=""

    if [ "${GH_AUTH_STATUS:-missing}" != "deployable" ]; then
        error "GitHub CLI auth is not deployable"
        echo "    ${GH_AUTH_DETAIL:-not detected}"
        return 1
    fi

    if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null; then
        error "Local gh is not authenticated"
        echo "    Run 'gh auth login' locally first."
        return 1
    fi

    if ! remote_exec "command -v gh &>/dev/null"; then
        echo "  GitHub CLI not found on remote; bootstrapping to ~/.local/bin..."
        if ! bootstrap_remote_gh_cli; then
            error "GitHub CLI not found on remote and bootstrap failed"
            echo "    Install gh on the remote manually or skip this step."
            return 1
        fi
    fi

    if ! remote_exec "command -v gh &>/dev/null"; then
        error "GitHub CLI not found on remote after bootstrap"
        return 1
    fi

    gh_token="$(gh auth token 2>/dev/null || true)"
    # Validate against GitHub's known token prefixes so we never pipe
    # arbitrary content (banners, error messages, accidentally-captured
    # whitespace) into `gh auth login --with-token` on the remote.
    # ghp_ PAT classic, gho_ OAuth, ghu_ user-server, ghs_ server,
    # github_pat_ fine-grained PAT.
    if [ -n "$gh_token" ] && ! [[ "$gh_token" =~ ^(ghp_|gho_|ghu_|ghs_|github_pat_)[A-Za-z0-9_]+$ ]]; then
        warn "Local gh token failed shape validation; falling back to hosts.yml"
        gh_token=""
    fi
    if [ -n "$gh_token" ] && printf "%s" "$gh_token" | remote_exec '
        set -eu -o pipefail
        umask 077
        mkdir -p "$HOME/.config/gh"
        chmod 700 "$HOME/.config" "$HOME/.config/gh" 2>/dev/null || true
        GH_PROMPT_DISABLED=1 gh auth login --hostname github.com --git-protocol https --with-token >/dev/null
        gh auth setup-git >/dev/null 2>&1 || true
    '; then
        :
    elif local_gh_hosts_has_token "$LOCAL_GH_HOSTS_FILE" &&
        copy_local_file_to_remote "$LOCAL_GH_HOSTS_FILE" '$HOME/.config/gh/hosts.yml' 600; then
        remote_exec "
            set -u
            chmod 700 \"\$HOME/.config\" \"\$HOME/.config/gh\" 2>/dev/null || true
            gh auth setup-git >/dev/null 2>&1 || true
        "
    else
        error "Failed to copy GitHub CLI auth"
        echo "    Local gh token is not readable, and $LOCAL_GH_HOSTS_FILE has no plaintext token fallback."
        return 1
    fi

    if remote_exec "gh auth status >/dev/null 2>&1"; then
        success "GitHub CLI credentials copied and verified"
    else
        error "GitHub CLI credentials copied but auth did not verify"
        return 1
    fi
}

step_rclone_auth() {
    section "Google Drive Auth"

    if [ "${RCLONE_AUTH_STATUS:-missing}" != "deployable" ]; then
        error "Google Drive auth is not deployable"
        echo "    ${RCLONE_AUTH_DETAIL:-not detected}"
        return 1
    fi
    if [ ! -r "$LOCAL_RCLONE_CONFIG_FILE" ]; then
        error "Local rclone config is not readable"
        echo "    Expected: $LOCAL_RCLONE_CONFIG_FILE"
        return 1
    fi
    if ! remote_exec "command -v rclone >/dev/null 2>&1"; then
        error "rclone is not installed on the remote"
        echo "    Run the clone/setup step before Google Drive auth."
        return 1
    fi

    if ! copy_gdrive_auth_to_remote "$LOCAL_RCLONE_CONFIG_FILE"; then
        error "Failed to deploy the gdrive profile"
        echo "    Existing encrypted, symlinked, or unreadable remote configs are left unchanged."
        return 1
    fi

    if remote_exec "rclone lsd gdrive: --max-depth 1 >/dev/null 2>&1"; then
        success "Google Drive credentials copied and verified"
    else
        error "Google Drive credentials copied but gdrive: did not verify"
        return 1
    fi
}

step_claude_auth() {
    section "Claude Code Auth"

    if [ "${CLAUDE_AUTH_STATUS:-missing}" != "deployable" ]; then
        error "Claude Code auth is not deployable"
        echo "    ${CLAUDE_AUTH_DETAIL:-not detected}"
        return 1
    fi

    if [ ! -f "$LOCAL_CLAUDE_CREDENTIALS_FILE" ]; then
        error "Local Claude Code auth file not found"
        echo "    Expected: $LOCAL_CLAUDE_CREDENTIALS_FILE"
        return 1
    fi

    if ! remote_exec "command -v claude &>/dev/null"; then
        error "Claude Code CLI not found on remote"
        echo "    Run the clone/setup step before Claude Code auth."
        return 1
    fi

    if ! remote_exec "[ -f ~/.claude/settings.json ]"; then
        error "Claude Code settings not found on remote"
        echo "    Run the clone/setup step from this repo before Claude Code auth."
        return 1
    fi

    remote_dump_dir_state '$HOME/.claude' '.credentials.json'

    if copy_local_file_to_remote "$LOCAL_CLAUDE_CREDENTIALS_FILE" '$HOME/.claude/.credentials.json' 600; then
        success "Claude Code credentials copied to remote"
    else
        error "Failed to copy Claude Code credentials"
        echo "    Local:"
        ls -la "$LOCAL_CLAUDE_CREDENTIALS_FILE" 2>&1 | sed 's/^/      /'
        echo "    Remote (post-failure):"
        remote_dump_dir_state '$HOME/.claude' '.credentials.json'
        return 1
    fi

    if remote_claude_supports_print; then
        if remote_exec "claude -p 'ping' >/dev/null 2>&1"; then
            success "Claude Code auth verified on remote"
        else
            warn "Claude Code credentials copied but auth did not verify"
        fi
    else
        warn "Claude Code credentials copied, but this remote Claude Code build has no print mode for verification"
    fi
}

step_codex_auth() {
    section "Codex Auth"
    if [ "${CODEX_AUTH_STATUS:-missing}" != "deployable" ]; then
        error "Codex auth is not deployable"
        echo "    ${CODEX_AUTH_DETAIL:-not detected}"
        return 1
    fi

    if [ ! -f "$LOCAL_CODEX_AUTH_FILE" ]; then
        error "Local Codex auth file not found"
        echo "    Expected: $LOCAL_CODEX_AUTH_FILE"
        return 1
    fi

    if ! remote_exec "command -v codex &>/dev/null"; then
        error "Codex CLI not found on remote"
        echo "    Run the clone/setup step before Codex auth."
        return 1
    fi

    if ! remote_exec "[ -f ~/.codex/config.toml ]"; then
        error "Codex config not found on remote"
        echo "    Run the clone/setup step from this repo before Codex auth."
        return 1
    fi

    remote_dump_dir_state '$HOME/.codex' 'auth.json'

    if copy_local_file_to_remote "$LOCAL_CODEX_AUTH_FILE" '$HOME/.codex/auth.json' 600; then
        success "Codex auth file copied to remote"
    else
        error "Failed to copy Codex auth file"
        echo "    Local:"
        ls -la "$LOCAL_CODEX_AUTH_FILE" 2>&1 | sed 's/^/      /'
        echo "    Remote (post-failure):"
        remote_dump_dir_state '$HOME/.codex' 'auth.json'
        return 1
    fi

    if remote_codex_supports_login_status; then
        if remote_exec "codex login status >/dev/null 2>&1"; then
            success "Codex auth verified on remote"
        else
            warn "Codex auth file copied but login status did not verify"
        fi
    else
        warn "Codex auth file copied, but this remote Codex build has no 'login status' command for verification"
    fi
}

step_api_keys() {
    section "API Keys"

    local env_keys=""
    if [ "${API_KEYS_STATUS:-missing}" != "deployable" ]; then
        error "API keys are not deployable"
        echo "    ${API_KEYS_DETAIL:-not detected}"
        return 1
    fi

    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        env_keys+="export ANTHROPIC_API_KEY=$(shell_quote_env_value "$ANTHROPIC_API_KEY")"$'\n'
        echo "  • ANTHROPIC_API_KEY"
    fi
    if [ -n "${OPENAI_API_KEY:-}" ]; then
        env_keys+="export OPENAI_API_KEY=$(shell_quote_env_value "$OPENAI_API_KEY")"$'\n'
        echo "  • OPENAI_API_KEY"
    fi

    # Use base64 to safely transfer (avoids shell quoting issues)
    if remote_upsert_env_exports "$env_keys"; then
        ensure_remote_env_keys_loader
        success "API keys written to ~/.env_keys"
    else
        error "Failed to write API keys"
        return 1
    fi
}

step_clone_setup() {
    section "Clone Repo & Run Setup"

    # Derive repo slug and HTTPS URL from local remote
    local REPO_URL REPO_SLUG
    REPO_URL="$(git -C "$DIR" remote get-url origin 2>/dev/null | sed 's|git@github.com:|https://github.com/|')"
    if [ -z "$REPO_URL" ]; then
        local FALLBACK_REPO_URL="https://github.com/jianjianh1/dotfiles.git"
        warn "Could not read 'origin' remote from $DIR"
        echo "    Default: $FALLBACK_REPO_URL"
        if ! tui_confirm "Use the default repo URL above?" "no"; then
            error "Aborted. Re-run from inside the intended git clone, or set 'origin' first."
            return 1
        fi
        REPO_URL="$FALLBACK_REPO_URL"
    fi
    # Extract owner/repo slug (e.g. "jianjianh1/dotfiles")
    REPO_SLUG="$(echo "$REPO_URL" | sed 's|.*github\.com/||; s|\.git$||')"

    local REMOTE_DIR='$HOME/.dotfiles'

    # Make sure the remote git can actually do HTTPS before we lean on it. A
    # stale GIT_EXEC_PATH/GIT_TEMPLATE_DIR (inherited from the remote login
    # profile) or a partial git install makes every HTTPS clone/pull die with
    # "git: 'remote-https' is not a git command". Pick a git whose
    # git-remote-https helper resolves, bootstrapping a portable one if none
    # does, and run all git/gh commands below with the env sanitized.
    local GOOD_GIT GDIR
    local GIT_ENV='unset GIT_EXEC_PATH GIT_TEMPLATE_DIR;'
    GOOD_GIT="$(remote_usable_git)"
    if [ -z "$GOOD_GIT" ]; then
        echo "  Remote git can't run HTTPS operations — bootstrapping a portable git..."
        bootstrap_remote_git && GOOD_GIT="$(remote_usable_git)"
    fi
    if [ -z "$GOOD_GIT" ]; then
        error "No usable git on remote (git-remote-https helper missing)"
        remote_git_diagnose
        echo "    Remedy: install a complete git (e.g. 'sudo apt install git',"
        echo "    'module load git') and re-run."
        return 1
    fi
    GDIR="$(dirname "$GOOD_GIT")"

    if remote_exec "[ -d $REMOTE_DIR/.git ]"; then
        echo "  Repo exists — pulling latest..."
        # If the remote working tree is dirty, list what's dirty so the user
        # can recognise it later (git stash list won't show the file names)
        # and let `git pull --autostash` stash, fast-forward, and pop. Any
        # conflict on pop leaves the changes in `git stash list` for the
        # user to recover with `git stash pop` after SSHing in.
        local dirty
        dirty="$(remote_exec "$GIT_ENV cd $REMOTE_DIR && '$GOOD_GIT' status --porcelain" 2>/dev/null || true)"
        if [ -n "$dirty" ]; then
            warn "Remote $REMOTE_DIR has local changes — stashing for the pull:"
            printf "%s\n" "$dirty" | sed 's/^/    /'
        fi
        if ! remote_exec "$GIT_ENV cd $REMOTE_DIR && '$GOOD_GIT' pull --autostash --ff-only"; then
            error "git pull --autostash --ff-only failed on $REMOTE_DIR"
            echo "    The remote branch likely diverged. SSH in and reconcile,"
            echo "    then re-run. Any auto-stashed changes are in 'git stash list'."
            return 1
        fi
    else
        echo "  Cloning $REPO_SLUG..."
        if ! remote_prepare_dotfiles_dir "$REMOTE_DIR"; then
            error "Remote clone destination is not usable: $REMOTE_DIR"
            remote_clone_diagnose "$REMOTE_DIR" "$GOOD_GIT"
            return 1
        fi
        if remote_exec "command -v gh &>/dev/null && gh auth status &>/dev/null"; then
            # Use git for the filesystem write and gh only as an ephemeral
            # credential helper. Snap-packaged gh can authenticate fine but
            # may be confined away from hidden HOME paths like ~/.dotfiles.
            if ! remote_exec "$(remote_git_clone_cmd "$GIT_ENV" "$GDIR" "$GOOD_GIT" "$REPO_URL" "$REMOTE_DIR" true)"; then
                error "git clone failed using GitHub CLI credentials"
                remote_clone_diagnose "$REMOTE_DIR" "$GOOD_GIT"
                return 1
            fi
        else
            # Fallback to git clone over HTTPS
            if ! remote_exec "$(remote_git_clone_cmd "$GIT_ENV" "$GDIR" "$GOOD_GIT" "$REPO_URL" "$REMOTE_DIR" false)"; then
                error "git clone failed — verify GitHub auth (run 'gh auth login' on the remote)"
                remote_clone_diagnose "$REMOTE_DIR" "$GOOD_GIT"
                return 1
            fi
        fi
    fi

    echo "  Running install.sh..."
    if remote_exec "cd $REMOTE_DIR && ./install.sh"; then
        success "install.sh completed"
    else
        warn "install.sh exited with errors (check output above)"
        return 1
    fi
}

# ============================================================
# Execute Selected Steps
# ============================================================

STEP_FNS=(step_ssh_keys step_gh_auth step_clone_setup step_rclone_auth step_claude_auth step_codex_auth step_api_keys)

for i in "${!STEPS[@]}"; do
    [ "${STEPS_SELECTED[$i]}" = "on" ] || continue
    run_step "${STEPS[$i]}" "${STEP_FNS[$i]}"
done

# ============================================================
# Summary
# ============================================================

printf "${BOLD}===============================${RESET}\n"
if [ ${#FAILURES[@]} -gt 0 ]; then
    printf "${RED}Deploy complete with ${#FAILURES[@]} failure(s):${RESET}\n"
    for f in "${FAILURES[@]}"; do
        error "$f"
    done
    exit 1
else
    printf "${GREEN}Deploy complete! Remote server is ready.${RESET}\n"
    printf "  ssh"
    [ -n "$JUMP_HOST" ] && printf " -J %s" "$JUMP_HOST"
    [ "$AUTH_METHOD" != "5" ] && printf " -p %s" "$SSH_PORT"
    [ -n "$IDENTITY_FILE" ] && printf " -i %s" "$IDENTITY_FILE"
    printf " %s\n" "$REMOTE_HOST"
fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    deploy_main "$@"
fi
