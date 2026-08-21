# dotfiles

Personal dotfiles + multi-host bootstrap. One repo to set up a fresh local machine *or* a remote Linux/CHPC server: shell (bash + zsh + starship), editors (vim + Neovim with LSP), tmux, git, SSH, and AI CLIs (Claude, Codex) — with version-adaptive config rendering and a follow-the-terminal light/dark theme system.

## Quickstart

### Fresh machine (local)

```bash
git clone <this-repo> ~/.dotfiles
cd ~/.dotfiles
./install.sh               # idempotent — re-run auto-updates outdated CLI tools
./install.sh --no-update   # keep already-installed tools as-is (offline / fast path)
./install.sh --force       # reinstall CLI tools even if present and current
./install.sh --dry-run     # show planned steps without changing files
```

Re-running `install.sh` keeps every managed CLI tool current: each present tool's version is compared against the latest release (GitHub releases, `npm view` version signal for `claude`/`codex`, the Node LTS index, or `brew outdated` on macOS) and upgraded only when outdated — Claude Code updates via its native `claude update`, codex reinstalls from npm. A failed version lookup (offline, rate-limited) leaves the installed tool untouched. Use `--no-update` (or `NO_UPDATE=1`) to skip the checks entirely.

On macOS, `install.sh` uses Homebrew for managed CLI tools when `brew` is already installed. It does not install Homebrew automatically.

### Remote server

```bash
./deploy.sh              # interactive: pick host, auth method, steps
./deploy.sh --yes        # non-interactive (accept defaults)
./deploy.sh --force-copy # re-copy files even if remote matches
```

`deploy.sh` authenticates once via SSH ControlMaster, then multiplexes all subsequent commands. Supports password, SSH key, custom key path, 2FA/DUO, and SSH config aliases. Use `--help` for full usage.

GitHub CLI auth is recreated on the remote from the local `gh auth token` before cloning, bootstrapping `gh` to `~/.local/bin` on Linux remotes when needed. If the token is already stored in plaintext locally, `deploy.sh` can fall back to copying `hosts.yml`. Claude and Codex copy only known auth files (`~/.claude/.credentials.json`, `~/.codex/auth.json`); keychain-backed Claude auth is reported as non-transferable and must be set up on the remote with `claude auth login` or `claude setup-token`. Google Drive auth is deployed after setup by securely merging only the validated `[gdrive]` section from the local rclone config, preserving unrelated remotes.

### Uninstall

```bash
./uninstall.sh           # interactive per-component removal
./uninstall.sh --yes     # remove everything non-interactively
```

Restores `.bak` backups of any files that were replaced.

### Validation

```bash
bash -n install.sh deploy.sh uninstall.sh scripts/install_claude_plugins.sh lib/common.sh .githooks/pre-commit scripts/test_regressions.sh shell/bashrc_exports shell/bashrc_aliases
shellcheck --severity=warning --exclude=SC1091 install.sh deploy.sh uninstall.sh scripts/install_claude_plugins.sh lib/common.sh .githooks/pre-commit scripts/test_regressions.sh shell/bashrc_exports shell/bashrc_aliases
bash scripts/test_regressions.sh
HOME="$(mktemp -d)" ./install.sh --dry-run
```

---

## What Gets Installed

### Config Files

| Repo file | Installed to | Method |
|-----------|-------------|--------|
| `shell/bashrc_exports` | `~/.bashrc_exports` | symlink |
| `shell/bashrc_aliases` | `~/.bashrc_aliases` | symlink |
| `shell/zshrc` | `~/.zshrc` | symlink (when absent) |
| `shell/zshrc_exports` | `~/.zshrc_exports` | symlink |
| `shell/zshrc_aliases` | `~/.zshrc_aliases` | symlink |
| `shell/inputrc` | `~/.inputrc` | symlink |
| `shell/dircolors` | `~/.dircolors` | symlink |
| `shell/dircolors.light` | `~/.dircolors.light` | symlink |
| `shell/starship.toml` | `~/.config/starship.toml` | symlink |
| `shell/starship-light.toml` | `~/.config/starship-light.toml` | symlink |
| `editor/vimrc` | `~/.vimrc` | symlink |
| `editor/nvim/` | `~/.config/nvim/` | symlink |
| `tmux/tmux.conf` | `~/.tmux.conf` | symlink |
| _generated_ `tmux-theme.conf` | `~/.tmux-theme.conf` | symlink (rendered by `install.sh`) |
| `git/gitconfig` | `~/.gitconfig` | symlink |
| `ai/claude_settings.json` | `~/.claude/settings.json` | copy |
| `ai/codex_config.toml` | `~/.codex/config.toml` | copy |
| `scripts/detect-theme.sh` | `~/.local/bin/detect-theme` | symlink |
| `scripts/chpc-allocs.py` | `~/.local/bin/chpc-allocs` | symlink |

