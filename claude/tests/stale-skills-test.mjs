// Feeds restored-skills text recorded from Claude Code 2.1.332 through the
// stale-skills mod's parsing (claude/mods/stale-skills/hooks/sections.ts).
// Needs only node (22.18 or later, which strips the types); no Claude Code.
//
// fixtures/stale-skills/three-skills.txt is one attachment as a request
// carried it: scratch skills marker-kept (long, so cut, with the cut notice),
// marker-edited and marker-gone, in that order.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { filter, parse } from '../mods/stale-skills/hooks/sections.ts'

const blob = readFileSync(new URL('./fixtures/stale-skills/three-skills.txt', import.meta.url), 'utf8')
const SKILLS = '/private/tmp/skill-restore-probe/.claude/skills'
const ON = { isChangedReplaced: true }

const skillFile = body => `---\nname: x\ndescription: Scratch.\n---\n\n${body}`
const scratch = passphrase =>
  'This is a scratch test skill. It carries one fact.\n\n' +
  `The secret passphrase of this skill is ${passphrase}.\n\n` +
  'After reading this, reply with exactly the word `loaded` and nothing else. ' +
  'Do not repeat the passphrase unless a later prompt asks for it.\n'

const parsed = parse(blob)
const keptBody = parsed?.sections[0]?.body ?? ''

// The disk as it was when the blob was recorded and nothing had changed.
const untouched = {
  [`${SKILLS}/marker-kept`]: { isDirThere: true, skillText: skillFile(`${keptBody} and the rest of the file\n`) },
  [`${SKILLS}/marker-edited`]: { isDirThere: true, skillText: skillFile(scratch('HERON-COBALT-1187-FENNEL')) },
  [`${SKILLS}/marker-gone`]: { isDirThere: true, skillText: skillFile(scratch('OTTER-BASALT-4402-JUNIPER')) },
}
const disk = changes => async dir => ({ ...untouched, ...changes })[dir] ?? {}
const gone = { isDirThere: false }

let pass = 0
let fail = 0
const check = async (label, body) => {
  try {
    await body()
    pass += 1
    console.log(`ok   - ${label}`)
  } catch (error) {
    fail += 1
    console.log(`FAIL - ${label}\n${error.message}`)
  }
}

await check('parses the recorded text into its three sections', () => {
  assert.deepEqual(parsed?.sections.map(s => [s.name, s.source, s.dir, s.isCut]), [
    ['marker-kept', 'projectSettings:marker-kept', `${SKILLS}/marker-kept`, true],
    ['marker-edited', 'projectSettings:marker-edited', `${SKILLS}/marker-edited`, false],
    ['marker-gone', 'projectSettings:marker-gone', `${SKILLS}/marker-gone`, false],
  ])
  assert.equal(parsed.trailer, undefined)
})

await check('nothing changed on disk: left alone, the cut skill included', async () => {
  assert.deepEqual(await filter(blob, disk({}), ON), { status: 'same' })
})

await check('a deleted skill is cut out and the rest is byte-identical', async () => {
  const result = await filter(blob, disk({ [`${SKILLS}/marker-gone`]: gone }), ON)
  const at = blob.indexOf('\n\n---\n\n### Skill: marker-gone')

  assert.deepEqual([result.status, result.dropped, result.changed], ['rewritten', ['marker-gone'], []])
  assert.equal(result.text, blob.slice(0, at))
})

await check('a directory left without its SKILL.md counts as deleted', async () => {
  const result = await filter(blob, disk({ [`${SKILLS}/marker-gone`]: { isDirThere: true, skillText: null } }), ON)

  assert.deepEqual(result.dropped, ['marker-gone'])
})

await check('a skill no settings folder holds is kept without a SKILL.md', async () => {
  const bundled = blob.replaceAll('projectSettings:marker-gone', 'bundled:marker-gone')
  const result = await filter(bundled, disk({ [`${SKILLS}/marker-gone`]: { isDirThere: true, skillText: null } }), ON)

  assert.equal(result.status, 'same')
})

