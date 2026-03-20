---
name: adding-skills
description: 'Create or update user-level Copilot skills. USE FOR: new skill, add skill, create skill, update skill setup. DO NOT USE FOR: repo-specific instructions (.github/instructions/), VS Code agent modes.'
---

# Adding Skills

User-level skills live in `~/dotfiles/.agents/skills/` and are symlinked to `~/.agents/skills/`.

## Creating a New Skill

1. Create `~/dotfiles/.agents/skills/<name>/SKILL.md`
2. Add a symlink line to `~/dotfiles/install_symlinks.sh`:
   ```sh
   ln -is ~/dotfiles/.agents/skills/<name> ~/.agents/skills/<name>
   ```
3. Run the symlink: `ln -is ~/dotfiles/.agents/skills/<name> ~/.agents/skills/<name>`

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
