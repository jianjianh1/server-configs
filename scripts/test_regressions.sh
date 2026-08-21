#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_remote_bash_lc_quote() (
    local tmp quoted
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME/.dotfiles/.git"

    quoted="$(quote_for_bash_lc '[ -d $HOME/.dotfiles/.git ]')"
    eval "bash -lc $quoted" || fail "remote bash -lc quoting lost \$HOME expansion"
)

test_portable_helpers() (
    local tmp file decoded decode_cmd
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    file="$tmp/file.txt"
    printf 'alpha\nremove-me\nbeta\n' > "$file"
    sha256_file "$file" >/dev/null || fail "sha256_file failed"
    decode_cmd="$(base64_decode_cmd)" || fail "base64_decode_cmd did not find a decoder"
    case "$decode_cmd" in
        "base64 -d") decoded="$(printf 'ok' | base64 | base64 -d)" ;;
        "base64 -D") decoded="$(printf 'ok' | base64 | base64 -D)" ;;
        *) fail "base64_decode_cmd returned unexpected command: $decode_cmd" ;;
    esac
    [ "$decoded" = "ok" ] || fail "base64_decode_cmd failed"

    delete_matching_lines "$file" '^remove-me$'
    grep -q remove-me "$file" && fail "delete_matching_lines left matching line"

    ln -s "$file" "$tmp/link"
    [ "$(portable_realpath "$tmp/link")" = "$(portable_realpath "$file")" ] ||
        fail "portable_realpath did not resolve symlink"

    [ "$(to_lower 'ALL')" = "all" ] || fail "to_lower failed"
)

test_backup_helpers_fail_loudly() (
    local tmp src
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    src="$tmp/src"
    printf 'x\n' > "$src"
    mkdir -p "$tmp/readonly"
    chmod 500 "$tmp/readonly"

    if backup_and_copy "$src" "$tmp/readonly/file" >/dev/null 2>&1; then
        fail "backup_and_copy returned success after a copy failure"
    fi
    if backup_and_link "$src" "$tmp/readonly/link" >/dev/null 2>&1; then
        fail "backup_and_link returned success after a link failure"
    fi
)

test_backup_rotation_idempotent_when_identical() (
    # Byte-identical short-circuit branch: existing .bak == dst -> delete
    # in place, no timestamped sibling created.
    local tmp dst
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    dst="$tmp/dst"
    printf 'identical content\n' > "$dst"
    printf 'identical content\n' > "${dst}.bak"

    _rotate_backup "$dst"

    [ -e "${dst}.bak" ] && fail "_rotate_backup left .bak in place when it matched dst"
    local extras
    extras="$(find "$tmp" -maxdepth 1 -name 'dst.bak.*' 2>/dev/null)"
    [ -z "$extras" ] || fail "_rotate_backup created a timestamped backup unnecessarily: $extras"
)

test_remote_capture_strips_banner() (
    local begin='__DEPLOY_CAPTURE_TEST_BEGIN__' end='__DEPLOY_CAPTURE_TEST_END__'
    _extract() {
        awk -v begin="$begin" -v end="$end" '
            $0 == begin { inside = 1; next }
            $0 == end   { found_end = 1; inside = 0; next }
            inside      { print }
            END         { exit (found_end ? 0 : 2) }
        ' <<<"$1"
    }

    local raw extracted rc=0
    raw="$(printf 'Welcome to FakeOS\nLast login: yesterday\n%s\nabc123def\nextra line\n%s\nfooter banner\n' "$begin" "$end")"
    extracted="$(_extract "$raw")" || rc=$?
    [ "$rc" -eq 0 ] || fail "extractor signaled truncation on complete input"
    [ "$extracted" = "abc123def
extra line" ] || fail "extractor returned wrong content: [$extracted]"

    raw="$(printf '%s\nabc\n' "$begin")"
    rc=0
    _extract "$raw" >/dev/null || rc=$?
    [ "$rc" -ne 0 ] || fail "extractor should signal truncation when end marker missing"
)

test_gh_latest_cache_memoizes() (
    local tmp curl_log
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/bin"
    curl_log="$tmp/curl.log"
    cat > "$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$curl_log"
case "\$*" in
    *-sfL*api.github.com*) printf '{"tag_name":"v9.9.9"}\n' ;;
    *-sfI*github.com*)     printf 'HTTP/2 302\r\nlocation: https://github.com/x/y/releases/tag/v9.9.9\r\n' ;;
esac
EOF
    chmod +x "$tmp/bin/curl"

    # Scope the cache file to $tmp so it gets cleaned up with the test;
    # without this override gh_latest leaks /tmp/.gh-latest-cache.<pid>.
    PATH="$tmp/bin:$PATH" _GH_LATEST_CACHE_FILE="$tmp/gh-cache" bash -c "
        . '$DIR/install.sh'
        v1=\"\$(gh_latest fake/repo)\"
        v2=\"\$(gh_latest fake/repo)\"
        [ \"\$v1\" = '9.9.9' ] || { echo \"v1=\$v1\" >&2; exit 1; }
        [ \"\$v2\" = '9.9.9' ] || { echo \"v2=\$v2\" >&2; exit 1; }
    " || fail "gh_latest did not return the expected version"

    local invocations
    # BSD wc on macOS right-pads its line count with spaces even when
    # reading from stdin -- strip them so the equality check works on
    # both runners.
    invocations="$(wc -l < "$curl_log" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    [ "$invocations" = 1 ] ||
        fail "gh_latest cache miss: expected 1 curl invocation, got $invocations"
)

test_cached_init_handles_empty_output() (
    local tmp run_log
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/bin"
    run_log="$tmp/run.log"
    cat > "$tmp/bin/silentool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$run_log"
exit 0
EOF
    chmod +x "$tmp/bin/silentool"
    # Age the fake binary so the cache file is unambiguously newer
    # under second-precision `[ -nt ]` (macOS /bin/bash is bash 3.2,
    # which doesn't compare sub-second mtimes). Without this the
    # freshness check fails and the function rewrites the cache every
    # call, breaking the memoization assertion.
    touch -t 197001020000 "$tmp/bin/silentool"

    # Extract just the function definition to a real file: sourcing via
    # `<(sed ...)` is flaky on macOS's bash 3.2 (the FIFO interacts badly
    # with `source`'s seek attempts), so use a temp file instead.
    sed -n '/^_dotfiles_load_cached_init() {$/,/^}$/p' "$DIR/shell/bashrc_exports" > "$tmp/cached_init.bash"

    HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash -c "
        . '$tmp/cached_init.bash'
        _dotfiles_load_cached_init silentool 'silentool init bash'
        _dotfiles_load_cached_init silentool 'silentool init bash'
        _dotfiles_load_cached_init silentool 'silentool init bash'
    " || fail "cached init helper returned non-zero"

    local invocations
    invocations="$(wc -l < "$run_log" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    [ "$invocations" = 1 ] ||
        fail "cached init re-ran on empty output: expected 1 invocation, got $invocations"
)

test_cached_init_evals_output_when_cache_unwritable() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    mkdir -p "$tmp/bin" "$tmp/home/.cache"
    printf 'blocks mkdir -p\n' > "$tmp/home/.cache/dotfiles"
    cat > "$tmp/bin/initool" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "init bash" ] || exit 2