Both `shell/bashrc_exports` and `shell/bashrc_aliases` are sourced from `~/.bashrc` (lines appended by `install.sh` if not already present). Zsh wiring is parallel: `~/.zshrc_exports` and `~/.zshrc_aliases`.

### CLI Tools

| Tool | Purpose |
|------|---------|
| `gh` | GitHub CLI |
| `glow` | Terminal markdown renderer |
| `nvim` | Neovim editor |
| `node` | Node.js LTS (for npx, Neovim plugins) |
| `uv` / `uvx` | Python package manager |
| `fzf` | Fuzzy finder (Ctrl+T, Ctrl+R, Alt+C) |
| `rg` | ripgrep — fast file content search |
| `fd` | find replacement |
| `bat` | cat replacement with syntax highlighting |
| `delta` | Git diff pager (side-by-side, syntax-highlighted) |
| `zoxide` | Smart `cd` replacement (`z` command) |
| `lazygit` | Git TUI |
| `btop` | System monitor |
| `jq` | JSON processor |
| `rclone` | Google Drive file transfer (`gdrive:` remote) |
| `starship` | Cross-shell prompt |
| `atuin` | Shell history sync and search |
| `claude` | Claude Code CLI |
| `codex` | Codex CLI |
| `code` tunnel | VS Code remote tunnel CLI (Remote-SSH bridge) |

All tools install to `~/.local/bin/`. Installed via GitHub releases (no root required). On Linux, Neovim uses the official release tarball under `~/.local/opt/nvim` with a `~/.local/bin/nvim` symlink; old x86_64 glibc systems use Neovim's legacy glibc 2.17 release tarball.

---

## Repository Structure

```
.dotfiles/
├── install.sh                  # Local install: tools + symlinks + render compat configs
├── deploy.sh                   # Remote SSH bootstrap
├── uninstall.sh                # Clean removal + backup restore
├── lib/
│   ├── common.sh               # Shared helpers (run_step, retry, backup_and_link, ...)
│   └── vscode-tunnel.sh        # `vscode-tunnel` shell helper sourced by aliases
├── scripts/
│   ├── install_claude_plugins.sh   # MCP servers for Claude Code
│   ├── detect-theme.sh             # Terminal background detector
│   ├── chpc-allocs.py              # CHPC SLURM allocations CLI
│   └── test_regressions.sh         # Regression test suite
├── shell/
│   ├── bashrc_exports          # bash environment, prompt, history
│   ├── bashrc_aliases          # bash aliases (git, nav, safety, modern tools)
│   ├── zshrc                   # zsh entrypoint (installed when ~/.zshrc absent)
│   ├── zshrc_exports           # zsh environment (parallel to bashrc_exports)
│   ├── zshrc_aliases           # zsh aliases (parallel to bashrc_aliases)
│   ├── inputrc                 # Readline (case-insensitive, history search)
│   ├── dircolors               # LS color scheme (dark terminals)
│   ├── dircolors.light         # LS color scheme (light terminals)
│   ├── starship.toml           # Starship prompt (dark)
│   └── starship-light.toml     # Starship prompt (light)
├── editor/
│   ├── vimrc                   # Vim config (plugin-free)
│   └── nvim/                   # Neovim config (lazy.nvim, ~20 plugins, LSP)
│       ├── init.lua
│       └── lua/{config,plugins}/
├── tmux/
│   └── tmux.conf               # tmux config (prefix: Ctrl-a)
├── git/
│   └── gitconfig               # delta pager, rebase, aliases
├── ai/
│   ├── claude_settings.json    # Claude Code settings
│   ├── codex_config.toml       # Codex CLI settings
│   └── skills/                 # Claude Code skills (HPC, CUDA, LaTeX, …) — symlinked into ~/.claude/skills/
├── .githooks/
│   └── pre-commit              # bash -n + shellcheck + secret scan on staged files
├── .gitignore
├── CLAUDE.md                   # AI agent guidance
├── AGENTS.md                   # Contributor guidelines
└── docs/                       # Reference documentation
    ├── shell.md
    ├── vim.md
    ├── neovim.md
    ├── tmux.md
    ├── git.md
    ├── misc-configs.md
    ├── ai-tools.md
    ├── ai-skills.md
    └── chpc-allocs.md
```

