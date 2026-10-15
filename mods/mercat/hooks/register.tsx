import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { MercatEdited, MercatShown } from '../types'
import { parseAnsi } from './ansi'
import type { Line } from './ansi'
import { mermaidFences, split } from './fences'
import {
  basename,
  clampWidth,
  clipNoteOf,
  diagramArgv,
  diagramInput,
  diagramOf,
  documentArgv,
  editedIn,
  isDoc,
  Lru,
  MISSING_HINT,
  newestFirst,
  paneTitle,
  printable,
  relativeTo,
  resolvePath,
  transcriptWidth,
} from './mercat'

const PANE = 'mercat'
const RUNNING_MAX = 3

const edited = atom({ plugin: 'mercat', key: 'edited' } as const, [] as MercatEdited)
const shown = atom({ plugin: 'mercat', key: 'shown' } as const, null as MercatShown)

type Doc = { lines: Line[] } | { error: string }

type Diagram = { art: string; note?: string }

const diagrams = new Lru<Diagram | null>(200)
const everDrawn = new Lru<true>(5_000)
const docs = new Lru<Doc>(20)
const docGen = new Map<string, number>()
const inFlight = new Set<string>()
const queue: (() => Promise<void>)[] = []
let running = 0
let isMercatMissing = false

function schedule(key: string, job: () => Promise<void>): void {
  if (inFlight.has(key)) return
  inFlight.add(key)
  queue.push(() => job().finally(() => inFlight.delete(key)))
  pump()
}

function pump(): void {
  while (running < RUNNING_MAX && queue.length > 0) {
    const job = queue.shift()!
    running++
    void job().finally(() => {
      running--
      pump()
    })
  }
}

const docKey = (width: number, path: string) => `f${width}:${docGen.get(path) ?? 0}\n${path}`

function forgetDoc(path: string): void {
  docGen.set(path, (docGen.get(path) ?? 0) + 1)
  docs.dropWhere(isDocKeyOf(path))
}
const isDocKeyOf = (path: string) => (key: string) => key.endsWith(`\n${path}`)

async function isAbsent($: EngineInterface): Promise<boolean> {
  try {
    await $.process.run(['mercat', '--version'], { timeoutMs: 3_000 })
    return false
  } catch {
    if (!isMercatMissing) $.ui.toast(MISSING_HINT)
    isMercatMissing = true
    return true
  }
}

async function drawDiagram($: EngineInterface, key: string, source: string, width: number): Promise<void> {
  try {
    const run = await $.process.run(diagramArgv(width), { stdin: diagramInput(source), timeoutMs: 10_000 })
    const art = diagramOf(run)
    const note = clipNoteOf(run.stderr)
    diagrams.set(key, art === undefined ? null : note === undefined ? { art } : { art, note })
    if (art !== undefined && !everDrawn.has(key)) {
      everDrawn.set(key, true)
      $.ui.invalidate('ui.render')
    }
  } catch {
    diagrams.set(key, null)
    await isAbsent($)
  }
}

async function drawDoc($: EngineInterface, key: string, path: string, width: number): Promise<void> {
  try {
    const run = await $.process.run(documentArgv(width, path), { timeoutMs: 15_000 })
    const error = run.stderr.trim() || `mercat exited with ${run.exitCode}`
    docs.set(key, run.exitCode === 0 ? { lines: parseAnsi(run.stdout) } : { error })
  } catch (error) {
    docs.set(key, { error: (await isAbsent($)) ? MISSING_HINT : String(error) })
  }
  $.ui.invalidate('ui.render')
}

async function openPane($: EngineInterface, title: string): Promise<void> {
  await $.ui.open({ id: PANE, title, focus: true, closeOnEscape: true })
}

async function showFile($: EngineInterface, path: string): Promise<void> {
  forgetDoc(path)
  await update($, shown, () => path)
  await openPane($, paneTitle(path))
}

