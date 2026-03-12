# Installation

## Prerequisites

Before installing aid, ensure you have:

1. **Git** (with worktree support - version 2.5+)
   ```bash
   git --version
   ```

2. **GitHub CLI** (for accessing GitHub issues)
   ```bash
   # Install
   brew install gh
   
   # Authenticate
   gh auth login
   ```

3. **OpenCode**
   ```bash
   curl -fsSL https://opencode.ai/install | bash
   ```

4. **jq** (JSON processor)
   ```bash
   brew install jq
   ```

## Installation Steps

### 1. Files are already in place

If you're reading this, the installation has already created:
- `~/.config/opencode/scripts/ai-dispatch.sh`
- `~/.config/opencode/agents/dispatch.md`
- `~/.config/opencode/commands/*.md`

### 2. Create the symlink

The symlink to `~/.local/bin/aid` should already be created. Verify with:

```bash
which aid
```

If not found, create it manually:

```bash
mkdir -p ~/.local/bin
ln -sf ~/.config/opencode/scripts/ai-dispatch.sh ~/.local/bin/aid
```

### 3. Add ~/.local/bin to PATH

If `~/.local/bin` is not in your PATH, add it to your shell config:

**For Zsh (~/.zshrc):**
```bash
export PATH="$HOME/.local/bin:$PATH"
```

**For Bash (~/.bashrc):**
```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then reload your shell:
```bash
source ~/.zshrc  # or ~/.bashrc
```

### 4. Verify installation

```bash
aid help
```

You should see the help message with available commands.

## Upgrading

To upgrade, simply pull the latest changes:

```bash
cd ~/.config/opencode
git pull
```

## Uninstalling

```bash
# Remove the symlink
rm ~/.local/bin/aid

# Optionally remove all files
rm -rf ~/.config/opencode/scripts
rm -rf ~/.config/opencode/agents
rm -rf ~/.config/opencode/commands
rm -rf ~/.config/opencode/dispatch
rm -rf ~/.config/opencode/worktrees
rm -rf ~/.config/opencode/docs
```