printf '%s\n' 'export INITOOL_READY=1'
EOF
    chmod +x "$tmp/bin/initool"
    touch -t 197001020000 "$tmp/bin/initool"

    sed -n '/^_dotfiles_load_cached_init() {$/,/^}$/p' "$DIR/shell/bashrc_exports" > "$tmp/cached_init.bash"

    HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash -c "
        . '$tmp/cached_init.bash'
        _dotfiles_load_cached_init initool 'initool init bash'
        [ \"\${INITOOL_READY:-}\" = 1 ]
    " || fail "cached init fallback did not eval generated init output"
)

test_backup_rotation_preserves_edited_bak() (
    local tmp src dst rotated
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    src="$tmp/src"
    dst="$tmp/dst"
    printf 'src v1\n' > "$src"
    printf 'original user file\n' > "$dst"

    # Run 1: dst gets backed up to dst.bak (contents: "original user file"),
    # then dst is overwritten by src.
    backup_and_copy "$src" "$dst" >/dev/null 2>&1 || fail "first backup_and_copy failed"
    grep -q '^original user file$' "${dst}.bak" ||
        fail ".bak should contain pre-existing dst content after first run"

    # User edits the .bak (cribbing a snippet from the previous config).
    printf 'user-edited backup\n' > "${dst}.bak"

    # Run 2: src is bumped, so dst is rewritten. The user-edited .bak must
    # be rotated to .bak.<timestamp>, never silently destroyed.
    printf 'src v2\n' > "$src"
    backup_and_copy "$src" "$dst" >/dev/null 2>&1 || fail "second backup_and_copy failed"

    rotated="$(find "$tmp" -maxdepth 1 -name 'dst.bak.*' | head -1)"
    [ -n "$rotated" ] || fail "edited .bak was not rotated to a timestamped name"
    grep -q '^user-edited backup$' "$rotated" ||
        fail "rotated backup did not preserve user-edited content"

    # And the new .bak should hold the previous (run-1) dst content (src v1).
    grep -q '^src v1$' "${dst}.bak" ||
        fail ".bak after run 2 should contain run-1 dst content"
)

test_manifest_controls_uninstall() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME/.dotfiles-generated" "$HOME/.local/bin" "$HOME/.local/opt/nvim/bin" "$HOME/.codex"
    INSTALL_MANIFEST="$HOME/.dotfiles-generated/install-manifest.txt"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/gh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/rg"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/detect-theme"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/opt/nvim/bin/nvim"
    ln -s "$HOME/.local/opt/nvim/bin/nvim" "$HOME/.local/bin/nvim"
    : > "$HOME/.dotfiles-generated/tmux-theme.conf"
    ln -s "$HOME/.dotfiles-generated/tmux-theme.conf" "$HOME/.tmux-theme.conf"
    chmod +x "$HOME/.local/bin/gh" "$HOME/.local/bin/rg" "$HOME/.local/bin/detect-theme" "$HOME/.local/opt/nvim/bin/nvim"
    printf 'config = true\n' > "$HOME/.codex/config.toml"

    # shellcheck source=uninstall.sh
    . "$DIR/uninstall.sh"

    manifest_add_path "$HOME/.local/bin/gh"
    manifest_add_path "$HOME/.local/bin/detect-theme"
    manifest_add_path "$HOME/.codex/config.toml"

    remove_bin gh
    [ ! -e "$HOME/.local/bin/gh" ] || fail "tracked binary was not removed"

    remove_bin rg
    [ -e "$HOME/.local/bin/rg" ] || fail "untracked binary should not be removed"

    remove_tools
    [ ! -e "$HOME/.local/bin/detect-theme" ] || fail "tracked detect-theme was not removed by remove_tools"

    remove_symlinks >/dev/null
    [ ! -e "$HOME/.tmux-theme.conf" ] || fail "tmux-theme symlink was not removed"

    remove_tracked_path "$HOME/.codex/config.toml"
    [ ! -e "$HOME/.codex/config.toml" ] || fail "tracked config copy was not removed"

    manifest_add_path "$HOME/.local/bin/nvim"
    manifest_add_path "$HOME/.local/opt/nvim"
    remove_nvim
    [ ! -e "$HOME/.local/bin/nvim" ] || fail "tracked nvim symlink was not removed"
    [ ! -e "$HOME/.local/opt/nvim" ] || fail "tracked nvim opt dir was not removed"
)

test_scripts_source_without_side_effects() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    command -v setup_main >/dev/null || fail "setup_main missing after source"
    [ ! -e "$HOME/.dotfiles-generated" ] || fail "sourcing install.sh created generated state"
)

test_detect_theme_installs_to_local_bin() (
    local tmp target
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME/.dotfiles-generated"
    INSTALL_MANIFEST="$HOME/.dotfiles-generated/install-manifest.txt"
    BIN_DIR="$tmp/not-used"
    # shellcheck disable=SC2034 # consumed by sourced install.sh helpers
    DRY_RUN=false

    # shellcheck source=install.sh
    . "$DIR/install.sh"

    install_detect_theme >/dev/null || fail "install_detect_theme failed"
    [ -L "$HOME/.local/bin/detect-theme" ] || fail "detect-theme was not linked into ~/.local/bin"
    target="$(portable_realpath "$HOME/.local/bin/detect-theme" 2>/dev/null || true)"
    [ "$target" = "$DIR/scripts/detect-theme.sh" ] || fail "detect-theme symlink points at '$target'"
    manifest_contains_path "$HOME/.local/bin/detect-theme" ||
        fail "detect-theme local-bin path was not recorded in manifest"
    [ ! -e "$BIN_DIR/detect-theme" ] || fail "detect-theme should ignore BIN_DIR"
)

test_deploy_sources_without_prompting() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"
    command -v deploy_main >/dev/null || fail "deploy_main missing after source"
)

test_remote_dotfiles_preflight_snippet() (
    local tmp snippet
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"
    snippet="$(remote_dotfiles_preflight_snippet)"

    mkdir -p "$HOME/.dotfiles"
    DOTFILES_REMOTE_DIR="$HOME/.dotfiles" bash -c "$snippet" >/dev/null ||
        fail "preflight rejected an empty non-git dotfiles directory"
    [ ! -e "$HOME/.dotfiles" ] ||
        fail "preflight did not remove an empty non-git dotfiles directory"

    mkdir -p "$HOME/.dotfiles"
    printf 'keep\n' > "$HOME/.dotfiles/file"
    if DOTFILES_REMOTE_DIR="$HOME/.dotfiles" bash -c "$snippet" >/dev/null 2>&1; then
        fail "preflight accepted a non-empty non-git dotfiles directory"
    fi
    [ -f "$HOME/.dotfiles/file" ] ||
        fail "preflight removed user content from a non-empty dotfiles directory"
)

