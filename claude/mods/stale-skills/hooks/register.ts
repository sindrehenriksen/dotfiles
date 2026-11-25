import type { Register } from 'claude-code'
import { type Disk, type Filtered, filter } from './sections'

// After a compaction the engine re-attaches the text of every skill invoked
// before it, as it was when loaded. This leaves out the ones that are gone
// from disk, and points at the file for the ones that changed.
export const register: Register = (on, options) => {
  let hasSaidUnparsed = false

  on('prompt.attachment', { type: 'invoked_skills' }, async ($, e, next) => {
    let result: Filtered = { status: 'same' }

    try {
      const look = async (dir: string): Promise<Disk> => {
        const isDirThere = await $.fs.exists(dir).catch(() => undefined)

        if (isDirThere !== true) return { isDirThere }

        const path = `${dir}/SKILL.md`
        const isFileThere = await $.fs.exists(path).catch(() => undefined)

        if (isFileThere === false) return { isDirThere, skillText: null }
        if (isFileThere === undefined) return { isDirThere }

        return { isDirThere, skillText: await $.fs.read(path).catch(() => undefined) }
      }

      result = await filter(String(e.text), look, { isChangedReplaced: options.isChangedReplaced !== false })

      if (result.status === 'unparsed' && !hasSaidUnparsed) {
        hasSaidUnparsed = true
        $.ui.log('stale-skills: the restored skills text is not in the form this mod reads; left as it is')
      }

      if (result.status === 'rewritten') {
        $.ui.log(
          `stale-skills: left out [${result.dropped.join(', ')}], marked changed [${result.changed.join(', ')}]`,
          { to: 'debug' },
        )
      }
    } catch {
      result = { status: 'same' }
    }

    if (result.status !== 'rewritten') return next(e)
    if (result.text === null) return { text: null }

    return next({ ...e, text: result.text })
  })
}
