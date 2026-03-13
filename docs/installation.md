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

### 1. Clone the Repository

Clone this repository directly into your OpenCode configuration directory:

```bash
# Ensure the directory exists
mkdir -p ~/.config/opencode

# Clone the repository
git clone https://github.com/iyioon/aid.git ~/.config/opencode
```

> **Note**: If you already have an `opencode` configuration, you may need to back it up or merge these files.

### 2. Create the symlink

Create a symlink to make the `aid` command available globally:

```bash
mkdir -p ~/.local/bin
ln -sf ~/.config/opencode/scripts/aid.sh ~/.local/bin/aid
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
rm -rf ~/.config/opencode/skills
rm -rf ~/.config/opencode/dispatch
rm -rf ~/.config/opencode/worktrees
rm -rf ~/.config/opencode/docs
```