test_git_clone_command_uses_gh_only_for_credentials() (
    local tmp good_git cmd fallback_cmd
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME" "$tmp/bin"
    good_git="$tmp/bin/git"
    printf '#!/bin/sh\nexit 0\n' > "$good_git"
    chmod +x "$good_git"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"

    cmd="$(remote_git_clone_cmd 'unset GIT_EXEC_PATH GIT_TEMPLATE_DIR;' "$tmp/bin" "$good_git" "https://github.com/jianjianh1/dotfiles.git" '$HOME/.dotfiles' true)"
    printf '%s\n' "$cmd" | grep -Fq "'$good_git'" ||
        fail "gh-authenticated clone command did not use the selected git: $cmd"
    printf '%s\n' "$cmd" | grep -Fq "credential.https://github.com.helper='!gh auth git-credential'" ||
        fail "gh-authenticated clone command did not use gh credential helper: $cmd"
    printf '%s\n' "$cmd" | grep -Fq "clone https://github.com/jianjianh1/dotfiles.git" ||
        fail "gh-authenticated clone command did not clone the repo URL: $cmd"
    printf '%s\n' "$cmd" | grep -Fq '$HOME/.dotfiles' ||
        fail "gh-authenticated clone command did not target remote dotfiles dir: $cmd"
    if printf '%s\n' "$cmd" | grep -q 'gh repo clone'; then
        fail "gh-authenticated clone command still uses gh repo clone"
    fi

    fallback_cmd="$(remote_git_clone_cmd 'unset GIT_EXEC_PATH GIT_TEMPLATE_DIR;' "$tmp/bin" "$good_git" "https://github.com/jianjianh1/dotfiles.git" '$HOME/.dotfiles' false)"
    printf '%s\n' "$fallback_cmd" | grep -Fq "'$good_git' clone https://github.com/jianjianh1/dotfiles.git" ||
        fail "fallback clone command did not use plain git clone: $fallback_cmd"
    printf '%s\n' "$fallback_cmd" | grep -Fq '$HOME/.dotfiles' ||
        fail "fallback clone command did not target remote dotfiles dir: $fallback_cmd"
)

test_remote_git_probe_snippet() (
    local tmp snippet out good_exec good_git bad_exec bad_git
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME" "$tmp/bin"
    # Keep git-core off PATH so `command -v git-remote-https` only sees what we
    # plant here, making the cases deterministic on any host.
    export PATH="$tmp/bin:/usr/bin:/bin"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"
    snippet="$(remote_git_probe_snippet)"

    # Case 1: a git whose --exec-path holds an executable git-remote-https.
    good_exec="$tmp/good-exec"
    mkdir -p "$good_exec"
    printf '#!/bin/sh\ntrue\n' > "$good_exec/git-remote-https"
    chmod +x "$good_exec/git-remote-https"
    good_git="$tmp/good-git"
    printf '#!/bin/sh\n[ "$1" = "--exec-path" ] && echo "%s"\nexit 0\n' "$good_exec" > "$good_git"
    chmod +x "$good_git"
    out="$(DOTFILES_GIT_CANDIDATES="$good_git" bash -c "$snippet")" ||
        fail "probe rejected a healthy git"
    [ "$out" = "$good_git" ] || fail "probe returned '$out', expected '$good_git'"

    # Case 2: a git whose --exec-path lacks git-remote-https, none on PATH.
    bad_exec="$tmp/bad-exec"
    mkdir -p "$bad_exec"
    bad_git="$tmp/bad-git"
    printf '#!/bin/sh\n[ "$1" = "--exec-path" ] && echo "%s"\nexit 0\n' "$bad_exec" > "$bad_git"
    chmod +x "$bad_git"
    if out="$(DOTFILES_GIT_CANDIDATES="$bad_git" bash -c "$snippet")"; then
        fail "probe accepted a git with no git-remote-https (returned '$out')"
    fi
    [ -z "$out" ] || fail "probe emitted '$out' for an unusable git"

    # Case 3: broken --exec-path but git-remote-https present on PATH.
    printf '#!/bin/sh\ntrue\n' > "$tmp/bin/git-remote-https"
    chmod +x "$tmp/bin/git-remote-https"
    out="$(DOTFILES_GIT_CANDIDATES="$bad_git" bash -c "$snippet")" ||
        fail "probe rejected a git whose helper is on PATH"
    [ "$out" = "$bad_git" ] || fail "probe returned '$out', expected '$bad_git'"
)

test_auth_state_helpers() (
    local tmp state quoted quoted_value
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export PATH="$tmp/bin:/usr/bin:/bin"
    unset GH_CONFIG_DIR XDG_CONFIG_HOME CLAUDE_CONFIG_DIR CODEX_HOME
    unset ANTHROPIC_API_KEY OPENAI_API_KEY GH_STATUS_EXIT GH_TOKEN_VALUE CLAUDE_STATUS_EXIT
    mkdir -p "$HOME" "$tmp/bin"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"

    quoted="$(shell_quote_env_value "alpha'beta")"
    eval "quoted_value=$quoted"
    [ "$quoted_value" = "alpha'beta" ] ||
        fail "shell_quote_env_value did not preserve apostrophes"

    [ "$(local_gh_config_dir)" = "$HOME/.config/gh" ] ||
        fail "local_gh_config_dir did not default to ~/.config/gh"
    export XDG_CONFIG_HOME="$tmp/xdg"
    [ "$(local_gh_config_dir)" = "$tmp/xdg/gh" ] ||
        fail "local_gh_config_dir did not honor XDG_CONFIG_HOME"
    export GH_CONFIG_DIR="$tmp/gh-config"
    [ "$(local_gh_config_dir)" = "$tmp/gh-config" ] ||
        fail "local_gh_config_dir did not honor GH_CONFIG_DIR"

    state="$(auth_state_gh "$tmp/missing-hosts.yml")"
    [ "$(auth_state_status "$state")" = "missing" ] ||
        fail "auth_state_gh should be missing without gh"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "$1 $2" in' \
        '  "auth status") exit "${GH_STATUS_EXIT:-0}" ;;' \
        '  "auth token") [ -n "${GH_TOKEN_VALUE:-}" ] && printf "%s\n" "$GH_TOKEN_VALUE"; exit 0 ;;' \
        '  *) exit 1 ;;' \
        'esac' > "$tmp/bin/gh"
    chmod +x "$tmp/bin/gh"

    export GH_STATUS_EXIT=1
    state="$(auth_state_gh "$tmp/missing-hosts.yml")"
    [ "$(auth_state_status "$state")" = "missing" ] ||
        fail "auth_state_gh should be missing when gh is unauthenticated"

    export GH_STATUS_EXIT=0 GH_TOKEN_VALUE=secret-token
    state="$(auth_state_gh "$tmp/missing-hosts.yml")"
    [ "$(auth_state_status "$state")" = "deployable" ] &&
        printf '%s\n' "$state" | grep -q 'gh auth token' ||
        fail "auth_state_gh should prefer gh auth token"

    unset GH_TOKEN_VALUE
    mkdir -p "$(dirname "$(local_gh_hosts_file)")"
    printf 'github.com:\n    oauth_token: secret-token\n' > "$(local_gh_hosts_file)"
    state="$(auth_state_gh "$(local_gh_hosts_file)")"
    [ "$(auth_state_status "$state")" = "deployable" ] &&
        printf '%s\n' "$state" | grep -q 'hosts.yml' ||
        fail "auth_state_gh should fall back to plaintext hosts.yml token"

    rm -f "$(local_gh_hosts_file)"
    state="$(auth_state_gh "$(local_gh_hosts_file)")"
    [ "$(auth_state_status "$state")" = "blocked" ] ||
        fail "auth_state_gh should be blocked for keychain-only auth with unreadable token"

    export CLAUDE_CONFIG_DIR="$tmp/claude"
    state="$(auth_state_claude)"
    [ "$(auth_state_status "$state")" = "missing" ] ||
        fail "auth_state_claude should be missing without file or CLI login"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "$1 $2" in' \
        '  "auth status") exit "${CLAUDE_STATUS_EXIT:-0}" ;;' \
        '  *) exit 1 ;;' \
        'esac' > "$tmp/bin/claude"
    chmod +x "$tmp/bin/claude"

    export CLAUDE_STATUS_EXIT=0
    state="$(auth_state_claude)"
    [ "$(auth_state_status "$state")" = "blocked" ] ||
        fail "auth_state_claude should be blocked for login without credentials file"

    mkdir -p "$CLAUDE_CONFIG_DIR"
    printf '{}\n' > "$CLAUDE_CONFIG_DIR/.credentials.json"
    state="$(auth_state_claude)"
    [ "$(auth_state_status "$state")" = "deployable" ] ||
        fail "auth_state_claude should be deployable when credentials file exists"

    export CODEX_HOME="$tmp/codex"
    state="$(auth_state_codex)"
    [ "$(auth_state_status "$state")" = "missing" ] ||
        fail "auth_state_codex should be missing without auth.json"
    mkdir -p "$CODEX_HOME"
    printf '{}\n' > "$CODEX_HOME/auth.json"
    state="$(auth_state_codex)"
    [ "$(auth_state_status "$state")" = "deployable" ] ||
        fail "auth_state_codex should be deployable with auth.json"

    state="$(auth_state_api_keys)"
    [ "$(auth_state_status "$state")" = "missing" ] ||
        fail "auth_state_api_keys should be missing without env vars"
    export OPENAI_API_KEY=test-key
    state="$(auth_state_api_keys)"
    [ "$(auth_state_status "$state")" = "deployable" ] &&
        printf '%s\n' "$state" | grep -q 'OPENAI_API_KEY' ||
        fail "auth_state_api_keys should list deployable key names"
)

