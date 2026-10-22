import type { Register } from 'claude-code'

// Runs live in %TEMP%\agent-runs\<name>-<yyyyMMdd>-<HHmmss>\ (written by the
// orchestrating-coding-agents skill's scripts): done.json appears when a turn ends.
type Run = {
  name: string
  backend: 'agy' | 'opencode'
  status: string
  turn: number
  tokens: number
  startMs: number
  endMs: number
}

const POLL_MS = 3000
const SCAN_WINDOW_MS = 3 * 60 * 60 * 1000
const SHOW_DONE_MS = 10 * 60 * 1000
const STALE_MS = 20 * 60 * 1000
const STARTUP_MS = 2 * 60 * 1000
const MAX_LINES = 4

const NAME = /^(.*)-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/

const kilo = (n: number) => (n >= 1000 ? `${Math.round(n / 1000)}k` : `${n}`)
const span = (ms: number) => {
  const s = Math.max(0, Math.round(ms / 1000))
  return s >= 60 ? `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s` : `${s}s`
}

let visible: Run[] = []
let hiddenCount = 0
let nowMs = 0
let isPrimed = false
let isTicking = false
const seen = new Map<string, string>()
let sessionCwd = ''

// Windows paths are case-insensitive and use backslashes; compare everything with forward slashes.
const isWin = (p: string) => /^[A-Za-z]:/.test(p) || p.includes('\\')
const norm = (p: string) => {
  const n = p.replace(/\\/g, '/').replace(/\/+$/, '')

  return isWin(p) ? n.toLowerCase() : n
}

// A run belongs to this session when its target dir is the session's cwd or nested with it (either way).
function sameProject(target: string, cwd: string): boolean {
  const t = norm(target)
  const c = norm(cwd)
  if (!t || !c) return false

  return t === c || t.startsWith(`${c}/`) || c.startsWith(`${t}/`)
}

// PIDs of the PowerShell processes that run workers; null when tasklist/ps can't be read
async function livePids($: any, win: boolean): Promise<Set<number> | null> {
  try {
    if (!win) {
      const r = await $.process.run(['ps', '-A', '-o', 'pid=,comm='])
      const pids = new Set<number>()
      for (const line of String(r.stdout).split('
')) {
        const m = /^\s*(\d+)\s+.*pwsh/.exec(line)
        if (m) pids.add(+m[1])
      }

      return pids
    }
    const r = await $.process.run(['tasklist', '/FI', 'IMAGENAME eq powershell.exe', '/FO', 'CSV', '/NH'])
    const pids = new Set<number>()
    for (const line of String(r.stdout).split('\n')) {
      const m = /^"[^"]*","(\d+)"/.exec(line.trim())
      if (m) pids.add(+m[1])
    }
    return pids
  } catch {
    return null
  }
}