---

## Key Concepts

### Version-Adaptive Compatibility

`install.sh` detects tool versions and generates compatibility configs in `~/.dotfiles-generated/`:

| Generated file | Source config | Adapts for |
|---------------|-------------|------------|
| `tmux.compat.conf` | `tmux/tmux.conf` | Terminal type, true color, passthrough |
| `tmux-theme*.conf` | (rendered) | Light/dark palette dispatcher (`*-style` vs legacy `*-bg`/`*-fg`) |
| `vimrc.compat` | `editor/vimrc` | Clipboard, listchars, Neovim features |
| `gitconfig.compat` | `git/gitconfig` | Credential helper; HTTPS rewrite on keyless hosts |
| `bashrc_compat` | `shell/bashrc_aliases`, `shell/zshrc_aliases` | Tool-specific flags by version (POSIX-clean) |

The main configs `source`/`include` these generated files. Never edit the generated files directly — edit the `render_*()` functions in `install.sh`.

### Theme System

Shell exposes `theme light|dark|auto`. It sets `DOTFILES_THEME`, propagates to tmux via `set-environment -g`, and re-sources `~/.tmux-theme.conf`. Running nvim/vim instances need `:set background=light|dark` to repaint (handled by `colorscheme.lua`'s `OptionSet` autocmd). Detection covers VS Code (local + Remote-SSH), Apple Terminal, OSC 11 (outside tmux), and `COLORFGBG`; falls back to dark. See [docs/shell.md](docs/shell.md#theme-detection--override).

### Backup & Restore

When `install.sh` replaces an existing file with a symlink, the original is saved as `<filename>.bak`. Running `uninstall.sh` removes the symlinks and restores the `.bak` files.

### Vim vs Neovim

| | Vim (`editor/vimrc`) | Neovim (`editor/nvim/`) |
|---|---|---|
| Plugins | None (intentionally) | ~20 via lazy.nvim |
| File explorer | netrw (built-in) | oil.nvim |
| Fuzzy finder | fzf (if installed) | Telescope |
| Status line | Custom `statusline` | lualine.nvim |
| LSP | None | pyright + ruff + clangd + lua_ls |
| Leader | Space | Space |

Both share the same core keybindings. See [docs/vim.md](docs/vim.md) and [docs/neovim.md](docs/neovim.md).

---

## Reference Documentation

Comprehensive lookup tables for every keybinding, alias, option, and setting:

| Document | Covers |
|----------|--------|
| [docs/shell.md](docs/shell.md) | All shell aliases, environment variables, prompt, history, fzf, tool integrations |
| [docs/vim.md](docs/vim.md) | Every vim option, keybinding, autocmd, color theme, status line |
| [docs/neovim.md](docs/neovim.md) | All plugins, their keybindings, architecture, differences from vim |
| [docs/tmux.md](docs/tmux.md) | Every tmux keybinding, option, status bar, copy mode |
| [docs/git.md](docs/git.md) | Git config, delta, behavior settings, all aliases (git + shell) |
| [docs/misc-configs.md](docs/misc-configs.md) | Readline settings, dircolors |
| [docs/ai-tools.md](docs/ai-tools.md) | Claude Code settings, Codex config, MCP servers |
| [docs/google-drive.md](docs/google-drive.md) | rclone installation, Google Drive OAuth, deploy behavior |
| [docs/ai-skills.md](docs/ai-skills.md) | Claude Code skills under `ai/skills/` (HPC, CUDA, MPI, LaTeX, paper review, …) |
| [docs/chpc-allocs.md](docs/chpc-allocs.md) | `chpc-allocs` SLURM allocations & wait predictions |