test_rclone_config_helpers() (
    local tmp config section destination state mode before
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    unset RCLONE_CONFIG XDG_CONFIG_HOME
    mkdir -p "$HOME/.config/rclone"
    config="$HOME/.config/rclone/rclone.conf"

    [ "$(rclone_config_file)" = "$config" ] ||
        fail "rclone_config_file did not select the standard config path"
    state="$(rclone_gdrive_auth_state "$config")"
    [ "${state%%|*}" = missing ] || fail "missing rclone config was not reported missing"

    printf '%s\n' \
        '[other]' \
        'type = s3' \
        'access_key_id = keep-me' \
        '' \
        '[gdrive]' \
        'type = drive' \
        'client_id = personal-client.apps.googleusercontent.com' \
        'client_secret = fake-client-secret' \
        'scope = drive' \
        'token = {"access_token":"fake-access-token"}' > "$config"
    chmod 600 "$config"

    state="$(rclone_gdrive_auth_state "$config")"
    [ "${state%%|*}" = deployable ] || fail "valid gdrive config was not deployable: $state"
    case "$state" in
        *fake-client-secret*|*fake-access-token*) fail "auth state exposed rclone secrets" ;;
    esac

    section="$tmp/gdrive.conf"
    rclone_extract_remote_section "$config" gdrive > "$section"
    rclone_gdrive_profile_valid "$section" || fail "extracted gdrive profile was not valid"
    if grep -q '^\[other\]$' "$section"; then
        fail "gdrive extraction included an unrelated remote"
    fi

    destination="$tmp/remote/rclone.conf"
    mkdir -p "$(dirname "$destination")"
    printf '%s\n' \
        '[remote-only]' \
        'type = sftp' \
        'host = preserve.example' \
        '' \
        '[gdrive]' \
        'type = drive' \
        'scope = drive.file' \
        'token = old-token' > "$destination"
    rclone_merge_gdrive_section "$section" "$destination" || fail "gdrive section merge failed"
    grep -q '^\[remote-only\]$' "$destination" || fail "merge removed a remote-only profile"
    grep -q '^host = preserve.example$' "$destination" || fail "merge changed unrelated settings"
    grep -q '^scope = drive$' "$destination" || fail "merge did not install the full-drive profile"
    if grep -q 'old-token' "$destination"; then fail "merge retained the old gdrive token"; fi
    [ "$(grep -c '^\[gdrive\]$' "$destination")" -eq 1 ] || fail "merge created duplicate gdrive sections"
    mode="$(stat -c '%a' "$destination" 2>/dev/null || stat -f '%Lp' "$destination")"
    [ "$mode" = 600 ] || fail "merged rclone config mode is $mode, expected 600"

    before="$(sha256_file "$destination")"
    printf 'RCLONE_ENCRYPT_V0:\nnot-a-real-encrypted-config\n' > "$destination"
    if rclone_merge_gdrive_section "$section" "$destination" >/dev/null 2>&1; then
        fail "merge accepted an encrypted destination"
    fi
    grep -q '^RCLONE_ENCRYPT_V0:' "$destination" || fail "failed merge changed encrypted destination"

    printf '%s\n' \
        '[gdrive]' \
        'type = drive' \
        'scope = drive.file' \
        'token = restricted-token' > "$config"
    state="$(rclone_gdrive_auth_state "$config")"
    [ "${state%%|*}" = blocked ] || fail "restricted/shared-client config was not blocked"
    [ -n "$before" ] || fail "sha256 helper returned an empty digest"
)

test_rclone_deploy_merges_only_gdrive() (
    local tmp local_home remote_home config destination first_sum
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    local_home="$tmp/local-home"
    remote_home="$tmp/remote-home"
    mkdir -p "$local_home/.config/rclone" "$remote_home/.config/rclone"
    export HOME="$local_home"
    config="$HOME/.config/rclone/rclone.conf"
    printf '%s\n' \
        '[local-only]' \
        'type = dropbox' \
        'token = do-not-copy' \
        '' \
        '[gdrive]' \
        'type = drive' \
        'client_id = personal-client.apps.googleusercontent.com' \
        'client_secret = fake-client-secret' \
        'scope = drive' \
        'token = {"access_token":"fake-access-token"}' > "$config"
    chmod 600 "$config"
    destination="$remote_home/.config/rclone/rclone.conf"
    printf '%s\n' \
        '[remote-only]' \
        'type = sftp' \
        'host = preserve.example' > "$destination"

    # shellcheck source=deploy.sh
    . "$DIR/deploy.sh"
    remote_exec() { HOME="$remote_home" bash -c "$1"; }
    remote_capture() { HOME="$remote_home" bash -c "$1"; }
    copy_local_file_to_remote() {
        local source="$1" remote_path="$2" mode="${3:-600}" resolved
        resolved="$(printf '%s' "$remote_path" | sed "s|^\\\$HOME|$remote_home|")"
        mkdir -p "$(dirname "$resolved")" || return 1
        cp "$source" "$resolved" || return 1
        chmod "$mode" "$resolved"
    }

    FORCE_COPY=0
    copy_gdrive_auth_to_remote "$config" >/dev/null || fail "gdrive deploy helper failed"
    grep -q '^\[remote-only\]$' "$destination" || fail "deploy removed a remote-only profile"
    grep -q '^\[gdrive\]$' "$destination" || fail "deploy did not add gdrive"
    if grep -q '^\[local-only\]$' "$destination"; then fail "deploy copied an unrelated local profile"; fi
    first_sum="$(sha256_file "$destination")"
    copy_gdrive_auth_to_remote "$config" >/dev/null || fail "idempotent gdrive deploy failed"
    [ "$first_sum" = "$(sha256_file "$destination")" ] || fail "idempotent deploy rewrote the config"
)

