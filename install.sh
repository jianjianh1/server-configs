#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIR
GENERATED_DIR="$HOME/.dotfiles-generated"
readonly GENERATED_DIR
INSTALL_MANIFEST="$GENERATED_DIR/install-manifest.txt"
readonly INSTALL_MANIFEST
CLAUDE_SETTINGS_SRC=""
CLAUDE_SETTINGS_MODE="repo"
CODEX_CONFIG_SRC=""
CODEX_CONFIG_MODE="repo"
DOTFILES_MODULE_VARS=(NVIM_MODULE CLAUDE_MODULE CODEX_MODULE GH_MODULE NODE_MODULE UV_MODULE BTOP_MODULE CODE_CLI_MODULE)

reset_module_vars() {
    local module_var

    for module_var in "${DOTFILES_MODULE_VARS[@]}"; do
        printf -v "$module_var" '%s' ""
    done
}

reset_module_vars
# CHPC module names — verified against `module spider` on notchpeak2
# (2026-05). Re-verify with: ./install.sh --probe-modules
CLAUDE_MODULE_CANDIDATES=("claude")
CODEX_MODULE_CANDIDATES=("codex")
GH_MODULE_CANDIDATES=("gh")
NODE_MODULE_CANDIDATES=("nodejs")
UV_MODULE_CANDIDATES=("uv")
BTOP_MODULE_CANDIDATES=("btop")
NVIM_MODULE_CANDIDATES=("nvim/0.11.2" "nvim")
# tree-sitter has no CHPC module today; install_tree_sitter falls back to
# the prebuilt binary (then to cargo build-from-source if glibc is too old).
TREE_SITTER_MODULE_CANDIDATES=()
# VS Code tunnel CLI has no CHPC module today; falls back to binary install.
CODE_CLI_MODULE_CANDIDATES=()
FORCE="${FORCE:-false}"
DRY_RUN="${DRY_RUN:-false}"
NO_UPDATE="${NO_UPDATE:-false}"
CHPC_USE_MODULES="${CHPC_USE_MODULES:-false}"
FAILURES=()

_setup_cleanup() {
    [ -n "${_GH_LATEST_CACHE_FILE:-}" ] && rm -f "$_GH_LATEST_CACHE_FILE" 2>/dev/null
}

# --- Shared helpers (run_step, retry, backup_and_link, backup_and_copy) ---
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

# --- Helpers ---

# Wrapper: move/copy files respecting sudo needs
install_to() {
    local src="$1" dst="$2"
    if [ "${DRY_RUN:-false}" = true ]; then
        echo "[dry-run] Would install $src -> $dst"
        return 0
    fi
    if [ -n "$NEED_SUDO" ]; then
        sudo mv -f "$src" "$dst"
    else
        mv -f "$src" "$dst"
    fi
}

command_output_contains() {
    local pattern="$1"
    local output
    shift
    output="$("$@" 2>/dev/null || true)"
    [[ "$output" == *"$pattern"* ]]
}

