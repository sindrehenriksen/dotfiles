---
name: adding-skills
description: 'Create or update user-level skills. USE FOR: new skill, add skill, create skill, update skill setup. DO NOT USE FOR: repo-specific instructions (.github/instructions/), VS Code agent modes.'
allowed-tools: Read, Grep, Glob, Bash
---
<!-- Agents counterpart: .agents/skills/adding-skills/SKILL.md — keep in sync.
     Only difference: this file has `allowed-tools` frontmatter. -->

# Adding Skills

User-level skills are dual-maintained in two directories:

- **Agents** (generic — Copilot CLI, Codex CLI, etc.): `~/dotfiles/.agents/skills/<name>/SKILL.md` → symlinked to `~/.agents/skills/`
- **Claude Code**: `~/dotfiles/.claude/skills/<name>/SKILL.md` → symlinked to `~/.claude/skills/`

Both use the same `<name>/SKILL.md` directory convention. The only difference is that Claude Code versions include `allowed-tools` frontmatter.

## Creating a New Skill

1. Create **agents** version: `~/dotfiles/.agents/skills/<name>/SKILL.md`
2. Create **Claude Code** version: `~/dotfiles/.claude/skills/<name>/SKILL.md` (copy agents version, add `allowed-tools`)
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

Claude Code version adds `allowed-tools: Read, Grep, Glob, Bash` (or similar) to the frontmatter.

## Guidelines

- Keep skills concise — they load into context on every match
- Avoid duplicating content already in root instructions (`.instructions.md` files) — reference them instead or move content out and reference the skill
- Use `USE FOR` / `DO NOT USE FOR` in the description to control when the skill triggers
