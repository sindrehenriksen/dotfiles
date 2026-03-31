---
name: adding-skills
description: 'Create or update user-level Copilot skills. USE FOR: new skill, add skill, create skill, update skill setup. DO NOT USE FOR: repo-specific instructions (.github/instructions/), VS Code agent modes.'
---

# Adding Skills

User-level skills are dual-maintained for Copilot and Claude Code:

- **Copilot**: `~/dotfiles/.agents/skills/<name>/SKILL.md` → symlinked to `~/.agents/skills/`
- **Claude Code**: `~/dotfiles/.claude/skills/<name>.md` → symlinked to `~/.claude/skills/`

Separate files because Copilot uses `directory/SKILL.md` convention and Claude uses flat `.md` files with different frontmatter fields (`allowed-tools` etc.).

## Creating a New Skill

1. Create **Copilot** version: `~/dotfiles/.agents/skills/<name>/SKILL.md`
2. Create **Claude Code** version: `~/dotfiles/.claude/skills/<name>.md`
3. Add symlink lines to `~/dotfiles/install_symlinks.sh` for both
4. Run `install_symlinks.sh`

## SKILL.md Format

```markdown
---
name: <name>
description: '<Brief description>. USE FOR: <trigger phrases>. DO NOT USE FOR: <exclusions>.'
---

# <Title>

<Content — keep focused and actionable>
```

## Guidelines

- Keep skills concise — they load into context on every match
- Avoid duplicating content already in root instructions (`.instructions.md` files) — reference them instead or move content out and reference the skill
- Use `USE FOR` / `DO NOT USE FOR` in the description to control when the skill triggers