record_command_if_managed() {
    local cmd="$1"
    local path

    path="$(command -v "$cmd" 2>/dev/null || true)"
    [ -n "$path" ] || return 1
    case "$path" in
        "$HOME"/*) ;;
        *) return 0 ;;
    esac
    manifest_add_path "$path"
}

brew_install() {
    local formula="$1" cmd="${2:-$1}"

    is_macos || return 1
    if ! command -v brew &>/dev/null; then
        echo "  Skipping $formula: Homebrew is not installed."
        return 1
    fi
    if command -v "$cmd" &>/dev/null && ! $FORCE; then
        if $NO_UPDATE; then
            echo "$cmd present (update check skipped)"
            return 0
        fi
        # brew knows outdated state; only upgrade formulae it actually manages.
        if brew outdated "$formula" 2>/dev/null | grep -q .; then
            echo "Updating $formula with Homebrew..."
            brew upgrade "$formula" || return 1
            hash -r
            return 0
        fi
        echo "$cmd up to date: $("$cmd" --version 2>&1 | head -1)"
        return 0
    fi
    echo "Installing $formula with Homebrew..."
    if brew list --formula "$formula" >/dev/null 2>&1 && ! $FORCE; then
        brew link "$formula" >/dev/null 2>&1 || true
    else
        brew install "$formula" || return 1
    fi
    hash -r
    command -v "$cmd" &>/dev/null
}

record_node_manifest() {
    local path

    for path in \
        "$HOME/.local/bin/node" \
        "$HOME/.local/bin/npm" \
        "$HOME/.local/bin/npx" \
        "$HOME/.local/bin/corepack" \
        "$HOME/.local/lib/node_modules" \
        "$HOME/.local/include/node" \
        "$HOME/.local/share/doc/node" \
        "$HOME/.local/share/man/man1/node.1" \
        "$HOME/.local/share/systemtap/tapset/node.stp"
    do
        [ -e "$path" ] && manifest_add_path "$path"
    done
}

record_nvim_manifest() {
    local opt_dir target target_bin expected

    target_bin="$HOME/.local/bin/nvim"
    opt_dir="$HOME/.local/opt/nvim"

    if [ -L "$target_bin" ]; then
        target="$(portable_realpath "$target_bin" 2>/dev/null || true)"
        # Resolve the expected path the same way so parent-dir symlinks
        # (e.g. macOS /var -> /private/var inside mktemp roots) don't
        # cause a spurious mismatch.
        expected="$(portable_realpath "$opt_dir/bin/nvim" 2>/dev/null || printf '%s' "$opt_dir/bin/nvim")"
        [ "$target" = "$expected" ] || return 0
        manifest_add_path "$target_bin"
        [ -d "$opt_dir" ] && manifest_add_path "$opt_dir"
    fi
}

append_line_if_missing() {
    local line="$1" file="$2"

    if ! grep -qF "$line" "$file" 2>/dev/null; then
        mkdir -p "$(dirname "$file")" || return 1
        # If the file lacks a trailing newline, the append would fuse onto
        # the last line. `tail -c 1` of a newline-terminated file yields an
        # empty string (command substitution strips it); any other last byte
        # comes through as non-empty.
        if [ -s "$file" ] && [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
            printf '\n' >> "$file" || return 1
        fi
        printf '%s\n' "$line" >> "$file" || return 1
    fi
}

version_at_least() {
    local actual="$1" required="$2"
    awk -v actual="$actual" -v required="$required" '
        function split_version(version, parts, count, i) {
            count = split(version, parts, ".")
            for (i = count + 1; i <= 4; i++) {
                parts[i] = 0
            }
            return count
        }
        BEGIN {
            split_version(actual, actual_parts)
            split_version(required, required_parts)
            for (i = 1; i <= 4; i++) {
                if ((actual_parts[i] + 0) > (required_parts[i] + 0)) exit 0
                if ((actual_parts[i] + 0) < (required_parts[i] + 0)) exit 1
            }
            exit 0
        }
    '
}

# First dotted numeric version token from `<cmd> --version` (handles
# "gh version 2.63.0", "jq-1.7.1", "NVIM v0.11.2", "uv 0.5.0", "2.1.83", ...).
tool_version() {
    "$1" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# Decide whether a caller's install body must run.
#   returns 1 => (re)install: missing, --force, or installed < latest
#   returns 0 => skip: present and current, --no-update, or latest unknown
# Never churns on a failed version fetch (empty $latest => keep what we have).
update_guard() {
    local name="$1" cmd="$2" latest="$3" cur
    command -v "$cmd" &>/dev/null || return 1
    $FORCE && return 1
    if $NO_UPDATE; then
        echo "$name present (update check skipped)"
        return 0
    fi
    # Normalize latest to a bare dotted-numeric version (tags like "jq-1.7.1"
    # or "v2.63.0" -> "1.7.1" / "2.63.0") so version_at_least compares cleanly.
    latest="$(printf '%s' "$latest" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    cur="$(tool_version "$cmd")"
    if [ -z "$latest" ]; then
        echo "  $name: latest version unknown; keeping ${cur:-current}"
        return 0
    fi
    if [ -n "$cur" ] && version_at_least "$cur" "$latest"; then
        echo "$name up to date ($cur)"
        return 0
    fi
    echo "Updating $name ${cur:-?} -> $latest..."
    return 1
}

tmux_version() {
    command -v tmux &>/dev/null || return 1
    tmux -V 2>/dev/null | awk '{print $2}' | sed 's/[^0-9.].*$//'
}

git_version() {
    command -v git &>/dev/null || return 1
    git --version 2>/dev/null | awk '{print $3}' | sed 's/[^0-9.].*$//'
}

tmux_default_terminal() {
    if command -v infocmp &>/dev/null && infocmp tmux-256color &>/dev/null; then
        echo "tmux-256color"
    else
        echo "screen-256color"
    fi
}

tmux_supports_allow_passthrough() {
    local version
    version="$(tmux_version 2>/dev/null || true)"
    [ -n "$version" ] && version_at_least "$version" "3.3"
}

tmux_supports_set_clipboard() {
    local version
    version="$(tmux_version 2>/dev/null || true)"
    [ -n "$version" ] && version_at_least "$version" "2.6"
}

# `*-style` options (status-style, pane-*-border-style) — tmux 2.9+. Older
# tmux needs legacy `*-bg` / `*-fg` pairs. Drives render_tmux_theme().
tmux_supports_styles() {
    local version
    version="$(tmux_version 2>/dev/null || true)"
    [ -n "$version" ] && version_at_least "$version" "2.9"
}

vim_supports_clipboard() {
    command -v vim &>/dev/null || return 1
    vim --version 2>/dev/null | grep -Eq '^\+(clipboard|xterm_clipboard)\b'
}

vim_supports_unicode_listchars() {
    command -v vim &>/dev/null || return 1
    vim -Nu NONE -n -es +'set listchars=tab:>>·,trail:·,extends:›,precedes:‹,nbsp:␣' +qall! >/dev/null 2>&1
}

gh_supports_git_credential() {
    command -v gh &>/dev/null || return 1
    gh auth git-credential --help >/dev/null 2>&1
}

ssh_has_default_key() {
    local key
    for key in id_ed25519 id_rsa id_ecdsa id_dsa; do
        [ -f "$HOME/.ssh/$key" ] && return 0
    done
    return 1
}

claude_supports_settings() {
    command -v claude &>/dev/null || return 1
    command_output_contains '--settings ' claude --help
}

claude_supports_permission_mode() {
    command -v claude &>/dev/null || return 1
    command_output_contains '--permission-mode ' claude --help
}

codex_supports_settings() {
    command -v codex &>/dev/null || return 1
    command_output_contains '--ask-for-approval' codex --help &&
        command_output_contains '--sandbox' codex --help
}

codex_supports_login_status() {
    command -v codex &>/dev/null || return 1
    codex login --help 2>/dev/null | grep -q '^[[:space:]]*status[[:space:]]'
}

ensure_module_command() {
    local init

    if command -v module &>/dev/null; then
        return 0
    fi

    for init in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh /usr/share/Modules/init/bash; do
        if [ -r "$init" ]; then
            # shellcheck disable=SC1090
            . "$init" >/dev/null 2>&1 || true
            if command -v module &>/dev/null; then
                return 0
            fi
        fi
    done

    return 1
}

# Try to satisfy a tool requirement on CHPC via environment modules.
# Sets the named variable to the loaded module name on success.
# Returns 0 if already available or loaded; 1 if no module found.
try_chpc_module_load() {
    local cmd="$1" display="$2" var_name="$3"
    shift 3
    local tried=("$@")

    if ensure_module_command; then
        local mod
        for mod in "$@"; do
            if module load "$mod" 2>/dev/null && command -v "$cmd" &>/dev/null; then
                hash -r
                printf -v "$var_name" '%s' "$mod"
                echo "$display loaded via module: $mod ($("$cmd" --version 2>&1 | head -1))"
                return 0
            fi
        done
    fi
    if command -v "$cmd" &>/dev/null && ! $FORCE; then
        echo "$display already available: $("$cmd" --version 2>&1 | head -1)"
        return 0
    fi
    echo "  Warning: no $display module found on CHPC — skipping self-install"
    if [ "${#tried[@]}" -gt 0 ]; then
        echo "  Tried: ${tried[*]}"
    fi
    echo "  Check available modules with: module spider $cmd"
    return 1
}

# Print which CHPC module candidates resolve and which don't, without
# loading anything. Useful for re-verifying the candidate lists after
# CHPC adds, removes, or renames modules.
probe_chpc_modules() {
    if ! ensure_module_command; then
        echo "Error: 'module' command unavailable. Run this on a CHPC login/compute node."
        return 1
    fi
    local group candidates_var name resolved out
    local groups=(
        "Claude Code:CLAUDE_MODULE_CANDIDATES"
        "Codex:CODEX_MODULE_CANDIDATES"
        "GitHub CLI:GH_MODULE_CANDIDATES"
        "Node.js:NODE_MODULE_CANDIDATES"
        "uv:UV_MODULE_CANDIDATES"
        "btop:BTOP_MODULE_CANDIDATES"
        "Neovim:NVIM_MODULE_CANDIDATES"
        "tree-sitter:TREE_SITTER_MODULE_CANDIDATES"
    )
    printf '%-14s %-12s %s\n' "TOOL" "STATUS" "CANDIDATE"
    printf '%-14s %-12s %s\n' "----" "------" "---------"
    for group in "${groups[@]}"; do
        name="${group%%:*}"
        candidates_var="${group##*:}"
        local -n arr="$candidates_var"
        if [ "${#arr[@]}" -eq 0 ]; then
            printf '%-14s %-12s %s\n' "$name" "(none)" "no candidates configured"
            continue
        fi
        for cand in "${arr[@]}"; do
            out="$(module spider "$cand" 2>&1)"
            if printf '%s' "$out" | grep -q 'Unable to find'; then
                printf '%-14s %-12s %s\n' "$name" "MISSING" "$cand"
            else
                # Prefer (D)-marked default, else last version Lmod prints.
                resolved="$(printf '%s\n' "$out" | awk -v cand="$cand" '
                    $0 ~ "^  " cand ": " cand "/" {
                        if (match($0, cand "/[^[:space:]]+") > 0) {
                            print substr($0, RSTART, RLENGTH); exit
                        }
                    }
                    $0 ~ "^[ ]+" cand "/[0-9]" {
                        if (match($0, cand "/[^[:space:](]+") > 0) {
                            v = substr($0, RSTART, RLENGTH)
                            if (index($0, "(D)") > 0) { print v; exit }
                            last = v
                        }
                    }
                    END { if (last != "") print last }
                ')"
                printf '%-14s %-12s %s\n' "$name" "FOUND" "$cand${resolved:+ -> $resolved}"
            fi
        done
    done
}

render_tmux_compat() {
    local default_terminal
    default_terminal="$(tmux_default_terminal)"

    cat > "$GENERATED_DIR/tmux.compat.conf" <<EOF
# Generated by install.sh. Re-run install.sh after changing tmux versions.
set -g default-terminal "${default_terminal}"
set -ga terminal-overrides ",xterm-256color:Tc"
EOF

    if tmux_supports_allow_passthrough; then
        cat >> "$GENERATED_DIR/tmux.compat.conf" <<'EOF'
set -g allow-passthrough on
EOF
    else
        cat >> "$GENERATED_DIR/tmux.compat.conf" <<'EOF'
# tmux < 3.3: leave passthrough disabled to avoid startup errors.
EOF
    fi

    if tmux_supports_set_clipboard; then
        cat >> "$GENERATED_DIR/tmux.compat.conf" <<'EOF'
set -s set-clipboard on
EOF
    else
        cat >> "$GENERATED_DIR/tmux.compat.conf" <<'EOF'
# tmux clipboard integration unavailable on this host version.
EOF
    fi
}

# Write the light/dark status palette as three generated files:
#   tmux-theme.conf        — dispatcher (single if-shell, identical across
#                            tmux versions). ~/.tmux-theme.conf symlinks here,
#                            so `theme light|dark|auto` keeps working.
#   tmux-theme-light.conf  — palette commands for light mode.
#   tmux-theme-dark.conf   — palette commands for dark mode.
# Option names branch on tmux version: `*-style` for tmux >= 2.9, legacy
# `*-bg` / `*-fg` for older. Inline `#[...]` format strings are unchanged.
render_tmux_theme() {
    cat > "$GENERATED_DIR/tmux-theme.conf" <<'EOF'
# Generated by install.sh. Re-run install.sh after changing tmux versions.
# Dispatcher: branch on detect-theme output (OSC 11 -> VS Code -> Apple
# Terminal -> COLORFGBG -> dark). Re-sourced by the `theme` shell alias
# and by tmux client-attached / client-light-theme / client-dark-theme
# hooks set in tmux.conf.
if-shell '[ "$(~/.local/bin/detect-theme 2>/dev/null)" = "light" ]' \
  'source-file ~/.dotfiles-generated/tmux-theme-light.conf' \
  'source-file ~/.dotfiles-generated/tmux-theme-dark.conf'
EOF

    _render_tmux_palette light "$GENERATED_DIR/tmux-theme-light.conf"
    _render_tmux_palette dark  "$GENERATED_DIR/tmux-theme-dark.conf"
}

_render_tmux_palette() {
    local mode="$1" out="$2"
    local status_bg status_fg accent_fg accent_bg right_fg clock_fg active_border inactive_border

    if [ "$mode" = "light" ]; then
        status_bg=colour254; status_fg=colour238
        accent_fg=colour231; accent_bg=colour33
        right_fg=colour238;  clock_fg=colour238
        active_border=colour33; inactive_border=colour250
    else
        status_bg=colour235; status_fg=colour252
        accent_fg=colour16;  accent_bg=colour39
        right_fg=colour248;  clock_fg=colour252
        active_border=colour39; inactive_border=colour238
    fi

    {
        echo "# Generated by install.sh. Re-run install.sh after changing tmux versions."
        if tmux_supports_styles; then
            echo "set -g status-style bg=${status_bg},fg=${status_fg}"
            echo "set -g pane-active-border-style fg=${active_border}"
            echo "set -g pane-border-style fg=${inactive_border}"
        else
            echo "# tmux < 2.9: legacy *-bg / *-fg option names."
            echo "set -g status-bg ${status_bg}"
            echo "set -g status-fg ${status_fg}"
            echo "set -g pane-active-border-fg ${active_border}"
            echo "set -g pane-border-fg ${inactive_border}"
        fi
        echo "set -g status-left \"#[fg=${accent_fg},bg=${accent_bg},bold] #S #[default] \""
        echo "set -g status-right \"#[fg=${right_fg}] #(cd #{pane_current_path}; git symbolic-ref --short HEAD 2>/dev/null) #[fg=${clock_fg}]%H:%M \""
        echo "setw -g window-status-current-format \"#[fg=${accent_fg},bg=${accent_bg},bold] #I:#W \""
        echo "setw -g window-status-format \" #[fg=${right_fg}]#I:#W \""
    } > "$out"
}

render_vim_compat() {
    local listchars

    if vim_supports_unicode_listchars; then
        listchars='tab:>>·,trail:·,extends:›,precedes:‹,nbsp:␣'
    else
        listchars='tab:>-,trail:.,extends:>,precedes:<,nbsp:+'
    fi

    cat > "$GENERATED_DIR/vimrc.compat" <<EOF
" Generated by install.sh. Re-run install.sh after changing Vim versions.
set listchars=${listchars}
EOF

    if vim_supports_clipboard; then
        cat >> "$GENERATED_DIR/vimrc.compat" <<'EOF'
set clipboard=unnamedplus
EOF
    else
        cat >> "$GENERATED_DIR/vimrc.compat" <<'EOF'
" Clipboard support not available in this Vim build.
EOF
    fi

    cat >> "$GENERATED_DIR/vimrc.compat" <<'EOF'
if has('nvim')
    augroup dotfiles_compat
        autocmd!
        autocmd TextYankPost * silent! lua vim.highlight.on_yank()
    augroup END
endif
EOF
}

render_git_compat() {
    if gh_supports_git_credential; then
        cat > "$GENERATED_DIR/gitconfig.compat" <<'EOF'
[credential "https://github.com"]
	helper =
	helper = !gh auth git-credential

[credential "https://gist.github.com"]
	helper =
	helper = !gh auth git-credential
EOF
        # On a keyless host (typical after `deploy.sh` bootstraps a
        # remote), route `git@github.com:` URLs through the gh HTTPS
        # credential helper so existing SSH-style remotes can still
        # pull/push. Skipped on workstations that have a real SSH key.
        if ! ssh_has_default_key; then
            cat >> "$GENERATED_DIR/gitconfig.compat" <<'EOF'

[url "https://github.com/"]
	insteadOf = git@github.com:
	insteadOf = ssh://git@github.com/
EOF
        fi
    else
        cat > "$GENERATED_DIR/gitconfig.compat" <<'EOF'
# Generated by install.sh. GitHub CLI credential helper unavailable on this host.
EOF
    fi

    # merge.conflictstyle: zdiff3 landed in git 2.35 (Jan 2022). On older gits
    # the static value would trip "fatal: unknown style 'zdiff3'" — including
    # in subprocess git calls from tools like the Claude Code plugin installer.
    # The static `gitconfig` declares `diff3` as a safe default *before* the
    # `[include]`; this block's role is upgrade-only — emit `zdiff3` on
    # git >= 2.35 (last-write-wins overrides the static default) and a
    # redundant `diff3` echo on older git for clarity. When git_version fails,
    # skip the block entirely and let the static default rule.
    local gitv
    gitv="$(git_version 2>/dev/null || true)"
    if [ -n "$gitv" ]; then
        if version_at_least "$gitv" "2.35"; then
            cat >> "$GENERATED_DIR/gitconfig.compat" <<'EOF'

[merge]
	conflictstyle = zdiff3
EOF
        else
            cat >> "$GENERATED_DIR/gitconfig.compat" <<'EOF'

[merge]
	conflictstyle = diff3
EOF
        fi
    fi
}

render_bash_compat() {
    cat > "$GENERATED_DIR/bashrc_compat" <<'EOF'
# Generated by install.sh. Re-run install.sh after upgrading Claude Code or Codex CLI.
if [ -n "${DOTFILES_BASH_COMPAT_LOADED:-}" ]; then
    return 0
fi
DOTFILES_BASH_COMPAT_LOADED=1
EOF

    # Persist module loads for any tool installed via module. We only run
    # them in interactive shells: SLURM job-step shells (srun --pty bash)
    # inherit Lmod state from the job, and an unconditional `module load`
    # here can swap MPI/compiler combos and break job startup.
    local mod_load mod_val _any_module=false
    for mod_load in "${DOTFILES_MODULE_VARS[@]}"; do
        mod_val="${!mod_load:-}"
        if [ -n "$mod_val" ]; then
            if ! "$_any_module"; then
                _any_module=true
                cat >> "$GENERATED_DIR/bashrc_compat" <<'EOF'

# Environment modules — interactive shells only.
case $- in
    *i*) ;;
    *) return 0 ;;
esac
if ! command -v module &>/dev/null; then
    for init in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh /usr/share/Modules/init/bash; do
        if [ -r "$init" ]; then
            . "$init" >/dev/null 2>&1 && break
        fi
    done
fi
_dotfiles_module_load() {
    command -v module &>/dev/null || return 0
    module load "$@"
}
EOF
            fi
            cat >> "$GENERATED_DIR/bashrc_compat" <<EOF
_dotfiles_module_load ${mod_val}
EOF
        fi
    done
}

render_claude_settings_target() {
    CLAUDE_SETTINGS_SRC="$DIR/ai/claude_settings.json"
    CLAUDE_SETTINGS_MODE="repo"

    if ! command -v claude &>/dev/null; then
        return 0
    fi

    if claude_supports_settings && claude_supports_permission_mode; then
        rm -f "$GENERATED_DIR/claude_settings.json"
        return 0
    fi

    cat > "$GENERATED_DIR/claude_settings.json" <<'EOF'
{}
EOF
    CLAUDE_SETTINGS_SRC="$GENERATED_DIR/claude_settings.json"
    CLAUDE_SETTINGS_MODE="fallback"
}

render_codex_config_target() {
    CODEX_CONFIG_SRC="$DIR/ai/codex_config.toml"
    CODEX_CONFIG_MODE="repo"

    if ! command -v codex &>/dev/null; then
        return 0
    fi

    if codex_supports_settings; then
        rm -f "$GENERATED_DIR/codex_config.toml"
        return 0
    fi

    cat > "$GENERATED_DIR/codex_config.toml" <<'EOF'
# Generated by install.sh for an older Codex CLI.
EOF
    CODEX_CONFIG_SRC="$GENERATED_DIR/codex_config.toml"
    CODEX_CONFIG_MODE="fallback"
}


write_compat_report() {
    local tmux_version_out="not installed"
    local tmux_default_term
    local tmux_passthrough="off"
    local vim_version_out="not installed"
    local vim_clipboard="off"
    local vim_listchars_mode="ascii"
    local gh_helper="off"
    local nvim_version_out="not installed"
    local claude_version_out="not installed"
    local codex_version_out="not installed"
    local chpc_out="no"
    local generated_at

    generated_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    is_chpc && chpc_out="yes"
    tmux_default_term="$(tmux_default_terminal)"

    if command -v tmux &>/dev/null; then
        tmux_version_out="$(tmux -V 2>/dev/null)"
        tmux_supports_allow_passthrough && tmux_passthrough="on"
    fi

    if command -v vim &>/dev/null; then
        vim_version_out="$(vim --version 2>/dev/null | head -1)"
        vim_supports_clipboard && vim_clipboard="on"
        if vim_supports_unicode_listchars; then
            vim_listchars_mode="unicode"
        fi
    fi

    gh_supports_git_credential && gh_helper="on"

    if command -v nvim &>/dev/null; then
        nvim_version_out="$(nvim --version 2>/dev/null | head -1)"
    fi

    if command -v claude &>/dev/null; then
        claude_version_out="$(claude --version 2>&1 | head -1)"
    fi

    local starship_version_out="not installed"
    local atuin_version_out="not installed"

    if command -v starship &>/dev/null; then
        starship_version_out="$(starship --version 2>&1 | head -1)"
    fi

    if command -v atuin &>/dev/null; then
        atuin_version_out="$(atuin --version 2>&1 | head -1)"
    fi

    if command -v codex &>/dev/null; then
        codex_version_out="$(codex --version 2>&1 | head -1)"
    fi

    cat > "$GENERATED_DIR/compat-report.txt" <<EOF
dotfiles compatibility report
Generated: ${generated_at}
chpc: ${chpc_out}

tmux: ${tmux_version_out}
  default-terminal: ${tmux_default_term}
  allow-passthrough: ${tmux_passthrough}

vim: ${vim_version_out}
  clipboard: ${vim_clipboard}
  listchars: ${vim_listchars_mode}

nvim: ${nvim_version_out}

git:
  gh git-credential helper: ${gh_helper}

starship: ${starship_version_out}
atuin: ${atuin_version_out}

claude: ${claude_version_out}
  settings source: ${CLAUDE_SETTINGS_MODE}

codex: ${codex_version_out}
  settings source: ${CODEX_CONFIG_MODE}
  login status command: $(codex_supports_login_status && echo on || echo off)
EOF
}

render_compat_configs() {
    render_tmux_compat
    render_tmux_theme
    render_vim_compat
    render_git_compat
    render_bash_compat
    render_claude_settings_target
    render_codex_config_target
    write_compat_report
}

# Latest release version from GitHub (strips leading 'v'). API first;
# falls back to the HTML redirect parse when no JSON parser is available.
# File-based cache because every caller uses $(gh_latest …), and a
# `declare -gA` in-shell cache wouldn't survive the subshell.
_GH_LATEST_CACHE_FILE="${_GH_LATEST_CACHE_FILE:-${TMPDIR:-/tmp}/.gh-latest-cache.$$}"

gh_latest() {
    local slug="$1" version="" s v
    if [ -f "$_GH_LATEST_CACHE_FILE" ]; then
        while IFS=$'\t' read -r s v; do
            if [ "$s" = "$slug" ]; then
                printf '%s\n' "$v"
                return 0
            fi
        done < "$_GH_LATEST_CACHE_FILE"
    fi

    if command -v jq &>/dev/null; then
        version="$(retry curl -sfL "https://api.github.com/repos/$slug/releases/latest" 2>/dev/null \
            | jq -r '.tag_name // empty' 2>/dev/null \
            | sed 's/^v//')" || version=""
    elif command -v python3 &>/dev/null; then
        version="$(retry curl -sfL "https://api.github.com/repos/$slug/releases/latest" 2>/dev/null \
            | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('tag_name','').lstrip('v'))
except Exception:
    pass" 2>/dev/null)" || version=""
    fi

    if [ -z "$version" ]; then
        version="$(retry curl -sfI "https://github.com/$slug/releases/latest" \
            | grep -i '^location:' | sed 's|.*/v\?\([^/[:space:]]*\).*|\1|')" || version=""
    fi

    if [ -z "$version" ]; then
        echo "  Warning: could not determine latest version for $slug" >&2
        return 1
    fi
    printf '%s\t%s\n' "$slug" "$version" >> "$_GH_LATEST_CACHE_FILE" 2>/dev/null || true
    printf '%s\n' "$version"
}

