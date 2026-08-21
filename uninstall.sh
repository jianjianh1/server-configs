#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATED_DIR="$HOME/.dotfiles-generated"
# shellcheck disable=SC2034  # consumed by manifest_contains_path from lib/common.sh
INSTALL_MANIFEST="$GENERATED_DIR/install-manifest.txt"
YES=false

# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"
# EXTERNAL_SKILLS_CACHE and display_path come from lib/common.sh.

# --- Helpers ---

confirm() {
    if $YES; then return 0; fi
    read -rp "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]]
}

# Remove a symlink only if it points into this repo, then restore .bak if present
restore_backup() {
    local dst="$1"
    if [ -e "${dst}.bak" ]; then
        mv "${dst}.bak" "$dst"
        echo "  Restored ${dst}.bak -> $dst"
    fi
}

unlink_config() {
    local dst="$1"
    local target="" dir_canon="" gen_canon="" ext_canon=""

    if [ -L "$dst" ]; then
        target="$(portable_realpath "$dst" 2>/dev/null || true)"
        # macOS resolves /var → /private/var (and similar /tmp → /private/tmp)
        # via portable_realpath, but $DIR / $GENERATED_DIR are kept in their
        # logical (pre-resolve) form. Match against both so the comparison
        # works whether or not the path crossed a symlinked prefix.
        dir_canon="$(portable_realpath "$DIR" 2>/dev/null || printf '%s' "$DIR")"
        gen_canon="$(portable_realpath "$GENERATED_DIR" 2>/dev/null || printf '%s' "$GENERATED_DIR")"
        ext_canon="$(portable_realpath "$EXTERNAL_SKILLS_CACHE" 2>/dev/null || printf '%s' "$EXTERNAL_SKILLS_CACHE")"
        case "$target" in
            "$DIR"|"$DIR"/*|"$GENERATED_DIR"|"$GENERATED_DIR"/*|\
            "$EXTERNAL_SKILLS_CACHE"|"$EXTERNAL_SKILLS_CACHE"/*|\
            "$dir_canon"|"$dir_canon"/*|"$gen_canon"|"$gen_canon"/*|\
            "$ext_canon"|"$ext_canon"/*)
                rm -f "$dst"
                echo "  Removed $dst"
                restore_backup "$dst"
                ;;
            *)
                echo "  Skipped $dst (not managed by this repo)"
                ;;
        esac
        return
    fi

    if [ -e "$dst" ]; then
        echo "  Skipped $dst (not a repo-managed symlink)"
    else
        echo "  Skipped $dst (not present)"
    fi
}

remove_path() {
    local path="$1" label="${2:-}"
    label="${label:-$(display_path "$path")}"
    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -rf "$path"
        echo "  Removed $label"
    fi
}

remove_tracked_path() {
    local path="$1" label="${2:-}"
    label="${label:-$(display_path "$path")}"

    if ! manifest_contains_path "$path"; then
        if [ -e "$path" ] || [ -L "$path" ]; then
            echo "  Skipped $label (not tracked by install.sh)"
        fi
        return 0
    fi

    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -rf "$path"
        echo "  Removed $label"
    fi
}

remove_bin() {
    local bin="$1"
    if manifest_contains_path "$HOME/.local/bin/$bin"; then
        if [ -e "$HOME/.local/bin/$bin" ]; then
            rm "$HOME/.local/bin/$bin"
            echo "  Removed ~/.local/bin/$bin"
        fi
    elif [ -e "$HOME/.local/bin/$bin" ]; then
        echo "  Skipped ~/.local/bin/$bin (not tracked by install.sh)"
    fi

    if manifest_contains_path "/usr/local/bin/$bin"; then
        if [ ! -e "/usr/local/bin/$bin" ]; then
            return 0
        fi
        if is_macos; then
            echo "  Skipped /usr/local/bin/$bin (managed by system package manager on macOS)"
            return 0
        fi
        if [ -w /usr/local/bin ] || { command -v sudo &>/dev/null && sudo -n true 2>/dev/null; }; then
            if [ -w /usr/local/bin ]; then
                rm "/usr/local/bin/$bin"
            else
                sudo rm "/usr/local/bin/$bin"
            fi
            echo "  Removed /usr/local/bin/$bin"
        else
            echo "  Found /usr/local/bin/$bin but need sudo to remove"
        fi
    elif [ -e "/usr/local/bin/$bin" ]; then
        echo "  Skipped /usr/local/bin/$bin (not tracked by install.sh)"
    fi
}

# --- Uninstall steps ---

# Remove the per-skill symlinks created by install.sh::link_claude_skills.
# Walks ai/skills/ so we only touch skills this repo owns; user-added skills
# under ~/.claude/skills/<other-name> are left alone. unlink_config checks
# that each symlink's target resolves into $DIR before removing.
unlink_claude_skills() {
    local skills_src="$DIR/ai/skills"
    [ -d "$skills_src" ] || return 0
    local skill_dir name
    for skill_dir in "$skills_src"/*/; do
        [ -d "$skill_dir" ] || continue
        name="$(basename "$skill_dir")"
        unlink_config "$HOME/.claude/skills/$name"
    done
    remove_dir_if_empty "$HOME/.claude/skills"
}

