import { test, expect, mock } from 'claude-code/testing'
import type { On } from 'claude-code'

// A fake %TEMP%\agent-runs holding one run; the tests choose its files and which PIDs are alive.
const BASE = 'C:\\T\\agent-runs'
const NOW = new Date(2026, 9, 12, 12, 0, 0).getTime()
const BAND = { component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false } } as const

function fakeWorld(on: On, run: string, files: Map<string, string>, alive: () => number[]) {
  const dir = `${BASE}\\${run}`
  const toasts: string[] = []
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { TEMP: 'C:\\T' })
  on('session.start', ($$, e) => ({ cwd: e.cwd }))
  on('fs.list', ($$, e, next) =>
    e.path === BASE
      ? { value: [{ name: run, kind: 'dir', size: 0, mtimeMs: 0, isLink: false }] }
      : next(e),
  )
  on('fs.exists', ($$, e, next) => (e.path.startsWith(dir) ? { value: files.has(e.path) } : next(e)))
  on('fs.read', ($$, e, next) => {
    if (!e.path.startsWith(dir)) return next(e)
    const text = files.get(e.path)

    return text === undefined ? { deny: 'ENOENT' } : { value: text }
  })
  on('fs.stat', ($$, e, next) =>
    e.path.startsWith(dir)
      ? files.has(e.path)
        ? { value: { kind: 'file', size: 1, mtimeMs: NOW - 5000, isLink: false } }
        : { deny: 'ENOENT' }
      : next(e),
  )
  on('process.run', ($$, e, next) =>
    e.argv[0] === 'tasklist'
      ? {
          value: {
            exitCode: 0,
            stdout: alive().map(p => `"powershell.exe","${p}","Console","1","50,000 K"\r\n`).join(''),
            stderr: '',
            isStdoutTruncated: false,
            isStderrTruncated: false,
          },
        }
      : next(e),
  )
  on('ui.toast', ($$, e) => {
    toasts.push(e.text)

    return { value: undefined }
  })

  return { dir, toasts, clock }
}

test('shows a live run, then toasts and shows done when done.json appears', async ($, on) => {
  const run = 'demo-20261012-115900'
  const files = new Map<string, string>()
  const w = fakeWorld(on, run, files, () => [4242])
  files.set(`${w.dir}\\worker.pid`, '4242\r\n')
  files.set(`${w.dir}\\out.log`, 'x')

  await $.session.start({ cwd: 'C:/T' })
  await w.clock.advance(3100)
  const ui = await $.ui.mount({ plugin: 'agent-runs-band', surface: 'terminal', ...BAND })
  expect(await ui.find({ type: 'Text', text: /demo/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /running/ })).toBeDefined()

  files.set(`${w.dir}\\done.json`, '\uFEFF{"status":"DONE","turn":2,"tokens":184355}')
  await w.clock.advance(3100)
  expect(w.toasts.some(t => /demo: done/.test(t))).toBe(true)
  await ui.redraw()
  expect(await ui.find({ type: 'Text', text: /turn 2/ })).toBeDefined()
  await ui.unmount()
})

test('a run whose worker died (window closed) shows as closed, not running', async ($, on) => {
  const run = 'gone-20261012-115900'
  const files = new Map<string, string>()
  const w = fakeWorld(on, run, files, () => [1111])
  files.set(`${w.dir}\\worker.pid`, '999\r\n')
  files.set(`${w.dir}\\out.log`, 'x')

  await $.session.start({ cwd: 'C:/T' })
  await w.clock.advance(3100)
  const ui = await $.ui.mount({ plugin: 'agent-runs-band', surface: 'terminal', ...BAND })
  expect(await ui.find({ type: 'Text', text: /closed/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /running/ })).toBeUndefined()
  await ui.unmount()
})

test('a run that never started (no worker.pid) is not listed once past startup', async ($, on) => {
  const run = 'never-20261012-115500'
  const files = new Map<string, string>()
  const w = fakeWorld(on, run, files, () => [])
  on('ui.render', { component: 'AbovePrompt' }, ($$, e) => {
    const { Text } = $$.ui.resolve(e)

    return <Text>base-band</Text> // what the engine draws when the mod has nothing to show
  })
  files.set(`${w.dir}\\brief.md`, 'x')

  await $.session.start({ cwd: 'C:/T' })
  await w.clock.advance(3100)
  const ui = await $.ui.mount({ plugin: 'agent-runs-band', surface: 'terminal', ...BAND })
  expect(await ui.find({ type: 'Text', text: /base-band/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /never/ })).toBeUndefined()
  await ui.unmount()
})