test_rclone_install_uses_managed_local_bin() (
    local tmp curl_log
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME/.dotfiles-generated" "$tmp/bin"
    INSTALL_MANIFEST="$HOME/.dotfiles-generated/install-manifest.txt"
    : > "$INSTALL_MANIFEST"
    curl_log="$tmp/curl.log"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'out=""; url=""' \
        'while [ $# -gt 0 ]; do' \
        '  case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac' \
        'done' \
        'printf "%s\n" "$url" >> "$RCLONE_TEST_CURL_LOG"' \
        'printf "fake zip\n" > "$out"' > "$tmp/bin/curl"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'dest=""' \
        'while [ $# -gt 0 ]; do' \
        '  case "$1" in -d) dest="$2"; shift 2 ;; *) shift ;; esac' \
        'done' \
        'mkdir -p "$dest/rclone-test"' \
        'printf "#!/usr/bin/env bash\\nprintf '\''rclone v9.9.9\\n'\''\\n" > "$dest/rclone-test/rclone"' \
        'chmod +x "$dest/rclone-test/rclone"' > "$tmp/bin/unzip"
    chmod +x "$tmp/bin/curl" "$tmp/bin/unzip"

    export PATH="$tmp/bin:/usr/bin:/bin"
    export RCLONE_TEST_CURL_LOG="$curl_log"
    FORCE=false
    NO_UPDATE=false
    DRY_RUN=false
    TEST_RCLONE_ARCH=x86_64

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    rclone_latest() { printf '9.9.9\n'; }
    machine_arch() { printf '%s\n' "$TEST_RCLONE_ARCH"; }
    report_rclone_gdrive_config() { :; }

    install_rclone >/dev/null || fail "managed rclone install failed"
    [ -x "$HOME/.local/bin/rclone" ] || fail "rclone was not installed into ~/.local/bin"
    manifest_contains_path "$HOME/.local/bin/rclone" || fail "rclone was not recorded in the manifest"
    grep -q 'rclone-v9.9.9-linux-amd64.zip' "$curl_log" || fail "rclone selected the wrong amd64 asset"

    TEST_RCLONE_ARCH=aarch64
    FORCE=true
    install_rclone >/dev/null || fail "forced arm64 rclone install failed"
    tail -1 "$curl_log" | grep -q 'rclone-v9.9.9-linux-arm64.zip' ||
        fail "rclone selected the wrong arm64 asset"
)

test_setup_dry_run_is_non_mutating() (
    local tmp output
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    output="$(HOME="$tmp/home" bash "$DIR/install.sh" --dry-run 2>&1)" ||
        fail "install.sh --dry-run failed: $output"
    printf '%s\n' "$output" | grep -q '\[dry-run\]' ||
        fail "install.sh --dry-run did not report dry-run steps"
    [ ! -e "$tmp/home/.dotfiles-generated" ] ||
        fail "install.sh --dry-run created generated state"
)

test_chpc_config_rendering_uses_repo_files() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export HOSTNAME="login1.chpc.utah.edu"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    mkdir -p "$GENERATED_DIR"
    render_compat_configs

    [ "$CLAUDE_SETTINGS_MODE" = "repo" ] ||
        fail "CHPC Claude settings should use the repo file directly (got mode '$CLAUDE_SETTINGS_MODE')"
    [ "$CLAUDE_SETTINGS_SRC" = "$DIR/ai/claude_settings.json" ] ||
        fail "CHPC Claude settings src should be the repo file (got '$CLAUDE_SETTINGS_SRC')"
    [ "$CODEX_CONFIG_MODE" = "repo" ] ||
        fail "CHPC Codex config should use the repo file directly (got mode '$CODEX_CONFIG_MODE')"
    [ "$CODEX_CONFIG_SRC" = "$DIR/ai/codex_config.toml" ] ||
        fail "CHPC Codex config src should be the repo file (got '$CODEX_CONFIG_SRC')"

    grep -q '"defaultMode": "bypassPermissions"' "$DIR/ai/claude_settings.json" ||
        fail "Repo Claude settings should use bypassPermissions per no-restriction defaults"
    grep -q '"enabled": false' "$DIR/ai/claude_settings.json" ||
        fail "Repo Claude settings should disable sandboxing per no-restriction defaults"

    grep -q 'approval_policy = "never"' "$DIR/ai/codex_config.toml" ||
        fail "Repo Codex config should auto-approve per no-restriction defaults"
    grep -q 'sandbox_mode = "danger-full-access"' "$DIR/ai/codex_config.toml" ||
        fail "Repo Codex config should use danger-full-access per no-restriction defaults"
)

test_chpc_module_loads_initialize_module_command() (
    local tmp bash_compat init_line claude_line codex_line
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export HOSTNAME="login1.chpc.utah.edu"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    mkdir -p "$GENERATED_DIR"
    # shellcheck disable=SC2034 # render_bash_compat reads module variables indirectly.
    CLAUDE_MODULE="claude-code"
    # shellcheck disable=SC2034 # render_bash_compat reads module variables indirectly.
    CODEX_MODULE="codex"
    render_bash_compat

    bash_compat="$GENERATED_DIR/bashrc_compat"
    init_line="$(grep -n 'for init in /etc/profile.d/modules.sh' "$bash_compat" | cut -d: -f1)"
    claude_line="$(grep -n '_dotfiles_module_load claude-code' "$bash_compat" | cut -d: -f1)"
    codex_line="$(grep -n '_dotfiles_module_load codex' "$bash_compat" | cut -d: -f1)"

    [ -n "$init_line" ] || fail "module initialization block missing"
    [ -n "$claude_line" ] || fail "Claude module load missing"
    [ -n "$codex_line" ] || fail "Codex module load missing"
    [ "$init_line" -lt "$claude_line" ] ||
        fail "Claude module load should come after module initialization"
    [ "$init_line" -lt "$codex_line" ] ||
        fail "Codex module load should come after module initialization"

    # Module loads must be gated on interactive shells so SLURM job-step
    # shells don't unintentionally swap modules at startup.
    grep -q 'case $- in' "$bash_compat" ||
        fail "module section missing interactive-shell guard"
)

test_module_var_reset_clears_stale_values() (
    local tmp bash_compat
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    mkdir -p "$GENERATED_DIR"

    CLAUDE_MODULE="stale-claude"
    CODEX_MODULE="stale-codex"
    reset_module_vars
    [ -z "${CLAUDE_MODULE:-}" ] || fail "reset_module_vars did not clear CLAUDE_MODULE"
    [ -z "${CODEX_MODULE:-}" ] || fail "reset_module_vars did not clear CODEX_MODULE"

    render_bash_compat
    bash_compat="$GENERATED_DIR/bashrc_compat"
    if grep -Eq '(_dotfiles_module_load|module load) stale-' "$bash_compat"; then
        fail "stale module values leaked into bash compat config"
    fi
)

test_nvim_manifest_records_only_owned_layout() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    mkdir -p "$GENERATED_DIR" "$HOME/.local/bin" "$HOME/.local/opt/nvim/bin"
    : > "$INSTALL_MANIFEST"

    record_nvim_manifest
    if [ -s "$INSTALL_MANIFEST" ]; then
        fail "record_nvim_manifest should not track unowned nvim paths"
    fi

    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/opt/nvim/bin/nvim"
    chmod +x "$HOME/.local/opt/nvim/bin/nvim"
    ln -s "$HOME/.local/opt/nvim/bin/nvim" "$HOME/.local/bin/nvim"

    record_nvim_manifest
    manifest_contains_path "$HOME/.local/bin/nvim" ||
        fail "record_nvim_manifest did not track owned nvim symlink"
    manifest_contains_path "$HOME/.local/opt/nvim" ||
        fail "record_nvim_manifest did not track owned nvim opt dir"
)

