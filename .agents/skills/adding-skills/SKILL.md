---
name: adding-skills
description: 'Create or update user-level skills. USE FOR: new skill, add skill, create skill, update skill setup. DO NOT USE FOR: repo-specific instructions (.github/instructions/), VS Code agent modes.'
allowed-tools: Read, Grep, Glob, Bash
---

# Adding Skills

Single source of truth in `~/dotfiles/.agents/skills/`. Symlinked to both `~/.agents/skills/` and `~/.claude/skills/`.

Claude Code-specific frontmatter like `allowed-tools` is included directly — other agents ignore unknown fields.

## Creating a New Skill

1. Create skill: `~/dotfiles/.agents/skills/<name>/SKILL.md`
2. Add `allowed-tools` frontmatter if the skill should restrict Claude Code's tool access
3. Add symlink lines to `~/dotfiles/install_symlinks.sh` (both `~/.agents/skills/` and `~/.claude/skills/`)
4. Run `install_symlinks.sh`

## SKILL.md Format

```markdown
---
name: <name>
description: '<Brief description>. USE FOR: <trigger phrases>. DO NOT USE FOR: <exclusions>.'
allowed-tools: Read, Grep, Glob, Bash
---

# <Title>

<Content — keep focused and actionable>
```

## Guidelines

- Keep skills concise — they load into context on every match
- Avoid duplicating content already in root instructions (`.instructions.md` files) — reference them instead or move content out and reference the skill
- Use `USE FOR` / `DO NOT USE FOR` in the description to control when the skill triggers
