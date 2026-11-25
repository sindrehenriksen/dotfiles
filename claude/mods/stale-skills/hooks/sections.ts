// The text Claude Code re-attaches after a compaction for the skills invoked
// before it (attachment type `invoked_skills`), taken apart and put back
// together. No engine in it and only syntax node strips, so node tests it
// directly (claude/tests/stale-skills-test.mjs).
//
// The text is prose, not a contract: an introduction, then per skill
//
//   ### Skill: <name>
//   Path: <source>:<name>
//
//   Base directory for this skill: <absolute path>
//
//   <body, cut at about 5,000 tokens>
//
// joined by SEPARATOR, and last an optional note naming skills to reload.
// Anything that does not read that way is left alone (`parse` answers
// undefined).

const SEPARATOR = '\n\n---\n\n'
const TITLE = '### Skill: '
const HEADER = /^### Skill: ([^\n]+)\nPath: ([^\n]*)\n\n/
const BASE = 'Base directory for this skill: '
const CUT = '\n\n[... skill content truncated for compaction; use Read on the skill path if you need the full text]'
const RELOAD_NOTE = 'The text of these skills was cut short or left out to save room: '

export type Section = {
  raw: string
  name: string
  source: string
  /** Absent for a skill with no directory to check (one an MCP server serves). */
  dir?: string
  /** The restored body, the cut notice taken off. */
  body: string
  isCut: boolean
}

export type Blob = { head: string; sections: Section[]; trailer?: string }

/** What is at a skill's directory now. `undefined` is "could not tell"; `skillText: null` is "no SKILL.md". */
export type Disk = { isDirThere?: boolean; skillText?: string | null }

export type Verdict = 'keep' | 'drop' | 'changed'

export type Options = { isChangedReplaced: boolean }

export type Filtered =
  | { status: 'unparsed' | 'same' }
  | { status: 'rewritten'; text: string | null; dropped: string[]; changed: string[] }

const section = (raw: string): Section => {
  const [header = '', name = '', source = ''] = HEADER.exec(raw) ?? []
  const rest = raw.slice(header.length)

  if (!rest.startsWith(BASE)) return { raw, name, source, body: rest, isCut: false }

  const end = rest.indexOf('\n')
  const dir = rest.slice(BASE.length, end < 0 ? undefined : end)
  const body = end < 0 ? '' : rest.slice(end + 1)
  const isCut = body.endsWith(CUT)

  return { raw, name, source, dir, body: isCut ? body.slice(0, -CUT.length) : body, isCut }
}

/** Whether the attachment is the reload note alone, which holds no skill text. */
export const isReloadNoteOnly = (text: string) => text.startsWith(RELOAD_NOTE)

export const parse = (text: string): Blob | undefined => {
  const at = text.indexOf(`\n\n${TITLE}`)

  if (at < 0) return undefined

  const head = text.slice(0, at + 2)
  const pieces = text.slice(at + 2).split(SEPARATOR)
  const trailer = pieces.length > 1 && isReloadNoteOnly(pieces.at(-1) ?? '') ? pieces.pop() : undefined
  const raws: string[] = []

  for (const piece of pieces) {
    if (HEADER.test(piece)) raws.push(piece)
    else if (raws.length === 0) return undefined
    // A body may hold the separator itself; the piece belongs to it.
    else raws[raws.length - 1] += SEPARATOR + piece
  }

  return { head, sections: raws.map(section), trailer }
}

const bodyOf = (skillText: string) => skillText.replace(/^---\r?\n[\s\S]*?\r?\n---[ \t]*(\r?\n|$)/, '').trim()

/**
 * Whether the restored body is still what SKILL.md says, as far as the
 * restored text reaches.
 */
export const isUnchanged = (restored: Section, skillText: string) => {
  const disk = bodyOf(skillText)

  // The engine fills these in at load (arguments, the skill's directory, a
  // command's output), so the loaded text never equals the file.
  if (/\$|!`|```!/.test(disk)) return true

  const loaded = restored.body.trim()

  if (restored.isCut) return disk.startsWith(loaded)
  if (loaded === disk) return true

  // Invoked with arguments, which the engine appends under a label.
  return loaded.startsWith(disk) && /^\s*(ARGUMENTS|Skill arguments): /.test(loaded.slice(disk.length))
}

export const verdict = (restored: Section, disk: Disk, options: Options): Verdict => {
  if (restored.dir === undefined) return 'keep'
  if (disk.isDirThere === false) return 'drop'
  if (disk.isDirThere !== true || disk.skillText === undefined) return 'keep'

  // A bundled skill's directory holds its other files and no SKILL.md, so a
  // missing one means "deleted" only for a skill a settings folder holds.
  if (disk.skillText === null) return /Settings:/.test(restored.source) ? 'drop' : 'keep'

  return options.isChangedReplaced && !isUnchanged(restored, disk.skillText) ? 'changed' : 'keep'
}

export const changedLine = (restored: Section) =>
  `${TITLE}${restored.name}: changed on disk since it was loaded; re-read ${restored.dir}/SKILL.md before acting under it`

/**
 * The attachment's text with each section treated by its verdict (one per
 * section, in order), or null when no text is left to attach.
 */
export const rebuild = (blob: Blob, verdicts: readonly Verdict[]) => {
  const parts = blob.sections.flatMap((restored, i) =>
    verdicts[i] === 'drop' ? [] : [verdicts[i] === 'changed' ? changedLine(restored) : restored.raw],
  )

  if (parts.length === 0) return blob.trailer ?? null

  return blob.head + [...parts, ...(blob.trailer === undefined ? [] : [blob.trailer])].join(SEPARATOR)
}

/**
 * @param text the attachment's text
 * @param look what is on disk at a skill's directory now
 */
export const filter = async (
  text: string,
  look: (dir: string) => Promise<Disk>,
  options: Options,
): Promise<Filtered> => {
  if (isReloadNoteOnly(text)) return { status: 'same' }

  const blob = parse(text)

  if (blob === undefined) return { status: 'unparsed' }

  const verdicts: Verdict[] = []

  for (const restored of blob.sections) {
    verdicts.push(restored.dir === undefined ? 'keep' : verdict(restored, await look(restored.dir), options))
  }

  if (verdicts.every(v => v === 'keep')) return { status: 'same' }

  const named = (v: Verdict) => blob.sections.filter((_, i) => verdicts[i] === v).map(s => s.name)

  return { status: 'rewritten', text: rebuild(blob, verdicts), dropped: named('drop'), changed: named('changed') }
}