# Install a binary from a GitHub release tarball
install_gh_binary() {
    local name="$1" url="$2" bin_name="${3:-$1}" latest="${4:-}"
    if update_guard "$bin_name" "$bin_name" "$latest"; then
        record_command_if_managed "$bin_name" || true
        return 0
    fi
    echo "Installing $name..."
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive" "$url"; then
        echo "  Warning: failed to download $name"
        return 1
    fi
    case "$url" in
        *.tbz|*.tar.bz2) tar xj -C "$TMP" -f "$TMP/archive" ;;
        *)                tar xz -C "$TMP" -f "$TMP/archive" ;;
    esac
    local bin
    bin="$(find "$TMP" -type f -name "$bin_name" | head -1)"
    if [ -z "$bin" ]; then
        echo "  Warning: $bin_name binary not found in archive"
        return 1
    fi
    chmod +x "$bin"
    if ! install_to "$bin" "$BIN_DIR/$bin_name"; then
        echo "  Warning: failed to install $name to $BIN_DIR/$bin_name"
        return 1
    fi
    manifest_add_path "$BIN_DIR/$bin_name"
    echo "  $name installed to $BIN_DIR/$bin_name"
}

# Install a bare binary (no archive) from a GitHub release
install_gh_bare_binary() {
    local name="$1" url="$2" bin_name="${3:-$1}" latest="${4:-}"
    if update_guard "$bin_name" "$bin_name" "$latest"; then
        record_command_if_managed "$bin_name" || true
        return 0
    fi
    echo "Installing $name..."
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/$bin_name" "$url"; then
        echo "  Warning: failed to download $name"
        return 1
    fi
    chmod +x "$TMP/$bin_name"
    if ! install_to "$TMP/$bin_name" "$BIN_DIR/$bin_name"; then
        echo "  Warning: failed to install $name to $BIN_DIR/$bin_name"
        return 1
    fi
    manifest_add_path "$BIN_DIR/$bin_name"
    echo "  $name installed to $BIN_DIR/$bin_name"
}

# --- Install functions ---