async function scan($: any): Promise<Run[]> {
  const tmp = String((await $.env.get('TEMP')) || (await $.env.get('XDG_RUNTIME_DIR')) || (await $.env.get('TMPDIR')) || `${await $.env.get('HOME')}/.cache`).replace(/[/\\]+$/, '')
  const win = isWin(tmp)
  const sep = win ? '\\' : '/'
  const base = `${tmp}${sep}agent-runs`
  nowMs = await $.clock.now()
  let entries: { name: string; kind: string }[]
  try {
    entries = await $.fs.list(base)
  } catch {
    return []
  }
  const runs: Run[] = []
  let live: Set<number> | null | undefined // undefined: not asked yet; null: could not tell
  for (const entry of entries) {
    const m = entry.kind === 'dir' ? NAME.exec(entry.name) : null
    if (!m) continue
    const startMs = new Date(+m[2], +m[3] - 1, +m[4], +m[5], +m[6], +m[7]).getTime()
    if (nowMs - startMs > SCAN_WINDOW_MS) continue
    const dir = `${base}${sep}${entry.name}`
    let target = ''
    try {
      target = String(await $.fs.read(`${dir}${sep}target-dir`)).trim()
    } catch {
      target = ''
    }
    if (!sameProject(target, sessionCwd)) continue // another project's run (or one we can't attribute)
    const backend = (await $.fs.exists(`${dir}${sep}inbox`)) ? 'agy' : 'opencode'
    let status = 'RUNNING'
    let turn = 0
    let tokens = 0
    let endMs = 0
    try {
      const text: string = await $.fs.read(`${dir}${sep}done.json`)
      const d = JSON.parse(text.replace(/^﻿/, ''))
      status = String(d.status)
      turn = Number(d.turn) || 0
      tokens = Number(d.tokens) || 0
      endMs = (await $.fs.stat(`${dir}${sep}done.json`)).mtimeMs
    } catch {
      // No done.json: running only if the worker process is really alive.
      // (Closing an AGY viewer window kills its worker; a run that never started has no worker.)
      let pid = 0
      try {
        pid = parseInt(await $.fs.read(`${dir}${sep}worker.pid`), 10) || 0
      } catch {
        pid = 0
      }
      if (!pid) {
        if (nowMs - startMs > STARTUP_MS) continue // never started: nothing to show
        status = 'STARTING'
      } else {
        if (live === undefined) live = await livePids($, win)
        let lastMs = startMs
        try {
          lastMs = (await $.fs.stat(`${dir}${sep}out.log`)).mtimeMs
        } catch {
          lastMs = startMs
        }
        if (live !== null && !live.has(pid)) {
          status = 'CLOSED'
          endMs = lastMs
        } else if (nowMs - lastMs > STALE_MS) {
          status = 'STALE'
        }
      }
    }
    runs.push({ name: m[1], backend, status, turn, tokens, startMs, endMs })
  }
  return runs
}

async function refresh($: any): Promise<void> {
  const runs = await scan($)
  for (const r of runs) {
    const key = `${r.name}@${r.startMs}`
    const stamp = `${r.status}:${r.turn}`
    const before = seen.get(key)
    seen.set(key, stamp)
    const isFinal = r.status !== 'RUNNING' && r.status !== 'STARTING' && r.status !== 'STALE'
    if (isPrimed && isFinal && before !== stamp) {
      const mark = r.status === 'DONE' ? 'done' : r.status.toLowerCase()
      const extra = r.tokens ? ` · ${kilo(r.tokens)} tokens` : ''
      $.ui.toast(`${r.backend} ${r.name}: ${mark}${extra}`, { timeoutMs: 8000 })
    }
  }
  isPrimed = true
  const active = runs.filter(r => r.status === 'RUNNING' || r.status === 'STARTING')
  const recent = runs.filter(
    r => r.status !== 'RUNNING' && r.status !== 'STARTING' && r.status !== 'STALE' && nowMs - r.endMs < SHOW_DONE_MS,
  )
  active.sort((a, b) => b.startMs - a.startMs)
  recent.sort((a, b) => b.endMs - a.endMs)
  const all = [...active, ...recent]
  visible = all.slice(0, MAX_LINES)
  hiddenCount = all.length - visible.length
  $.ui.invalidate('ui.render')
}


export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    sessionCwd = String(e.cwd ?? '')
    if (!isTicking) {
      isTicking = true
      void refresh($)
      $.clock.every(POLL_MS, () => refresh($))
    }

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || visible.length === 0) return next(e)

    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        {visible.map(r => {
          const running = r.status === 'RUNNING' || r.status === 'STARTING'
          const icon = running ? '●' : r.status === 'DONE' ? '✓' : '⚠'
          const color = running ? 'suggestion' : r.status === 'DONE' ? 'success' : r.status === 'CLOSED' ? 'warning' : 'error'
          const detail = running
            ? `running ${span(nowMs - r.startMs)}`
            : `${r.status.toLowerCase()}${r.turn ? ` · turn ${r.turn}` : ''}${r.tokens ? ` · ${kilo(r.tokens)} tok` : ''}`
          return (
            <Text color={color}>
              {icon} {r.backend} <Text bold>{r.name}</Text> <Text dimColor>{detail}</Text>
            </Text>
          )
        })}
        {hiddenCount > 0 && <Text dimColor>  +{hiddenCount} more</Text>}
      </Box>
    )
  })
}