# Sweep ~/.claude/skills/* for symlinks into the upstream-skills cache and
# remove them via unlink_config (which already gates on $EXTERNAL_SKILLS_CACHE
# being a recognized managed root). Decoupled from
# scripts/install_claude_skills.sh's curated arrays so additions/removals there
# don't break uninstall. User-added skills and unrelated symlinks survive.
unlink_external_claude_skills() {
    local skills_dst="$HOME/.claude/skills"
    [ -d "$skills_dst" ] || return 0
    local link
    for link in "$skills_dst"/*; do
        [ -L "$link" ] || continue
        unlink_config "$link"
    done
    remove_dir_if_empty "$skills_dst"
}

# Remove the upstream-skills clone cache. Separate from the symlink
# cleanup above because the cache may also be used by other tools the
# user wires up, and because it's larger / slower to recreate.
remove_external_skills_cache() {
    echo "Removing upstream-skill clone cache..."
    if [ -d "$EXTERNAL_SKILLS_CACHE" ]; then
        rm -rf "$EXTERNAL_SKILLS_CACHE"
        echo "  Removed $EXTERNAL_SKILLS_CACHE"
    fi
}

remove_symlinks() {
    echo "Removing config symlinks..."
    unlink_config "$HOME/CLAUDE.md"
    unlink_config "$HOME/.vimrc"
    unlink_config "$HOME/.tmux.conf"
    unlink_config "$HOME/.tmux-theme.conf"
    unlink_config "$HOME/.gitconfig"
    unlink_config "$HOME/.inputrc"
    unlink_config "$HOME/.dircolors"
    unlink_config "$HOME/.dircolors.light"
    unlink_config "$HOME/.config/nvim"
    unlink_config "$HOME/.config/starship.toml"
    unlink_config "$HOME/.config/starship-light.toml"
    unlink_config "$HOME/.config/tmux/tmux.conf"
    unlink_config "$HOME/.bashrc_exports"
    unlink_config "$HOME/.bashrc_aliases"
    unlink_config "$HOME/.zshrc_exports"
    unlink_config "$HOME/.zshrc_aliases"
    unlink_claude_skills
    unlink_external_claude_skills
    # Only remove ~/.zshrc when it's our symlink. A pre-existing user
    # ~/.zshrc with our source lines appended is handled by remove_bashrc_lines.
    unlink_config "$HOME/.zshrc"
}

remove_bashrc_lines() {
    echo "Removing shell init lines..."
    clean_line_from_file "$HOME/.bashrc" '^source ~/.bashrc_exports$'
    clean_line_from_file "$HOME/.bashrc" '^source ~/.bashrc_aliases$'
    clean_line_from_file "$HOME/.bashrc" '^\[ -f ~/.env_keys \] && . ~/.env_keys$'
    clean_line_from_file "$HOME/.profile" '^\[ -f ~/.env_keys \] && . ~/.env_keys$'
    clean_line_from_file "$HOME/.zshrc" '^source ~/.zshrc_exports$'
    clean_line_from_file "$HOME/.zshrc" '^source ~/.zshrc_aliases$'
    clean_line_from_file "$HOME/.zshrc" '^\[ -f ~/.env_keys \] && . ~/.env_keys$'
}

remove_git_hooks_config() {
    # install.sh wires core.hooksPath to .githooks; reset it so the repo falls
    # back to the default hooks path if the user later deletes .githooks.
    if git -C "$DIR" config --get core.hooksPath >/dev/null 2>&1; then
        echo "Resetting git config..."
        git -C "$DIR" config --unset core.hooksPath 2>/dev/null || true
        echo "  Unset core.hooksPath in $(display_path "$DIR")"
    fi
}

remove_tools() {
    echo "Removing CLI tools..."
    for bin in gh glow fzf rg fd bat delta zoxide lazygit btop jq rclone uv uvx starship atuin chpc-allocs detect-theme; do
        remove_bin "$bin"
    done
}

remove_claude() {
    echo "Removing Claude Code..."
    remove_bin claude
    remove_tracked_path "$HOME/.claude/settings.json"
    remove_dir_if_empty "$HOME/.claude"
}

remove_codex() {
    echo "Removing Codex CLI..."
    remove_bin codex
    remove_tracked_path "$HOME/.codex/config.toml"
    remove_dir_if_empty "$HOME/.codex"
}

remove_nvim() {
    echo "Removing Neovim..."
    remove_bin nvim
    remove_tracked_path "$HOME/.local/opt/nvim"
}

remove_node() {
    echo "Removing Node.js..."
    for bin in node npm npx corepack; do
        remove_bin "$bin"
    done
    remove_tracked_path "$HOME/.local/lib/node_modules"
    remove_tracked_path "$HOME/.local/include/node"
    remove_tracked_path "$HOME/.local/share/doc/node"
    remove_tracked_path "$HOME/.local/share/man/man1/node.1"
    remove_tracked_path "$HOME/.local/share/systemtap/tapset/node.stp"
}

remove_dirs() {
    echo "Cleaning up directories..."
    remove_path "$HOME/.dotfiles-generated"
    remove_path "$HOME/.tmux/plugins"
    remove_dir_if_empty "$HOME/.tmux"
    remove_dir_if_empty "$HOME/.config/tmux"
    remove_dir_if_empty "$HOME/.vim/undodir"
    remove_dir_if_empty "$HOME/.vim"
    remove_dir_if_empty "$HOME/.claude"
    remove_dir_if_empty "$HOME/.codex"
    remove_dir_if_empty "$HOME/.local/share/man/man1"
    remove_dir_if_empty "$HOME/.local/share/man"
    remove_dir_if_empty "$HOME/.local/share/doc"
    remove_dir_if_empty "$HOME/.local/share/systemtap/tapset"
    remove_dir_if_empty "$HOME/.local/share/systemtap"
    remove_dir_if_empty "$HOME/.local/share/claude"
    remove_dir_if_empty "$HOME/.local/share/codex"
    remove_dir_if_empty "$HOME/.local/share"
    remove_dir_if_empty "$HOME/.local/include"
    remove_dir_if_empty "$HOME/.local/opt"
    remove_dir_if_empty "$HOME/.local/lib"
    remove_dir_if_empty "$HOME/.local/bin"
    remove_dir_if_empty "$HOME/.local"
}

parse_args() {
    local arg

    for arg in "$@"; do
        case "$arg" in
            -y|--yes) YES=true ;;
            -h|--help)
                echo "Usage: uninstall.sh [--yes|-y] [--help|-h]"
                echo "  -y, --yes                 Skip confirmation prompts"
                echo "  -h, --help                Show this help"
                exit 0
                ;;
            *)
                echo "Unknown option: $arg"
                echo "Run './uninstall.sh --help' for usage."
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    echo "dotfiles uninstaller"
    echo "========================="
    echo ""

    confirm "Remove config symlinks?" && remove_symlinks
    echo ""
    confirm "Remove upstream-skill clone cache (~/.local/share/claude-skills/)?" \
        && remove_external_skills_cache
    echo ""
    confirm "Remove source lines from ~/.bashrc?" && remove_bashrc_lines
    echo ""
    confirm "Uninstall Claude Code?" && remove_claude
    echo ""
    confirm "Uninstall Codex CLI?" && remove_codex
    echo ""
    confirm "Remove Neovim?" && remove_nvim
    echo ""
    confirm "Remove Node.js?" && remove_node
    echo ""
    confirm "Remove CLI tools from ~/.local/bin?" && remove_tools
    echo ""
    confirm "Clean up empty directories?" && remove_dirs
    echo ""
    remove_git_hooks_config

    echo ""
    echo "Uninstall complete. Open a new shell to pick up changes."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