install_gh_cli() {
    if is_macos; then
        brew_install gh gh
        return $?
    fi
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load gh "GitHub CLI" GH_MODULE "${GH_MODULE_CANDIDATES[@]}"
        return
    fi
    local GH_VERSION
    GH_VERSION="$(gh_latest cli/cli)" || GH_VERSION=""
    if command -v gh &>/dev/null && ! $FORCE; then
        local gh_path
        gh_path="$(command -v gh)"
        if [[ "$gh_path" == /snap/* ]]; then
            # A confined snap gh cannot exec ssh (git@github.com clones fail with
            # "cannot exec 'ssh': Permission denied"). Fall through to install the
            # unconfined binary, which ~/.local/bin shadows ahead of /snap/bin.
            echo "  gh is a confined snap ($gh_path); installing unconfined binary to shadow it..."
        elif update_guard gh gh "$GH_VERSION"; then
            record_command_if_managed gh || true
            return 0
        fi
    fi
    echo "Installing GitHub CLI..."
    [ -n "$GH_VERSION" ] || { echo "  Warning: could not determine latest gh version"; return 1; }
    local ARCH GH_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  GH_ARCH="amd64" ;;
        aarch64) GH_ARCH="arm64" ;;
        *)       echo "  Skipping gh (unsupported arch: $ARCH)"; return 1 ;;
    esac
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive.tar.gz" "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${GH_ARCH}.tar.gz"; then
        echo "  Warning: failed to download gh"
        return 1
    fi
    tar xz -C "$TMP" -f "$TMP/archive.tar.gz"
    local bin
    bin="$(find "$TMP" -type f -name "gh" -path '*/bin/*' | head -1)"
    if [ -z "$bin" ]; then
        echo "  Warning: gh binary not found in archive"
        return 1
    fi
    chmod +x "$bin"
    if ! install_to "$bin" "$BIN_DIR/gh"; then
        echo "  Warning: failed to install gh to $BIN_DIR/gh"
        return 1
    fi
    manifest_add_path "$BIN_DIR/gh"
    echo "  gh $GH_VERSION installed to $BIN_DIR/gh"
    if ! gh auth status &>/dev/null; then
        echo "  Run 'gh auth login' to authenticate with GitHub."
    fi
}

install_glow() {
    if is_macos; then
        brew_install glow glow
        return $?
    fi
    local GLOW_VERSION
    GLOW_VERSION="$(gh_latest charmbracelet/glow)" || GLOW_VERSION=""
    if update_guard glow glow "$GLOW_VERSION"; then
        record_command_if_managed glow || true
        return 0
    fi
    echo "Installing glow..."
    [ -n "$GLOW_VERSION" ] || { echo "  Warning: could not determine latest glow version"; return 1; }
    local ARCH GLOW_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  GLOW_ARCH="x86_64" ;;
        aarch64) GLOW_ARCH="arm64"  ;;
        *)       echo "  Skipping glow (unsupported arch: $ARCH)"; return 1 ;;
    esac
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive.tar.gz" "https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_Linux_${GLOW_ARCH}.tar.gz"; then
        echo "  Warning: failed to download glow"
        return 1
    fi
    tar xz -C "$TMP" --strip-components=1 -f "$TMP/archive.tar.gz"
    if ! install_to "$TMP/glow" "$BIN_DIR/glow"; then
        echo "  Warning: failed to install glow to $BIN_DIR/glow"
        return 1
    fi
    manifest_add_path "$BIN_DIR/glow"
    echo "  glow $GLOW_VERSION installed to $BIN_DIR/glow"
}

install_gum() {
    if is_macos; then
        brew_install gum gum
        return $?
    fi
    local GUM_VERSION
    GUM_VERSION="$(gh_latest charmbracelet/gum)" || GUM_VERSION=""
    if update_guard gum gum "$GUM_VERSION"; then
        record_command_if_managed gum || true
        return 0
    fi
    echo "Installing gum..."
    [ -n "$GUM_VERSION" ] || { echo "  Warning: could not determine latest gum version"; return 1; }
    local ARCH GUM_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  GUM_ARCH="x86_64" ;;
        aarch64) GUM_ARCH="arm64"  ;;
        *)       echo "  Skipping gum (unsupported arch: $ARCH)"; return 1 ;;
    esac
    # Default BIN_DIR so deploy.sh can source this file and call install_gum
    # without going through setup_main (where BIN_DIR is normally chosen).
    local dest_dir="${BIN_DIR:-$HOME/.local/bin}"
    mkdir -p "$dest_dir" || return 1
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive.tar.gz" "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${GUM_ARCH}.tar.gz"; then
        echo "  Warning: failed to download gum"
        return 1
    fi
    tar xz -C "$TMP" --strip-components=1 -f "$TMP/archive.tar.gz"
    if ! install_to "$TMP/gum" "$dest_dir/gum"; then
        echo "  Warning: failed to install gum to $dest_dir/gum"
        return 1
    fi
    manifest_add_path "$dest_dir/gum"
    echo "  gum $GUM_VERSION installed to $dest_dir/gum"
}

install_jq() {
    if is_macos; then
        brew_install jq jq
        return $?
    fi
    if command -v jq &>/dev/null && ! $FORCE; then
        record_command_if_managed jq || true
        echo "jq already installed: $(jq --version 2>&1)"
        return 0
    fi
    echo "Installing jq..."
    local ARCH DEB_ARCH V
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  DEB_ARCH="amd64" ;;
        aarch64) DEB_ARCH="arm64" ;;
        *)       echo "  Skipping jq (unsupported arch: $ARCH)"; return 1 ;;
    esac
    if ! V="$(gh_latest jqlang/jq)"; then
        return 1
    fi
    install_gh_bare_binary jq \
        "https://github.com/jqlang/jq/releases/download/${V}/jq-linux-${DEB_ARCH}" jq "$V"
}

rclone_latest() {
    retry curl -sfL https://downloads.rclone.org/version.txt 2>/dev/null \
        | sed -n 's/^rclone v\([0-9][0-9.]*\).*$/\1/p' \
        | head -1
}

report_rclone_gdrive_config() {
    local state status detail

    state="$(rclone_gdrive_auth_state)"
    status="${state%%|*}"
    detail="${state#*|}"
    if [ "$status" = deployable ]; then
        echo "  Google Drive remote ready: gdrive:"
    else
        echo "  Google Drive auth not ready: $detail"
        echo "    Configure it as your user with: rclone config"
    fi
}

install_rclone() {
    if is_macos; then
        brew_install rclone rclone || return 1
        report_rclone_gdrive_config
        return 0
    fi

    local latest current current_path managed_path arch asset_arch tmp bin
    managed_path="$HOME/.local/bin/rclone"
    latest="$(rclone_latest)" || latest=""
    current_path="$(command -v rclone 2>/dev/null || true)"
    current=""
    [ -n "$current_path" ] && current="$(tool_version rclone)"

    if [ -n "$current_path" ] && ! $FORCE; then
        if [ "$NO_UPDATE" = true ] || [ -z "$latest" ] || \
            { [ -n "$current" ] && version_at_least "$current" "$latest"; }
        then
            if [ "$current_path" = "$managed_path" ]; then
                manifest_add_path "$managed_path"
            fi
            if [ "$NO_UPDATE" = true ]; then
                echo "rclone present (update check skipped): $current_path"
            elif [ -z "$latest" ]; then
                echo "rclone present (latest version unknown): $current_path"
            else
                echo "rclone up to date ($current): $current_path"
            fi
            report_rclone_gdrive_config
            return 0
        fi
    fi

    [ -n "$latest" ] || {
        echo "  Warning: could not determine the latest rclone version"
        return 1
    }

    arch="$(machine_arch)"
    case "$arch" in
        x86_64) asset_arch="amd64" ;;
        aarch64) asset_arch="arm64" ;;
        *) echo "  Skipping rclone (unsupported arch: $arch)"; return 1 ;;
    esac

    echo "Installing rclone $latest..."
    tmp="$(mktemp -d)" || return 1
    trap 'rm -rf "${tmp:-}"' RETURN
    if ! retry curl -sfL -o "$tmp/rclone.zip" \
        "https://downloads.rclone.org/v${latest}/rclone-v${latest}-linux-${asset_arch}.zip"
    then
        echo "  Warning: failed to download rclone"
        return 1
    fi
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$tmp/rclone.zip" -d "$tmp/unpacked" || return 1
    elif command -v python3 >/dev/null 2>&1; then
        mkdir -p "$tmp/unpacked" || return 1
        python3 -m zipfile -e "$tmp/rclone.zip" "$tmp/unpacked" || return 1
    else
        echo "  Warning: rclone install needs unzip or python3"
        return 1
    fi
    bin="$(find "$tmp/unpacked" -type f -name rclone | head -1)"
    [ -n "$bin" ] || { echo "  Warning: rclone binary not found in archive"; return 1; }
    chmod +x "$bin" || return 1
    "$bin" version >/dev/null 2>&1 || {
        echo "  Warning: downloaded rclone binary failed its version check"
        return 1
    }
    mkdir -p "$HOME/.local/bin" || return 1
    mv -f "$bin" "$managed_path" || return 1
    chmod 755 "$managed_path" || return 1
    manifest_add_path "$managed_path" || return 1
    hash -r
    echo "  rclone $latest installed to $managed_path"
    [ -n "$current_path" ] && [ "$current_path" != "$managed_path" ] && \
        echo "  Preserved external rclone at $current_path"
    report_rclone_gdrive_config
}

# Latest Node.js LTS version string (e.g. "v22.4.0"), or empty on failure.
# Prefer jq, then python3. No grep fallback — the nodejs.org JSON layout is
# compact but not stable enough for regex, and python3 is effectively always
# available on our target systems.
node_latest_lts() {
    if command -v jq &>/dev/null; then
        retry curl -sfL https://nodejs.org/dist/index.json \
            | jq -r '[.[] | select(.lts != false)] | .[0].version'
    elif command -v python3 &>/dev/null; then
        retry curl -sfL https://nodejs.org/dist/index.json \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(e['version'] for e in d if e.get('lts')))"
    fi
}

install_node() {
    local MIN_NODE_MAJOR=18
    if is_macos; then
        brew_install node node
        return $?
    fi
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load node "Node.js" NODE_MODULE "${NODE_MODULE_CANDIDATES[@]}"
        return
    fi
    if command -v node &>/dev/null && ! $FORCE; then
        local cur_major NODE_LATEST
        cur_major="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
        NODE_LATEST="$(node_latest_lts)" || NODE_LATEST=""
        if [ -n "$cur_major" ] && [ "$cur_major" -ge "$MIN_NODE_MAJOR" ] 2>/dev/null; then
            # Meets the floor; defer to the version check for LTS upgrades.
            if update_guard "Node.js" node "$NODE_LATEST"; then
                record_node_manifest
                return 0
            fi
        else
            echo "Node.js $(node --version 2>/dev/null) is below the v${MIN_NODE_MAJOR} floor. Upgrading..."
        fi
    fi
    echo "Installing Node.js..."
    local ARCH NODE_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  NODE_ARCH="x64" ;;
        aarch64) NODE_ARCH="arm64" ;;
        *)       echo "  Skipping Node.js (unsupported arch: $ARCH)"; return 1 ;;
    esac
    local NODE_VERSION
    NODE_VERSION="$(node_latest_lts)"
    if [ -z "$NODE_VERSION" ]; then
        echo "  Cannot determine latest Node LTS: fetch failed, or neither jq nor python3 is available."
        echo "  Install one of them and re-run, or pass --force after installing Node manually."
        return 1
    fi
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive.tar.xz" "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"; then
        echo "  Warning: failed to download Node.js"
        return 1
    fi
    tar xJ -C "$TMP" --strip-components=1 -f "$TMP/archive.tar.xz"
    mkdir -p "$HOME/.local"
    # Remove stale symlinks (e.g. from old nvm-based installs) before copying
    rm -f "$HOME/.local/bin/node" "$HOME/.local/bin/npm" "$HOME/.local/bin/npx" "$HOME/.local/bin/corepack"
    # Install node tree into ~/.local (bin/, lib/, include/, share/)
    if ! cp -rf "$TMP/bin" "$TMP/lib" "$TMP/include" "$TMP/share" "$HOME/.local/"; then
        echo "  Node.js install failed - could not copy files into ~/.local"
        return 1
    fi
    # Clear bash's command hash so it finds the newly installed binaries
    hash -r
    if ! "$HOME/.local/bin/node" --version &>/dev/null; then
        echo "  Node.js install failed — binary not working"
        return 1
    fi
    record_node_manifest
    echo "  Node.js $NODE_VERSION installed to ~/.local"
}

# Install a global npm package into the user-writable ~/.local tree and verify
# the resulting command. Used by install_claude / install_codex.
npm_global_install() {
    local pkg="$1" cmd="$2"
    if ! command -v npm &>/dev/null; then
        echo "  npm not found — Node.js must be installed first (run_step node)."
        return 1
    fi
    # --prefix keeps the install in ~/.local on every host: the binary lands in
    # ~/.local/bin (already on PATH and where install.sh puts Node on Linux) and
    # the package in ~/.local/lib/node_modules. This avoids EACCES when an
    # active system Node has a root-owned global prefix, and keeps the install
    # tracked/removable by uninstall.sh.
    if ! retry npm install -g --prefix "$HOME/.local" "$pkg@latest"; then
        echo "  Warning: npm install -g $pkg failed"
        return 1
    fi
    hash -r
    if ! command -v "$cmd" &>/dev/null; then
        echo "  $cmd not found on PATH after npm install of $pkg"
        return 1
    fi
}

install_uv() {
    if is_macos; then
        brew_install uv uv
        return $?
    fi
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load uv "uv" UV_MODULE "${UV_MODULE_CANDIDATES[@]}"
        return
    fi
    local UV_VERSION
    UV_VERSION="$(gh_latest astral-sh/uv)" || UV_VERSION=""
    if update_guard uv uv "$UV_VERSION"; then
        record_command_if_managed uv || true
        record_command_if_managed uvx || true
        return 0
    fi
    echo "Installing uv..."
    local UV_ARCH TMP
    UV_ARCH="$(machine_arch)"
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/archive.tar.gz" "https://github.com/astral-sh/uv/releases/latest/download/uv-${UV_ARCH}-unknown-linux-musl.tar.gz"; then
        echo "  Warning: failed to download uv"
        return 1
    fi
    tar xz -C "$TMP" -f "$TMP/archive.tar.gz"
    local uv_dir
    uv_dir="$(find "$TMP" -maxdepth 1 -type d -name 'uv-*' | head -1)"
    if [ -z "$uv_dir" ]; then
        echo "  Warning: uv archive had unexpected layout"
        return 1
    fi
    mkdir -p "$HOME/.local/bin"
    if ! install_to "$uv_dir/uv" "$HOME/.local/bin/uv" || \
       ! install_to "$uv_dir/uvx" "$HOME/.local/bin/uvx"; then
        echo "  Warning: failed to install uv binaries"
        return 1
    fi
    manifest_add_path "$HOME/.local/bin/uv"
    manifest_add_path "$HOME/.local/bin/uvx"
    echo "  uv $(uv --version) installed"
}

install_code_cli() {
    # Microsoft's standalone `code` CLI (tunnel CLI). Skip on macOS where
    # users run the full VS Code locally; this binary is meant for remote
    # hosts where you launch `code tunnel`.
    if is_macos; then
        return 0
    fi
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load code "VS Code CLI" CODE_CLI_MODULE "${CODE_CLI_MODULE_CANDIDATES[@]}"
        return
    fi
    if command -v code &>/dev/null && ! $FORCE; then
        # Only treat the existing binary as managed when it's the standalone
        # tunnel CLI, not some unrelated `code` in PATH (e.g. a wrapper).
        if code --version 2>&1 | head -3 | grep -qiE 'tunnel|stable|x64|arm64'; then
            record_command_if_managed code || true
            echo "code CLI already installed: $(code --version 2>/dev/null | head -1)"
            return 0
        fi
    fi
    echo "Installing VS Code CLI (code)..."
    local ARCH CODE_ARCH TMP
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  CODE_ARCH="cli-linux-x64" ;;
        aarch64) CODE_ARCH="cli-linux-arm64" ;;
        *) echo "  Skipping code CLI (unsupported arch: $ARCH)"; return 1 ;;
    esac
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/code.tar.gz" "https://update.code.visualstudio.com/latest/${CODE_ARCH}/stable"; then
        echo "  Warning: failed to download VS Code CLI"
        return 1
    fi
    if ! tar xz -C "$TMP" -f "$TMP/code.tar.gz"; then
        echo "  Warning: failed to extract VS Code CLI archive"
        return 1
    fi
    if [ ! -f "$TMP/code" ]; then
        echo "  Warning: VS Code CLI archive had unexpected layout"
        return 1
    fi
    mkdir -p "$HOME/.local/bin"
    chmod +x "$TMP/code"
    if ! install_to "$TMP/code" "$HOME/.local/bin/code"; then
        echo "  Warning: failed to install code binary"
        return 1
    fi
    hash -r
    manifest_add_path "$HOME/.local/bin/code"
    echo "  code $("$HOME/.local/bin/code" --version 2>/dev/null | head -1) installed"
}


glibc_version() {
    local first_line

    command -v ldd &>/dev/null || return 0
    first_line="$(ldd --version 2>/dev/null | head -1 || true)"
    case "$first_line" in
        *GLIBC*|*GNU\ libc*)
            # Last whitespace-separated token on the line is the version,
            # e.g. "ldd (Ubuntu GLIBC 2.35-0ubuntu3.1) 2.35" -> "2.35".
            printf '%s\n' "$first_line" | awk '{print $NF}'
            ;;
    esac
}

install_nvim_tarball() {
    local label="$1" url="$2" tmp="$3"
    local work_dir extracted_dir install_dir target_bin

    echo "  Trying $label Neovim tarball..."
    rm -rf "$tmp/nvim-tarball" "$tmp/nvim.tar.gz"
    work_dir="$tmp/nvim-tarball"
    mkdir -p "$work_dir" || return 1

    if ! retry curl -sfL -o "$tmp/nvim.tar.gz" "$url"; then
        echo "  Warning: failed to download $label Neovim tarball"
        return 1
    fi
    if ! tar xz -C "$work_dir" -f "$tmp/nvim.tar.gz"; then
        echo "  Warning: failed to extract $label Neovim tarball"
        return 1
    fi

    extracted_dir="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
    if [ -z "$extracted_dir" ] || [ ! -x "$extracted_dir/bin/nvim" ]; then
        echo "  Warning: $label Neovim tarball had unexpected layout"
        return 1
    fi
    if ! "$extracted_dir/bin/nvim" --version &>/dev/null; then
        echo "  $label Neovim tarball is not compatible with this system"
        return 1
    fi

    install_dir="$HOME/.local/opt/nvim"
    target_bin="$HOME/.local/bin/nvim"
    if [ -d "$target_bin" ] && [ ! -L "$target_bin" ]; then
        echo "  Warning: cannot replace directory $target_bin"
        return 1
    fi

    mkdir -p "$(dirname "$install_dir")" "$HOME/.local/bin" || return 1
    rm -rf "$install_dir"
    if ! mv "$extracted_dir" "$install_dir"; then
        echo "  Warning: failed to install Neovim to $install_dir"
        return 1
    fi
    rm -f "$target_bin"
    if ! ln -s "$install_dir/bin/nvim" "$target_bin"; then
        echo "  Warning: failed to link Neovim to $target_bin"
        return 1
    fi

    hash -r
    manifest_add_path "$target_bin"
    manifest_add_path "$install_dir"
    echo "  $("$target_bin" --version 2>/dev/null | head -1) installed to $install_dir"
}

install_nvim_appimage() {
    local label="$1" url="$2" tmp="$3"
    local target_bin="$HOME/.local/bin/nvim"

    echo "  Trying $label Neovim AppImage..."
    rm -f "$tmp/nvim.appimage"
    if ! retry curl -sfL -o "$tmp/nvim.appimage" "$url"; then
        echo "  Warning: failed to download $label Neovim AppImage"
        return 1
    fi

    chmod +x "$tmp/nvim.appimage"
    if ! "$tmp/nvim.appimage" --version &>/dev/null; then
        echo "  $label Neovim AppImage is not compatible with this system"
        return 1
    fi
    if [ -d "$target_bin" ] && [ ! -L "$target_bin" ]; then
        echo "  Warning: cannot replace directory $target_bin"
        return 1
    fi

    mkdir -p "$HOME/.local/bin" || return 1
    rm -f "$target_bin"
    if ! mv "$tmp/nvim.appimage" "$target_bin"; then
        echo "  Warning: failed to install Neovim to $target_bin"
        return 1
    fi
    hash -r
    manifest_add_path "$target_bin"
    echo "  $("$target_bin" --version 2>/dev/null | head -1) installed to $target_bin"
}

install_nvim() {
    if is_macos; then
        brew_install neovim nvim
        return $?
    fi
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load nvim "Neovim" NVIM_MODULE "${NVIM_MODULE_CANDIDATES[@]}"
        return
    fi
    if command -v nvim &>/dev/null && ! $FORCE; then
        local current_version NVIM_LATEST
        current_version="$(nvim --version 2>/dev/null | head -1 | sed 's/NVIM v//')"
        NVIM_LATEST="$(gh_latest neovim/neovim)" || NVIM_LATEST=""
        if ! version_at_least "${current_version}" "0.9.0"; then
            # Below the hard floor: reinstall regardless of latest-version fetch.
            echo "Upgrading nvim from v${current_version} (below 0.9.0 floor)..."
        elif update_guard nvim nvim "$NVIM_LATEST"; then
            record_nvim_manifest || true
            return 0
        fi
    fi

    echo "Installing Neovim..."
    local ARCH NVIM_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  NVIM_ARCH="x86_64" ;;
        aarch64) NVIM_ARCH="arm64" ;;
        *)  echo "  Skipping nvim (unsupported arch: $ARCH)"; return 1 ;;
    esac

    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN

    local detected_glibc official_tarball official_appimage legacy_tarball
    detected_glibc="$(glibc_version)"
    official_tarball="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${NVIM_ARCH}.tar.gz"
    official_appimage="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${NVIM_ARCH}.appimage"
    legacy_tarball="https://github.com/neovim/neovim-releases/releases/latest/download/nvim-linux-x86_64.tar.gz"

    if [ "$ARCH" = "x86_64" ] && [ -n "$detected_glibc" ]; then
        if ! version_at_least "$detected_glibc" "2.17"; then
            echo "  glibc $detected_glibc is too old for Neovim release binaries (need >= 2.17)."
            echo "  Try: ./install.sh --use-modules   (if on an HPC cluster with an nvim module)"
            return 1
        fi
        if ! version_at_least "$detected_glibc" "2.31"; then
            echo "  glibc $detected_glibc is old; using Neovim's legacy glibc 2.17 build."
            install_nvim_tarball "legacy" "$legacy_tarball" "$TMP" && return 0
            echo "  Warning: could not install Neovim from the legacy glibc build"
            echo "  Try: ./install.sh --use-modules   (if on an HPC cluster with an nvim module)"
            return 1
        fi
    fi

    install_nvim_tarball "official" "$official_tarball" "$TMP" && return 0
    install_nvim_appimage "official" "$official_appimage" "$TMP" && return 0

    if [ "$ARCH" = "x86_64" ]; then
        echo "  Falling back to Neovim's legacy glibc 2.17 build..."
        install_nvim_tarball "legacy" "$legacy_tarball" "$TMP" && return 0
    elif [ -n "$detected_glibc" ] && ! version_at_least "$detected_glibc" "2.31"; then
        echo "  Warning: old-glibc Neovim fallback is only published for x86_64."
    fi

    echo "  Warning: could not install Neovim"
    echo "  Try: ./install.sh --use-modules   (if on an HPC cluster with an nvim module)"
    return 1
}

install_tree_sitter_cargo() {
    # $1 (optional): version pin, e.g. "0.25.10". When set, cargo installs
    # exactly that version instead of "latest". Pinning matches the prebuilt
    # binary's version when available, so the cargo fallback can't drift
    # away from the version that matches our locked nvim-treesitter.
    local pin="${1:-}"
    if ! command -v cargo &>/dev/null; then
        echo "  Warning: cargo not installed; cannot build tree-sitter from source."
        echo "  Install rustup (https://rustup.rs) and re-run install.sh, or install tree-sitter manually."
        return 1
    fi
    if [ -n "$pin" ]; then
        echo "  Building tree-sitter $pin from source via cargo (this may take a few minutes)..."
    else
        echo "  Building tree-sitter from source via cargo (this may take a few minutes)..."
    fi
    local TMP cargo_args=(--quiet --locked --root)
    TMP="$(mktemp -d)"
    cargo_args+=("$TMP")
    [ -n "$pin" ] && cargo_args+=(--version "$pin")
    cargo_args+=(tree-sitter-cli)
    if ! cargo install "${cargo_args[@]}" 2>&1 | tail -3; then
        echo "  Warning: cargo install tree-sitter-cli failed"
        rm -rf "$TMP"
        return 1
    fi
    if [ ! -x "$TMP/bin/tree-sitter" ]; then
        echo "  Warning: cargo install did not produce tree-sitter binary"
        rm -rf "$TMP"
        return 1
    fi
    if ! install_to "$TMP/bin/tree-sitter" "$BIN_DIR/tree-sitter"; then
        echo "  Warning: failed to install tree-sitter to $BIN_DIR/tree-sitter"
        rm -rf "$TMP"
        return 1
    fi
    rm -rf "$TMP"
    manifest_add_path "$BIN_DIR/tree-sitter"
    echo "  tree-sitter${pin:+ $pin} (built from source) installed to $BIN_DIR/tree-sitter"
}

install_tree_sitter() {
    if is_macos; then
        brew_install tree-sitter-cli tree-sitter
        return $?
    fi
    # Only short-circuit on successful module load; if no module exists on
    # this CHPC system, fall through to the binary/cargo install path.
    if is_chpc && $CHPC_USE_MODULES && [ "${#TREE_SITTER_MODULE_CANDIDATES[@]}" -gt 0 ]; then
        if try_chpc_module_load tree-sitter "tree-sitter CLI" \
            TREE_SITTER_MODULE "${TREE_SITTER_MODULE_CANDIDATES[@]}"; then
            return 0
        fi
    fi
    # Resolve the target version BEFORE the update check so we compare against
    # what we would actually install, not raw latest.
    # tree-sitter prebuilts >= 0.25.x are linked against glibc 2.36+. On hosts
    # with older glibc (e.g. Ubuntu 22.04 = glibc 2.35), the prebuilt aborts at
    # load time. 0.24.7 is the last release built on Ubuntu 22.04 / glibc 2.35
    # and is still accepted by nvim-treesitter for parser builds. Bump this pin
    # when an even-newer glibc cutoff is needed.
    local TS_FALLBACK_VERSION="0.24.7"
    local TS_VERSION detected_glibc ts_pinned=false
    TS_VERSION="$(gh_latest tree-sitter/tree-sitter)" || TS_VERSION=""
    detected_glibc="$(glibc_version 2>/dev/null || true)"
    if [ -n "$TS_VERSION" ] && [ -n "$detected_glibc" ] && ! version_at_least "$detected_glibc" "2.36"; then
        TS_VERSION="$TS_FALLBACK_VERSION"
        ts_pinned=true
    fi
    if update_guard tree-sitter tree-sitter "$TS_VERSION"; then
        record_command_if_managed tree-sitter || true
        return 0
    fi
    echo "Installing tree-sitter CLI..."
    [ -n "$TS_VERSION" ] || { echo "  Warning: could not determine latest tree-sitter version"; return 1; }
    $ts_pinned && echo "  glibc $detected_glibc detected; pinning tree-sitter to $TS_VERSION (last release built on glibc 2.35)."
    local ARCH TS_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  TS_ARCH="x64"   ;;
        aarch64) TS_ARCH="arm64" ;;
        *)       echo "  Skipping tree-sitter (unsupported arch: $ARCH)"; return 1 ;;
    esac
    local TMP
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP:-}"' RETURN
    if ! retry curl -sfL -o "$TMP/tree-sitter.gz" \
        "https://github.com/tree-sitter/tree-sitter/releases/download/v${TS_VERSION}/tree-sitter-linux-${TS_ARCH}.gz"; then
        echo "  Warning: failed to download tree-sitter"
        install_tree_sitter_cargo "$TS_VERSION"
        return $?
    fi
    if ! gunzip "$TMP/tree-sitter.gz"; then
        echo "  Warning: failed to gunzip tree-sitter"
        install_tree_sitter_cargo "$TS_VERSION"
        return $?
    fi
    chmod +x "$TMP/tree-sitter"
    # The prebuilt binary is dynamically linked against modern glibc; on hosts
    # with older glibc (e.g. CHPC RHEL 8 = glibc 2.28), it fails to run. Probe
    # before installing, and fall back to building from source via cargo at
    # the same version so the binary and cargo paths stay deterministic.
    if ! "$TMP/tree-sitter" --version &>/dev/null; then
        echo "  Prebuilt tree-sitter incompatible with this host's glibc; falling back to cargo build."
        install_tree_sitter_cargo "$TS_VERSION"
        return $?
    fi
    if ! install_to "$TMP/tree-sitter" "$BIN_DIR/tree-sitter"; then
        echo "  Warning: failed to install tree-sitter to $BIN_DIR/tree-sitter"
        return 1
    fi
    manifest_add_path "$BIN_DIR/tree-sitter"
    echo "  tree-sitter $TS_VERSION installed to $BIN_DIR/tree-sitter"
}

install_gh_tools() {
    # jq is installed earlier in setup_main so install_node and friends
    # can use it; it is intentionally absent from this list.
    if [ "${DRY_RUN:-false}" = true ]; then
        for tool in fzf ripgrep fd bat delta zoxide lazygit btop starship atuin; do
            run_step "$tool" true
        done
        return 0
    fi

    if is_macos; then
        run_step "fzf"      brew_install fzf fzf
        run_step "ripgrep"  brew_install ripgrep rg
        run_step "fd"       brew_install fd fd
        run_step "bat"      brew_install bat bat
        run_step "delta"    brew_install git-delta delta
        run_step "zoxide"   brew_install zoxide zoxide
        run_step "lazygit"  brew_install lazygit lazygit
        run_step "btop"     brew_install btop btop
        run_step "starship" brew_install starship starship
        run_step "atuin"    brew_install atuin atuin
        return 0
    fi

    local ARCH DEB_ARCH GH_ARCH
    ARCH="$(machine_arch)"
    case "$ARCH" in
        x86_64)  DEB_ARCH="amd64"; GH_ARCH="x86_64" ;;
        aarch64) DEB_ARCH="arm64"; GH_ARCH="aarch64" ;;
        *)       echo "Skipping binary installs (unsupported arch: $ARCH)"; return 0 ;;
    esac

    local V

    if V="$(gh_latest junegunn/fzf)"; then
        run_step "fzf" install_gh_binary fzf \
            "https://github.com/junegunn/fzf/releases/download/v${V}/fzf-${V}-linux_${DEB_ARCH}.tar.gz" fzf "$V"
    else FAILURES+=("fzf"); fi

    if V="$(gh_latest BurntSushi/ripgrep)"; then
        run_step "ripgrep" install_gh_binary ripgrep \
            "https://github.com/BurntSushi/ripgrep/releases/download/${V}/ripgrep-${V}-${GH_ARCH}-unknown-linux-musl.tar.gz" rg "$V"
    else FAILURES+=("ripgrep"); fi

    if V="$(gh_latest sharkdp/fd)"; then
        run_step "fd" install_gh_binary fd \
            "https://github.com/sharkdp/fd/releases/download/v${V}/fd-v${V}-${GH_ARCH}-unknown-linux-musl.tar.gz" fd "$V"
    else FAILURES+=("fd"); fi

    if V="$(gh_latest sharkdp/bat)"; then
        run_step "bat" install_gh_binary bat \
            "https://github.com/sharkdp/bat/releases/download/v${V}/bat-v${V}-${GH_ARCH}-unknown-linux-musl.tar.gz" bat "$V"
    else FAILURES+=("bat"); fi

    if V="$(gh_latest dandavison/delta)"; then
        local DELTA_LIBC="musl"
        [ "$GH_ARCH" = "aarch64" ] && DELTA_LIBC="gnu"
        run_step "delta" install_gh_binary delta \
            "https://github.com/dandavison/delta/releases/download/${V}/delta-${V}-${GH_ARCH}-unknown-linux-${DELTA_LIBC}.tar.gz" delta "$V"
    else FAILURES+=("delta"); fi

    if V="$(gh_latest ajeetdsouza/zoxide)"; then
        run_step "zoxide" install_gh_binary zoxide \
            "https://github.com/ajeetdsouza/zoxide/releases/download/v${V}/zoxide-${V}-${GH_ARCH}-unknown-linux-musl.tar.gz" zoxide "$V"
    else FAILURES+=("zoxide"); fi

    local LAZYGIT_ARCH="$GH_ARCH"
    [ "$LAZYGIT_ARCH" = "aarch64" ] && LAZYGIT_ARCH="arm64"
    if V="$(gh_latest jesseduffield/lazygit)"; then
        run_step "lazygit" install_gh_binary lazygit \
            "https://github.com/jesseduffield/lazygit/releases/download/v${V}/lazygit_${V}_Linux_${LAZYGIT_ARCH}.tar.gz" lazygit "$V"
    else FAILURES+=("lazygit"); fi

    if is_chpc && $CHPC_USE_MODULES; then
        run_step "btop" try_chpc_module_load btop "btop" BTOP_MODULE "${BTOP_MODULE_CANDIDATES[@]}"
    elif V="$(gh_latest aristocratos/btop)"; then
        run_step "btop" install_gh_binary btop \
            "https://github.com/aristocratos/btop/releases/download/v${V}/btop-${GH_ARCH}-unknown-linux-musl.tar.gz" btop "$V"
    else FAILURES+=("btop"); fi

    if V="$(gh_latest starship/starship)"; then
        run_step "starship" install_gh_binary starship \
            "https://github.com/starship/starship/releases/download/v${V}/starship-${GH_ARCH}-unknown-linux-musl.tar.gz" starship "$V"
    else FAILURES+=("starship"); fi

    if V="$(gh_latest atuinsh/atuin)"; then
        run_step "atuin" install_gh_binary atuin \
            "https://github.com/atuinsh/atuin/releases/download/v${V}/atuin-${GH_ARCH}-unknown-linux-musl.tar.gz" atuin "$V"
    else FAILURES+=("atuin"); fi
}

install_claude() {
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load claude "Claude Code" CLAUDE_MODULE "${CLAUDE_MODULE_CANDIDATES[@]}"
        return
    fi

    # Claude Code ships a native, self-updating binary (~/.local/bin/claude ->
    # ~/.local/share/claude/versions/<v>), no longer an npm package. We still read
    # the npm-published version as the "latest" signal for update_guard (it tracks
    # the native release stream), but install/update via the native tooling — never
    # npm, which would collide with the native ~/.local/bin/claude symlink (EEXIST).
    local CLAUDE_LATEST
    CLAUDE_LATEST="$(retry npm view @anthropic-ai/claude-code version 2>/dev/null)" || CLAUDE_LATEST=""
    if update_guard "Claude Code" claude "$CLAUDE_LATEST"; then
        record_command_if_managed claude || true
        return 0
    fi
    if command -v claude &>/dev/null; then
        # Existing install: use the native self-updater. --force reinstalls the
        # latest native build (also migrates a legacy npm install to native).
        if $FORCE; then
            echo "Reinstalling Claude Code (native: claude install latest)..."
            claude install latest
        else
            echo "Updating Claude Code (native: claude update)..."
            claude update
        fi
    else
        # Fresh host: bootstrap via the official native installer. Installs to
        # ~/.local/bin/claude + ~/.local/share/claude/versions/<v>.
        echo "Installing Claude Code via the native installer..."
        if ! retry bash -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
            echo "  Claude Code install failed"
            return 1
        fi
    fi
    hash -r
    if ! command -v claude &>/dev/null; then
        echo "  Claude Code install failed — binary not found on PATH"
        return 1
    fi
    record_command_if_managed claude || true
    manifest_add_path "$HOME/.local/share/claude"
    echo "  Claude Code $(claude --version 2>&1 | head -1) installed. Run 'claude' to authenticate."
}

install_codex() {
    if is_chpc && $CHPC_USE_MODULES; then
        try_chpc_module_load codex "Codex" CODEX_MODULE "${CODEX_MODULE_CANDIDATES[@]}"
        return
    fi

    local CODEX_LATEST
    CODEX_LATEST="$(retry npm view @openai/codex version 2>/dev/null)" || CODEX_LATEST=""
    if update_guard "Codex CLI" codex "$CODEX_LATEST"; then
        record_command_if_managed codex || true
        return 0
    fi
    echo "Installing Codex CLI via npm (@openai/codex)..."
    if ! npm_global_install "@openai/codex" codex; then
        echo "  Codex CLI install failed"
        return 1
    fi
    record_command_if_managed codex || true
    manifest_add_path "$HOME/.local/lib/node_modules/@openai/codex"
    echo "  Codex CLI $(codex --version 2>&1 | head -1) installed. Run 'codex' to authenticate."
}

install_tpm() {
    local tpm_dir="$HOME/.tmux/plugins/tpm"
    if [ -d "$tpm_dir" ]; then
        echo "TPM already installed"
        return 0
    fi
    echo "Installing TPM (Tmux Plugin Manager)..."
    if ! git clone --depth 1 https://github.com/tmux-plugins/tpm "$tpm_dir" 2>/dev/null; then
        echo "  Warning: failed to clone TPM"
        return 1
    fi
    echo "  TPM installed. Press prefix + I inside tmux to install plugins."
}

install_plugins() {
    "$DIR/scripts/install_claude_plugins.sh"
}

install_chpc_allocs() {
    if ! is_chpc; then
        echo "  Skipping chpc-allocs (not on CHPC)"
        return 0
    fi
    if [ ! -f "$DIR/scripts/chpc-allocs.py" ]; then
        echo "  Skipping chpc-allocs (source missing)"
        return 1
    fi
    chmod +x "$DIR/scripts/chpc-allocs.py" 2>/dev/null || true
    backup_and_link "$DIR/scripts/chpc-allocs.py" "$BIN_DIR/chpc-allocs" || return 1
    manifest_add_path "$BIN_DIR/chpc-allocs"
}

# detect-theme: shared helper called by bashrc, zshrc, tmux, vim, and nvim.
# Keep this in ~/.local/bin because every shell rc prepends that path and the
# configs call this helper directly from there.
install_detect_theme() {
    if [ ! -f "$DIR/scripts/detect-theme.sh" ]; then
        echo "  Skipping detect-theme (source missing)"
        return 1
    fi
    chmod +x "$DIR/scripts/detect-theme.sh" 2>/dev/null || true
    mkdir -p "$HOME/.local/bin" || return 1
    backup_and_link "$DIR/scripts/detect-theme.sh" "$HOME/.local/bin/detect-theme" || return 1
    manifest_add_path "$HOME/.local/bin/detect-theme"
}

# One-shot migration: older installs appended `Include $DIR/ssh/sshconfig`
# to ~/.ssh/config and created ~/.ssh/sockets for ControlMaster. Both are
# gone now — strip the Include line and rmdir the (empty) sockets dir so
# upgrading hosts end up clean. Idempotent: no-ops once the line is gone.
# Safe to delete entirely after enough time has passed for all hosts to
# have run install.sh at least once post-removal.
unwire_ssh_config_legacy() {
    local config="$HOME/.ssh/config"
    if [ -f "$config" ] && [ ! -L "$config" ]; then
        clean_line_from_file "$config" "^Include $DIR/ssh/sshconfig\$"
    fi
    remove_dir_if_empty "$HOME/.ssh/sockets"
}

link_core_configs() {
    mkdir -p "$HOME/.config" "$HOME/.vim/undodir" "$HOME/.local/lib" || return 1
    backup_and_link "$DIR/lib/vscode-tunnel.sh" "$HOME/.local/lib/vscode-tunnel.sh" || return 1
    backup_and_link "$DIR/editor/vimrc" "$HOME/.vimrc" || return 1
    backup_and_link "$DIR/tmux/tmux.conf" "$HOME/.tmux.conf" || return 1
    backup_and_link "$DIR/editor/nvim" "$HOME/.config/nvim" || return 1
    backup_and_link "$DIR/git/gitconfig" "$HOME/.gitconfig" || return 1
    backup_and_link "$DIR/shell/inputrc" "$HOME/.inputrc" || return 1
    backup_and_link "$DIR/shell/dircolors" "$HOME/.dircolors" || return 1
    backup_and_link "$DIR/shell/dircolors.light" "$HOME/.dircolors.light" || return 1
    unwire_ssh_config_legacy || true
    backup_and_link "$DIR/shell/starship.toml" "$HOME/.config/starship.toml" || return 1
    backup_and_link "$DIR/shell/starship-light.toml" "$HOME/.config/starship-light.toml" || return 1
    # XDG-compliant tmux path (tmux 3.2+ reads this natively)
    mkdir -p "$HOME/.config/tmux" 2>/dev/null || true
    backup_and_link "$DIR/tmux/tmux.conf" "$HOME/.config/tmux/tmux.conf" || return 1
}

link_generated_configs() {
    backup_and_link "$GENERATED_DIR/tmux-theme.conf" "$HOME/.tmux-theme.conf" || return 1
    backup_and_link "$DIR/shell/bashrc_exports" "$HOME/.bashrc_exports" || return 1
    backup_and_link "$DIR/shell/bashrc_aliases" "$HOME/.bashrc_aliases" || return 1
    backup_and_copy "$CLAUDE_SETTINGS_SRC" "$HOME/.claude/settings.json" || return 1
    manifest_add_path "$HOME/.claude/settings.json" || return 1
    backup_and_copy "$CODEX_CONFIG_SRC" "$HOME/.codex/config.toml" || return 1
    manifest_add_path "$HOME/.codex/config.toml" || return 1
    append_line_if_missing 'source ~/.bashrc_exports' "$HOME/.bashrc" || return 1
    append_line_if_missing 'source ~/.bashrc_aliases' "$HOME/.bashrc" || return 1
    link_zsh_configs || return 1
}

# Run scripts/install_claude_skills.sh to clone upstream skill repos
# (obra/superpowers, anthropics/skills) into ~/.local/share/claude-skills/
# and symlink the curated set into ~/.claude/skills/. Forwards --force and
# --dry-run so a top-level `./install.sh --force` re-clones upstream too.
install_external_claude_skills() {
    local args=()
    [ "$FORCE" = true ]   && args+=(--force)
    [ "$DRY_RUN" = true ] && args+=(--dry-run)
    bash "$DIR/scripts/install_claude_skills.sh" ${args[@]+"${args[@]}"}
}

# Symlink every directory under ai/skills/ into ~/.claude/skills/<name>.
# Skills are pure markdown so no CHPC gate is needed (unlike MCP servers,
# which are still installed only by scripts/install_claude_plugins.sh).
# Unlike claude_settings.json (per-host overrides → copy), skills are
# shared knowledge that should track the repo, so they are symlinked.
link_claude_skills() {
    local skills_src="$DIR/ai/skills"
    local skills_dst="$HOME/.claude/skills"
    local skill_dir name dst

    if [ ! -d "$skills_src" ]; then
        return 0
    fi

    mkdir -p "$skills_dst" || return 1

    for skill_dir in "$skills_src"/*/; do
        [ -d "$skill_dir" ] || continue
        [ -f "${skill_dir}SKILL.md" ] || continue
        name="$(basename "$skill_dir")"
        dst="$skills_dst/$name"
        # Strip trailing slash so the symlink target is the directory itself,
        # not "<dir>/" — ln -sf with a trailing slash creates a link inside.
        backup_and_link "${skill_dir%/}" "$dst" || return 1
        manifest_add_path "$dst" || return 1
    done
}

# The Notchpeak HPC agent guide (chpc/CLAUDE.md) is CHPC-specific operational
# knowledge that should track the repo verbatim (like skills), so symlink it --
# but only on CHPC, where ~/CLAUDE.md is the guide every agent loads. On first
# run backup_and_link moves any pre-existing real ~/CLAUDE.md to ~/CLAUDE.md.bak.
link_chpc_agent_guide() {
    is_chpc || return 0
    backup_and_link "$DIR/chpc/CLAUDE.md" "$HOME/CLAUDE.md" || return 1
    manifest_add_path "$HOME/CLAUDE.md" || return 1
}

# CloudLab nodes are bare-metal experiments with root, no SLURM/Lmod, and
# ephemeral local disk. cloudlab/CLAUDE.md is the operational guide every agent
# on a CloudLab node should load; symlink it like the CHPC guide, but only on
# CloudLab. is_cloudlab and is_chpc never both match on a real host (disjoint
# hostnames and path markers), so only one links ~/CLAUDE.md.
link_cloudlab_agent_guide() {
    is_cloudlab || return 0
    backup_and_link "$DIR/cloudlab/CLAUDE.md" "$HOME/CLAUDE.md" || return 1
    manifest_add_path "$HOME/CLAUDE.md" || return 1
}

# Zsh parallel of the bashrc wiring above. Always runs on macOS (zsh is the
# default login shell since Catalina); runs elsewhere only if zsh is
# installed, so Linux hosts without zsh skip cleanly.
link_zsh_configs() {
    if ! is_macos && ! command -v zsh &>/dev/null; then
        return 0
    fi
    backup_and_link "$DIR/shell/zshrc_exports" "$HOME/.zshrc_exports" || return 1
    backup_and_link "$DIR/shell/zshrc_aliases" "$HOME/.zshrc_aliases" || return 1

    # Don't append through ~/.zshrc if it's a symlink — could write into
    # another dotfiles repo.
    local zshrc="$HOME/.zshrc"
    if is_managed_symlink "$zshrc"; then
        echo "  ~/.zshrc already managed by this repo"
        return 0
    fi
    if [ -L "$zshrc" ]; then
        local target
        target="$(portable_realpath "$zshrc" 2>/dev/null || true)"
        if [ -z "$target" ]; then
            backup_and_link "$DIR/shell/zshrc" "$zshrc" || return 1
            return 0
        fi
        echo "  ~/.zshrc is a symlink to $target — skipping zsh source wiring." >&2
        echo "    Add these lines manually to that file (or its source) for zsh support:" >&2
        echo "      source ~/.zshrc_exports" >&2
        echo "      source ~/.zshrc_aliases" >&2
        return 0
    fi
    if [ -e "$zshrc" ]; then
        append_line_if_missing 'source ~/.zshrc_exports' "$zshrc" || return 1
        append_line_if_missing 'source ~/.zshrc_aliases' "$zshrc" || return 1
    else
        backup_and_link "$DIR/shell/zshrc" "$zshrc" || return 1
    fi
}

setup_main() {
    FORCE=false
    DRY_RUN=false
    FAILURES=()
    reset_module_vars

    for arg in "$@"; do
        case "$arg" in
            --force|-f) FORCE=true ;;
            --dry-run|-n) DRY_RUN=true ;;
            --no-update) NO_UPDATE=true ;;
            --use-modules|-m) CHPC_USE_MODULES=true ;;
            --probe-modules)
                probe_chpc_modules
                return $?
                ;;
            -h|--help)
                echo "Usage: install.sh [--force|-f] [--dry-run|-n] [--no-update] [--use-modules|-m] [--probe-modules] [--help|-h]"
                echo "  -f, --force        Reinstall CLI tools even if already present and current"
                echo "  -n, --dry-run      Show install steps without changing files"
                echo "      --no-update    Skip the latest-version check; keep already-installed tools as-is"
                echo "  -m, --use-modules  On CHPC, prefer module load over binary install"
                echo "      --probe-modules  Report which CHPC module candidates resolve, then exit"
                echo "  -h, --help         Show this help"
                return 0
                ;;
            *)
                echo "Unknown option: $arg"
                echo "Run './install.sh --help' for usage."
                return 1
                ;;
        esac
    done

    export PATH="$HOME/.local/bin:$PATH"
    trap _setup_cleanup EXIT

    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$GENERATED_DIR" || return 1
        chmod 700 "$GENERATED_DIR" 2>/dev/null || true
        # Manifest contract: truncate-and-rebuild on every run. Each
        # idempotent install function calls manifest_add_path /
        # record_command_if_managed even on its early-return path, so a
        # successful re-run (no install steps invoked) still produces a
        # complete manifest. If a run dies mid-way, the next run rebuilds
        # cleanly. Do NOT call uninstall.sh between a killed run and a
        # subsequent re-run — the partial manifest will leak un-tracked
        # files. Tested by test_manifest_controls_uninstall.
        : > "$INSTALL_MANIFEST"

        # Point this clone at the repo-local git hooks (idempotent; only when
        # run from inside the repo itself).
        if [ -d "$DIR/.git" ] && command -v git &>/dev/null; then
            if [ "$(git -C "$DIR" config --get core.hooksPath 2>/dev/null)" != ".githooks" ]; then
                git -C "$DIR" config core.hooksPath .githooks 2>/dev/null || true
            fi
        fi

        # Drop the shell-init cache so the next interactive bash regenerates
        # `atuin init`, `zoxide init`, `fzf --bash` against any newly
        # installed/upgraded binaries (matches I14 in the robustness plan).
        rm -rf "$HOME/.cache/dotfiles" 2>/dev/null || true
    fi

    echo "Linking config files..."
    run_step "core config links" link_core_configs

    # Determine install directories based on write access
    NEED_SUDO=""
    if [ "$DRY_RUN" = true ]; then
        BIN_DIR="$HOME/.local/bin"
    elif is_macos; then
        BIN_DIR="$HOME/.local/bin"
        mkdir -p "$BIN_DIR"
    elif [ -w /usr/local/bin ]; then
        BIN_DIR="/usr/local/bin"
    elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        BIN_DIR="/usr/local/bin"
        NEED_SUDO=1
    else
        BIN_DIR="$HOME/.local/bin"
        mkdir -p "$BIN_DIR"
    fi

    # Install tools (each step continues on failure).
    # jq goes first so install_node (which parses the nodejs.org JSON index)
    # can use it instead of falling back to python3 — and so any future
    # caller can rely on jq being present.
    run_step "gh"           install_gh_cli
    run_step "jq"           install_jq
    run_step "rclone"       install_rclone
    run_step "glow"         install_glow
    run_step "gum"          install_gum
    run_step "node"         install_node
    run_step "uv"           install_uv
    run_step "code (tunnel CLI)"   install_code_cli
    install_gh_tools
    run_step "tree-sitter"  install_tree_sitter
    run_step "nvim"         install_nvim
    run_step "tpm"          install_tpm
    run_step "claude"       install_claude
    run_step "codex"        install_codex
    run_step "chpc-allocs"  install_chpc_allocs
    run_step "detect-theme" install_detect_theme

    run_step "compat configs" render_compat_configs

    # Link remaining configs
    run_step "shell config links" link_generated_configs
    run_step "claude skills"      link_claude_skills
    run_step "external skills"    install_external_claude_skills
    run_step "chpc agent guide"   link_chpc_agent_guide
    run_step "cloudlab agent guide" link_cloudlab_agent_guide
    # Source bashrc only in interactive shells; non-interactive may lack shopt etc.
    if [[ $- == *i* ]] && [ "$DRY_RUN" = false ]; then
        # shellcheck source=/dev/null
        source "$HOME/.bashrc"
    fi

    run_step "claude plugins" install_plugins

    # --- Summary ---
    echo ""
    if [ ${#FAILURES[@]} -gt 0 ]; then
        echo "Setup complete with ${#FAILURES[@]} warning(s):"
        for f in "${FAILURES[@]}"; do
            echo "  - $f (optional)"
        done
        echo ""
        echo "Compatibility report: $GENERATED_DIR/compat-report.txt"
        echo "Start a new tmux session or run: tmux source ~/.tmux.conf"
    else
        echo "Compatibility report: $GENERATED_DIR/compat-report.txt"
        echo "Setup complete! Start a new tmux session or run: tmux source ~/.tmux.conf"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    setup_main "$@"
fi