test_nvim_install_selects_legacy_and_arm_assets() (
    local tmp calls
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    export HOME="$tmp/home"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    # shellcheck disable=SC2034 # consumed by install_nvim/install helpers
    FORCE=true
    # shellcheck disable=SC2034 # consumed by install_nvim/install helpers
    CHPC_USE_MODULES=false

    is_macos() { return 1; }
    is_chpc() { return 1; }

    calls="$tmp/old-glibc-calls"
    machine_arch() { printf 'x86_64'; }
    glibc_version() { printf '2.17'; }
    install_nvim_tarball() {
        printf 'tarball %s %s\n' "$1" "$2" >> "$calls"
        case "$2" in
            *neovim-releases*) return 0 ;;
            *) return 1 ;;
        esac
    }
    install_nvim_appimage() {
        printf 'appimage %s %s\n' "$1" "$2" >> "$calls"
        return 1
    }

    install_nvim >/dev/null 2>&1 ||
        fail "old-glibc nvim install should use legacy tarball"
    grep -q 'neovim-releases' "$calls" ||
        fail "old-glibc nvim install did not use legacy release repo"
    if grep -q 'appimage' "$calls"; then
        fail "old-glibc nvim install should skip AppImage"
    fi

    calls="$tmp/arm-calls"
    machine_arch() { printf 'aarch64'; }
    glibc_version() { :; }
    install_nvim_tarball() {
        printf 'tarball %s %s\n' "$1" "$2" >> "$calls"
        case "$2" in
            *nvim-linux-arm64.tar.gz) return 0 ;;
            *) return 1 ;;
        esac
    }
    install_nvim_appimage() {
        printf 'appimage %s %s\n' "$1" "$2" >> "$calls"
        return 1
    }

    install_nvim >/dev/null 2>&1 ||
        fail "aarch64 nvim install should use arm64 release asset"
    grep -q 'nvim-linux-arm64.tar.gz' "$calls" ||
        fail "aarch64 nvim install did not use arm64 release asset"
)

test_pre_commit_no_staged_files() (
    git -C "$DIR" diff --cached --quiet || return 0
    "$DIR/.githooks/pre-commit" || fail "pre-commit failed with no staged files"
)

test_pre_commit_blocks_secrets() (
    local tmp clone hook
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    clone="$tmp/clone"
    hook="$DIR/.githooks/pre-commit"
    git init -q "$clone"
    cd "$clone" || fail "cd to $clone failed"

    # 1) text blob containing an OpenAI-shaped key must be blocked
    printf 'OPENAI_API_KEY=sk-proj-%s\n' "$(printf 'a%.0s' {1..40})" > leaky.env
    git add leaky.env
    if "$hook" >/dev/null 2>&1; then
        fail "pre-commit should block file containing sk-proj-... token"
    fi
    git reset -q HEAD -- leaky.env
    rm -f leaky.env

    # 2) OpenAI project keys use the URL-safe alphabet, including _ and -
    printf 'OPENAI_API_KEY=%s%s\n' 'sk-proj-' 'abc_DEF-0123456789abc_DEF-0123456789' > leaky.env
    git add leaky.env
    if "$hook" >/dev/null 2>&1; then
        fail "pre-commit should block OpenAI project token with _ and -"
    fi
    git reset -q HEAD -- leaky.env
    rm -f leaky.env

    # 3) key-shaped filename must be blocked even when content looks innocuous
    printf 'not actually a key\n' > server.pem
    git add server.pem
    if "$hook" >/dev/null 2>&1; then
        fail "pre-commit should block file with .pem extension"
    fi
    git reset -q HEAD -- server.pem
    rm -f server.pem

    # 4) benign content with sk- prefix but only 8 chars must NOT be blocked
    printf 'see anchor sk-foo123\n' > notes.md
    git add notes.md
    if ! "$hook" >/dev/null 2>&1; then
        fail "pre-commit should NOT block short sk- string in markdown"
    fi
)

test_theme_detection() (
    # Stage detect-theme.sh at the path the function calls into
    # ($HOME/.local/bin/detect-theme), pointed at a tmp HOME so we don't
    # touch the developer's real $HOME.
    local tmp_home
    tmp_home="$(mktemp -d)"
    trap 'rm -rf "$tmp_home"' EXIT
    mkdir -p "$tmp_home/.local/bin"
    ln -s "$DIR/scripts/detect-theme.sh" "$tmp_home/.local/bin/detect-theme"
    chmod +x "$DIR/scripts/detect-theme.sh"

    local fn
    fn="$(sed -n '/^_dotfiles_detect_theme() {/,/^}/p' "$DIR/shell/bashrc_exports")"
    [ -n "$fn" ] || fail "could not extract _dotfiles_detect_theme from bashrc_exports"

    local out
    # TMUX=fake skips the OSC 11 probe inside detect-theme so the test doesn't
    # write to the suite-runner's controlling tty.

    # Pre-set override wins over every fallback.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake DOTFILES_THEME=light \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "pre-set override not honoured: got '$out'"

    # COLORFGBG dark bg → dark.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake COLORFGBG='15;0' \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "dark" ] || fail "COLORFGBG=15;0 should resolve dark: got '$out'"

    # COLORFGBG light bg → light.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake COLORFGBG='0;15' \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "COLORFGBG=0;15 should resolve light: got '$out'"

    # No tty, no COLORFGBG, non-darwin → falls through to dark.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake OSTYPE=linux-gnu \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "dark" ] || fail "fallback should be dark: got '$out'"

    # Helper missing → bashrc function still falls back to dark.
    out="$(env -i HOME="$(mktemp -d)" PATH="$PATH" TMUX=fake \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "dark" ] || fail "missing helper should still yield dark: got '$out'"

    # VS Code Remote-SSH storage.json → light themeBackground resolves light.
    # Staged at $tmp_home/.vscode-server/... so detect-theme.sh's loop hits it.
    mkdir -p "$tmp_home/.vscode-server/data/User/globalStorage"
    printf '{"themeBackground":"#ffffff"}\n' \
        > "$tmp_home/.vscode-server/data/User/globalStorage/storage.json"
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake TERM_PROGRAM=vscode \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "Remote-SSH storage.json white bg should resolve light: got '$out'"

    # VS Code Remote-SSH storage.json → dark themeBackground resolves dark.
    printf '{"themeBackground":"#1e1e1e"}\n' \
        > "$tmp_home/.vscode-server/data/User/globalStorage/storage.json"
    out="$(env -i HOME="$tmp_home" PATH="$PATH" TMUX=fake TERM_PROGRAM=vscode \
        bash -c "$fn"'; _dotfiles_detect_theme; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "dark" ] || fail "Remote-SSH storage.json dark bg should resolve dark: got '$out'"

    # Clean up so subsequent assertions don't inherit the staged file.
    rm -rf "$tmp_home/.vscode-server"
)