async function showList($: EngineInterface): Promise<void> {
  await update($, shown, () => null)
  await openPane($, 'mercat')
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'mercat',
      description: 'Render a markdown or mermaid file with mercat in a side pane',
      argumentHint: '[file]',
      immediate: true,
    })
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      await update($, edited, () => [])
      await update($, shown, () => null)
    }
    return next(e)
  })

  on('command.run', { command: 'mercat' }, async ($, e) => {
    try {
      const arg = e.args.trim()
      if (arg !== '') {
        const path = resolvePath(await $.session.cwd(), arg)
        const stat = await $.fs.stat(path).catch(() => undefined)
        if (stat?.kind !== 'file') return { text: `No such file: ${arg}` }
        await showFile($, path)
        return { text: `Showing ${basename(path)}` }
      }
      const list = newestFirst(await read($, edited), editedIn(await $.session.messages()))
      if (list.length === 0) return { text: 'No files edited yet. Try: /mercat <file>' }
      await update($, edited, () => list)
      await showList($)
      return { text: `${list.length} edited file${list.length === 1 ? '' : 's'}` }
    } catch (error) {
      return { text: String(error) }
    }
  })

  on('tool.call', { tool: ['Edit', 'Write'] }, async ($, e, next) => {
    if (!isDoc(e.file_path)) return next(e)
    const ran = await next(e)
    if (ran.deny === undefined && ran.isError !== true) {
      const path = e.file_path
      await update($, edited, list => newestFirst([path], list))
      forgetDoc(path)
      if ((await read($, shown)) === path && (await $.ui.panes()).some(p => p.id === PANE)) $.ui.invalidate('ui.render')
    }
    return ran
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    const text = e.props.text
    if (e.props.isSummary === true || !/mermaid/i.test(text)) return next(e)
    const fences = mermaidFences(text)
    if (fences.length === 0) return next(e)
    const width = transcriptWidth(e.viewport?.columns)
    let isDrawn = false
    const parts = split(text, fences, fence => {
      const key = `d${width}\n${fence.source}`
      const drawn = diagrams.get(key)
      if (drawn === undefined && !isMercatMissing) schedule(key, () => drawDiagram($, key, fence.source, width))
      if (drawn) isDrawn = true
      return drawn ?? undefined
    })
    if (!isDrawn) return next(e)
    const first = parts.findIndex(p => 'md' in p)
    if (parts.every(p => 'md' in p) || first === -1)
      return next({ ...e, props: { ...e.props, text: parts.map(p => ('md' in p ? p.md : '')).join('') } })
    const { Box, Markdown, Text } = $.ui.resolve(e)
    const head = parts[first] as { md: string }
    const theirs = await next({ ...e, props: { ...e.props, text: head.md } })
    return (
      <Box flexDirection="column">
        {parts.map((part, i) =>
          i === first ? (
            theirs
          ) : 'md' in part ? (
            <Box key={`md${i}`} paddingLeft={2}>
              <Markdown text={part.md} />
            </Box>
          ) : (
            <Box key={`note${i}`} paddingLeft={2}>
              <Text color="warning">{part.note}</Text>
            </Box>
          ),
        )}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const cwd = await $.session.cwd()
    const path = await read($, shown)

    if (path === null) {
      const list = await read($, edited)
      return (
        <Box flexDirection="column">
          {list.length === 0 && <Text dimColor>No files edited yet.</Text>}
          {list.map(file => (
            <Button key={file} plain onPress={() => void showFile($, file).catch(() => undefined)}>
              {printable(basename(file))} <Text dimColor>{printable(relativeTo(cwd, file))}</Text>
            </Button>
          ))}
        </Box>
      )
    }

    const width = clampWidth(e.props.bodyColumns - 1)
    const key = docKey(width, path)
    const doc = docs.get(key)
    if (doc === undefined) schedule(key, () => drawDoc($, key, path, width))

    return (
      <Box flexDirection="column">
        <Box flexDirection="row">
          <Button key="back" label="back" hotkey="b" onPress={() => void showList($).catch(() => undefined)} />
          <Text dimColor> {printable(relativeTo(cwd, path))}</Text>
        </Box>
        {doc === undefined && <Text dimColor>rendering…</Text>}
        {doc !== undefined && 'error' in doc && <Text color="error">{doc.error}</Text>}
        {doc !== undefined &&
          'lines' in doc &&
          doc.lines.map(line => (
            <Text wrap="truncate">
              {line.length === 0 ? ' ' : line.map(span => <Text {...span.style}>{span.text}</Text>)}
            </Text>
          ))}
      </Box>
    )
  })
}