await check('an edited skill becomes one line naming its file', async () => {
  const edited = { isDirThere: true, skillText: skillFile(scratch('LYNX-AMBER-9054-SORREL')) }
  const result = await filter(blob, disk({ [`${SKILLS}/marker-edited`]: edited }), ON)
  const from = blob.indexOf('### Skill: marker-edited')
  const to = blob.indexOf('\n\n---\n\n### Skill: marker-gone')
  const line =
    '### Skill: marker-edited: changed on disk since it was loaded; ' +
    `re-read ${SKILLS}/marker-edited/SKILL.md before acting under it`

  assert.deepEqual([result.dropped, result.changed], [[], ['marker-edited']])
  assert.equal(result.text, blob.slice(0, from) + line + blob.slice(to))
})

await check('with the option off an edited skill is left alone', async () => {
  const edited = { isDirThere: true, skillText: skillFile(scratch('LYNX-AMBER-9054-SORREL')) }
  const result = await filter(blob, disk({ [`${SKILLS}/marker-edited`]: edited }), { isChangedReplaced: false })

  assert.equal(result.status, 'same')
})

await check('a cut skill is compared only as far as its text reaches', async () => {
  const early = { isDirThere: true, skillText: skillFile(keptBody.replace('ZEBRA', 'ZEBU')) }
  const late = { isDirThere: true, skillText: skillFile(`${keptBody} and a different ending\n`) }

  assert.deepEqual((await filter(blob, disk({ [`${SKILLS}/marker-kept`]: early }), ON)).changed, ['marker-kept'])
  assert.equal((await filter(blob, disk({ [`${SKILLS}/marker-kept`]: late }), ON)).status, 'same')
})

await check('a skill the engine fills in at load is never called changed', async () => {
  const filled = { isDirThere: true, skillText: skillFile('Run $ARGUMENTS in ${CLAUDE_SKILL_DIR}.\n') }

  assert.equal((await filter(blob, disk({ [`${SKILLS}/marker-edited`]: filled }), ON)).status, 'same')
})

await check('arguments appended at load are not a change', async () => {
  const withArgs = blob.replace(
    'OTTER-BASALT-4402-JUNIPER.\n\nAfter reading this, reply with exactly the word `loaded` and nothing else. ' +
      'Do not repeat the passphrase unless a later prompt asks for it.\n',
    m => `${m}\nARGUMENTS: now\n`,
  )

  assert.notEqual(withArgs, blob)
  assert.equal((await filter(withArgs, disk({}), ON)).status, 'same')
})

await check('every skill gone: nothing is left to attach', async () => {
  const result = await filter(blob, async () => gone, ON)

  assert.equal(result.text, null)
  assert.deepEqual(result.dropped, ['marker-kept', 'marker-edited', 'marker-gone'])
})

await check('the reload note at the end survives, and stands alone when no skill is left', async () => {
  const note = 'The text of these skills was cut short or left out to save room: marker-kept. Before you do more work.'
  const noted = `${blob}\n\n---\n\n${note}`
  const one = await filter(noted, disk({ [`${SKILLS}/marker-gone`]: gone }), ON)

  assert.ok(one.text.endsWith(`\n\n---\n\n${note}`))
  assert.ok(!one.text.includes('marker-gone'))
  assert.equal((await filter(noted, async () => gone, ON)).text, note)
  assert.deepEqual(await filter(note, async () => gone, ON), { status: 'same' })
})

await check('what could not be looked up is kept', async () => {
  assert.equal((await filter(blob, async () => ({}), ON)).status, 'same')
  assert.equal((await filter(blob, async () => ({ isDirThere: true }), ON)).status, 'same')
})

await check('a skill with no base directory is kept', async () => {
  const served = blob.replace(
    `Base directory for this skill: ${SKILLS}/marker-gone`,
    'This skill is served by MCP server "scratch"',
  )

  assert.equal((await filter(served, async () => gone, ON)).dropped.includes('marker-gone'), false)
})

await check('text in another form is reported unparsed, never rewritten', async () => {
  const look = async () => gone

  assert.deepEqual(await filter(blob.replaceAll('### Skill: ', '## Skill '), look, ON), { status: 'unparsed' })
  assert.deepEqual(await filter(blob.replaceAll('\nPath: ', '\nSource: '), look, ON), { status: 'unparsed' })
  assert.deepEqual(await filter('', look, ON), { status: 'unparsed' })
})

console.log(`${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