test_theme_function() (
    # The `theme` function lives in bashrc_aliases and depends on
    # _dotfiles_detect_theme from bashrc_exports. Extract both, source in
    # order, then exercise light/dark/auto. No tmux integration tested here —
    # the function guards `tmux set-environment` on `$TMUX`, and we run with
    # TMUX unset (env -i) so that branch is a no-op.
    local tmp_home
    tmp_home="$(mktemp -d)"
    trap 'rm -rf "$tmp_home"' EXIT
    mkdir -p "$tmp_home/.local/bin"
    ln -s "$DIR/scripts/detect-theme.sh" "$tmp_home/.local/bin/detect-theme"
    chmod +x "$DIR/scripts/detect-theme.sh"

    local detect_fn theme_fn
    detect_fn="$(sed -n '/^_dotfiles_detect_theme() {/,/^}/p' "$DIR/shell/bashrc_exports")"
    theme_fn="$(sed -n '/^theme() {/,/^}/p' "$DIR/shell/bashrc_aliases")"
    [ -n "$detect_fn" ] || fail "could not extract _dotfiles_detect_theme"
    [ -n "$theme_fn" ] || fail "could not extract theme function"

    local out
    # `theme light` forces DOTFILES_THEME=light regardless of detection.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme light >/dev/null 2>&1; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "theme light should set DOTFILES_THEME=light: got '$out'"

    # `theme dark` forces DOTFILES_THEME=dark.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme dark >/dev/null 2>&1; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "dark" ] || fail "theme dark should set DOTFILES_THEME=dark: got '$out'"

    # `theme auto` clears any cached value and re-runs detection. With
    # COLORFGBG=0;15 the fallback chain resolves to light — proves the
    # DOTFILES_THEME unset path actually re-enters detection.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" COLORFGBG='0;15' \
        DOTFILES_THEME=dark \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme auto >/dev/null 2>&1; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "theme auto should re-detect (COLORFGBG=0;15 → light): got '$out'"

    # Unknown argument exits non-zero without modifying state.
    out="$(env -i HOME="$tmp_home" PATH="$PATH" DOTFILES_THEME=light \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme bogus 2>/dev/null; printf "%s" "$DOTFILES_THEME"')"
    [ "$out" = "light" ] || fail "theme bogus should not modify DOTFILES_THEME: got '$out'"
)

_theme_auto_setup() {
    # Common scaffolding for the two theme-auto tests: tmp HOME with a
    # detect-theme symlink and a tmux stub that logs every invocation and
    # answers `display -p '#{client_theme}'` / `-V` from env vars.
    local tmp_home="$1"
    mkdir -p "$tmp_home/.local/bin"
    ln -s "$DIR/scripts/detect-theme.sh" "$tmp_home/.local/bin/detect-theme"
    chmod +x "$DIR/scripts/detect-theme.sh"
    cat > "$tmp_home/.local/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_STUB_LOG"
if [ "$1" = "display" ] && [ "$2" = "-p" ] && [ "$3" = '#{client_theme}' ]; then
    printf '%s\n' "${TMUX_STUB_CLIENT_THEME:-}"
elif [ "$1" = "-V" ]; then
    printf 'tmux %s\n' "${TMUX_STUB_VERSION:-3.2a}"
fi
exit 0
STUB
    chmod +x "$tmp_home/.local/bin/tmux"
}

test_theme_function_auto_busts_cache_on_modern_tmux() (
    # On tmux 3.6+ (where #{client_theme} returns light/dark), `theme auto`
    # busts the stale DOTFILES_THEME from tmux's global env so the
    # re-probe doesn't immediately return the value cached by an earlier
    # run.
    local tmp_home
    tmp_home="$(mktemp -d)"
    trap 'rm -rf "$tmp_home"' EXIT
    _theme_auto_setup "$tmp_home"

    local detect_fn theme_fn
    detect_fn="$(sed -n '/^_dotfiles_detect_theme() {/,/^}/p' "$DIR/shell/bashrc_exports")"
    theme_fn="$(sed -n '/^theme() {/,/^}/p' "$DIR/shell/bashrc_aliases")"
    [ -n "$detect_fn" ] || fail "could not extract _dotfiles_detect_theme"
    [ -n "$theme_fn" ] || fail "could not extract theme function"

    local log="$tmp_home/tmux.log"
    : > "$log"
    env -i HOME="$tmp_home" PATH="$tmp_home/.local/bin:$PATH" \
        TMUX=fake TMUX_STUB_LOG="$log" \
        TMUX_STUB_CLIENT_THEME=light TMUX_STUB_VERSION=3.6 \
        DOTFILES_THEME=dark \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme auto >/dev/null 2>&1' >/dev/null 2>&1 || true

    grep -E '^set-environment .*-u .*DOTFILES_THEME' "$log" >/dev/null ||
        fail "theme auto did not bust tmux global env cache on tmux 3.6+. log:
$(cat "$log")"
)

test_theme_function_auto_refuses_on_legacy_tmux() (
    # On tmux < 3.6 there's no in-session probe (#{client_theme} is empty,
    # passthrough unavailable). `theme auto` must refuse rather than bust
    # the cache and overwrite it with the dark default that detect-theme
    # would fall through to.
    local tmp_home
    tmp_home="$(mktemp -d)"
    trap 'rm -rf "$tmp_home"' EXIT
    _theme_auto_setup "$tmp_home"

    local detect_fn theme_fn
    detect_fn="$(sed -n '/^_dotfiles_detect_theme() {/,/^}/p' "$DIR/shell/bashrc_exports")"
    theme_fn="$(sed -n '/^theme() {/,/^}/p' "$DIR/shell/bashrc_aliases")"

    local log="$tmp_home/tmux.log"
    local stderr_file="$tmp_home/stderr.txt"
    : > "$log"
    env -i HOME="$tmp_home" PATH="$tmp_home/.local/bin:$PATH" \
        TMUX=fake TMUX_STUB_LOG="$log" \
        TMUX_STUB_CLIENT_THEME='' TMUX_STUB_VERSION=3.2a \
        DOTFILES_THEME=dark \
        bash -c "$detect_fn"$'\n'"$theme_fn"';
            theme auto >/dev/null 2> "'"$stderr_file"'"' || true

    ! grep -E '^set-environment .*-u .*DOTFILES_THEME' "$log" >/dev/null ||
        fail "theme auto wrongly busted cache on legacy tmux. log:
$(cat "$log")"
    grep -q 'not supported' "$stderr_file" ||
        fail "theme auto did not emit unsupported-tmux warning on legacy tmux. stderr:
$(cat "$stderr_file")"
)

test_chpc_allocs_self_test() (
    python3 "$DIR/scripts/chpc-allocs.py" --self-test >/dev/null ||
        fail "chpc-allocs.py --self-test failed"
)

test_chpc_allocs_python36_compatible() (
    if ! command -v python3.6 >/dev/null 2>&1; then
        printf 'SKIP: test_chpc_allocs_python36_compatible (python3.6 not found)\n'
        return 0
    fi
    python3.6 "$DIR/scripts/chpc-allocs.py" --self-test >/dev/null ||
        fail "chpc-allocs.py --self-test failed under python3.6"
)

# Each ai/skills/<name>/SKILL.md must have YAML frontmatter starting on
# line 1, contain a `name:` field matching the directory, and a non-empty
# `description:`. Catches typos and missing fields that would break skill
# discovery once symlinked into ~/.claude/skills/.
test_skill_files_have_valid_frontmatter() (
    local skills_dir="$DIR/ai/skills" skill_dir name skill_file
    local declared_name declared_description closing_line

    [ -d "$skills_dir" ] || fail "ai/skills/ directory is missing"

    local count=0
    for skill_dir in "$skills_dir"/*/; do
        [ -d "$skill_dir" ] || continue
        name="$(basename "$skill_dir")"
        skill_file="${skill_dir}SKILL.md"
        [ -f "$skill_file" ] || fail "$name: SKILL.md is missing"

        if [ "$(sed -n '1p' "$skill_file")" != "---" ]; then
            fail "$name: SKILL.md must start with YAML frontmatter on line 1"
        fi

        closing_line="$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$skill_file")"
        if [ -z "$closing_line" ]; then
            fail "$name: SKILL.md frontmatter is missing closing ---"
        fi

        declared_name="$(awk '/^---$/{f++; next} f==1 && /^name:/ {sub(/^name:[[:space:]]*/, ""); print; exit}' "$skill_file")"
        declared_description="$(awk '/^---$/{f++; next} f==1 && /^description:/ {sub(/^description:[[:space:]]*/, ""); print; exit}' "$skill_file")"

        if [ "$declared_name" != "$name" ]; then
            fail "$name: frontmatter name='$declared_name' does not match directory '$name'"
        fi
        if [ -z "$declared_description" ]; then
            fail "$name: frontmatter description is empty"
        fi
        count=$((count + 1))
    done

    [ "$count" -gt 0 ] || fail "no skills found under $skills_dir"
)

# install_claude_skills.sh must (a) parse cleanly under bash and (b)
# honor --dry-run by NOT touching ~/.local/share/claude-skills or
# ~/.claude/skills (no clones, no symlinks). Catches accidental drift in
# the DRY_RUN contract enforced by lib/common.sh::run_step.
test_install_claude_skills_dry_run() (
    local tmp script
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    script="$DIR/scripts/install_claude_skills.sh"

    bash -n "$script" || fail "install_claude_skills.sh syntax error"

    HOME="$tmp" bash "$script" --dry-run >/dev/null || \
        fail "install_claude_skills.sh --dry-run returned non-zero"

    if [ -d "$tmp/.local/share/claude-skills" ]; then
        fail "install_claude_skills.sh --dry-run created cache directory"
    fi
    if [ -d "$tmp/.claude/skills" ]; then
        fail "install_claude_skills.sh --dry-run created skills directory"
    fi
    return 0
)

test_update_guard_decisions() (
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    export HOME="$tmp/home"; mkdir -p "$HOME"

    # shellcheck source=install.sh
    . "$DIR/install.sh"
    # shellcheck disable=SC2034 # consumed by update_guard
    FORCE=false
    # shellcheck disable=SC2034 # consumed by update_guard
    NO_UPDATE=false

    # A present tool reporting version 1.2.3 (a shell function is resolvable by
    # command -v and callable as "$cmd --version", so it stands in for a binary).
    ftool() { echo "ftool 1.2.3"; }

    [ "$(tool_version ftool)" = "1.2.3" ] || fail "tool_version did not extract 1.2.3"

    # Missing command -> (re)install (return 1).
    if update_guard nope nope-missing-cmd 9.9.9 >/dev/null; then
        fail "update_guard skipped a missing tool"
    fi
    # Present and current -> skip (return 0).
    update_guard ftool ftool 1.2.3 >/dev/null || fail "update_guard did not skip a current tool"
    # Installed newer than 'latest' -> skip.
    update_guard ftool ftool 1.0.0 >/dev/null || fail "update_guard did not skip a newer-than-latest tool"
    # Outdated -> install (return 1).
    if update_guard ftool ftool 2.0.0 >/dev/null; then
        fail "update_guard skipped an outdated tool"
    fi
    # Latest unknown (empty) -> keep current (return 0), never churn.
    update_guard ftool ftool "" >/dev/null || fail "update_guard did not keep tool on unknown latest"
    # Non-numeric / v-prefixed tag is normalized ("v2.0.0" -> outdated -> install).
    if update_guard ftool ftool v2.0.0 >/dev/null; then
        fail "update_guard did not normalize a v-prefixed latest"
    fi
    # A jq-style tag ("jq-1.7.1") equal to current -> skip.
    ftool() { echo "ftool 1.7.1"; }
    update_guard ftool ftool jq-1.7.1 >/dev/null || fail "update_guard did not normalize a jq-style tag"

    # --force always (re)installs, even when current.
    ftool() { echo "ftool 1.2.3"; }
    # shellcheck disable=SC2034
    FORCE=true
    if update_guard ftool ftool 1.2.3 >/dev/null; then
        fail "update_guard skipped despite --force"
    fi
    # shellcheck disable=SC2034
    FORCE=false
    # --no-update skips even when outdated.
    # shellcheck disable=SC2034
    NO_UPDATE=true
    update_guard ftool ftool 99.0.0 >/dev/null || fail "update_guard did not honor --no-update"
)

test_install_accepts_no_update_flag() (
    local out
    # --no-update is parsed (sets the flag) before --help short-circuits, so this
    # exits 0 with usage text and must never fall through to "Unknown option".
    out="$(bash "$DIR/install.sh" --no-update --help 2>&1)" ||
        fail "install.sh --no-update --help did not exit 0"
    printf '%s\n' "$out" | grep -q -- '--no-update' ||
        fail "install.sh --help does not document --no-update"
    if printf '%s\n' "$out" | grep -q 'Unknown option'; then
        fail "install.sh treated --no-update as an unknown option"
    fi
)

run_test() {
    local name="$1"

    if ! "$name"; then
        fail "$name failed"
    fi
}

main() {
    run_test test_remote_bash_lc_quote
    run_test test_portable_helpers
    run_test test_backup_helpers_fail_loudly
    run_test test_backup_rotation_preserves_edited_bak
    run_test test_backup_rotation_idempotent_when_identical
    run_test test_remote_capture_strips_banner
    run_test test_gh_latest_cache_memoizes
    run_test test_cached_init_handles_empty_output
    run_test test_cached_init_evals_output_when_cache_unwritable
    run_test test_manifest_controls_uninstall
    run_test test_detect_theme_installs_to_local_bin
    run_test test_scripts_source_without_side_effects
    run_test test_deploy_sources_without_prompting
    run_test test_remote_dotfiles_preflight_snippet
    run_test test_git_clone_command_uses_gh_only_for_credentials
    run_test test_remote_git_probe_snippet
    run_test test_auth_state_helpers
    run_test test_rclone_config_helpers
    run_test test_rclone_deploy_merges_only_gdrive
    run_test test_rclone_install_uses_managed_local_bin
    run_test test_setup_dry_run_is_non_mutating
    run_test test_chpc_config_rendering_uses_repo_files
    run_test test_chpc_module_loads_initialize_module_command
    run_test test_module_var_reset_clears_stale_values
    run_test test_nvim_manifest_records_only_owned_layout
    run_test test_nvim_install_selects_legacy_and_arm_assets
    run_test test_pre_commit_no_staged_files
    run_test test_pre_commit_blocks_secrets
    run_test test_theme_detection
    run_test test_theme_function
    run_test test_theme_function_auto_busts_cache_on_modern_tmux
    run_test test_theme_function_auto_refuses_on_legacy_tmux
    run_test test_chpc_allocs_self_test
    run_test test_chpc_allocs_python36_compatible
    run_test test_skill_files_have_valid_frontmatter
    run_test test_install_claude_skills_dry_run
    run_test test_update_guard_decisions
    run_test test_install_accepts_no_update_flag
    echo "All regression tests passed."
}

main "$@"
