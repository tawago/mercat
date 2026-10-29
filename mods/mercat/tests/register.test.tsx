import type { Args, CommandRunInput, On, RenderInput, SessionMessage } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import { MOD_VERSION } from '../hooks/mercat'

const SESSION = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const
const ART = '┌───┐\n│ A │\n└───┘'
const DOC = '\x1b[1;38;5;81m# Title\x1b[0m\n\n\x1b]8;;https://x\x1b\\\x1b[4mlink\x1b[0m\x1b]8;;\x1b\\\n'

type World = { version?: string; stderr?: string; isMissing?: boolean; isFailing?: boolean; messages?: SessionMessage[]; files?: string[] }

function world(on: On, given: World = {}) {
  const runs: Args<'process.run'>[] = []
  const probes: Args<'process.run'>[] = []
  const opened: Args<'ui.open'>[] = []
  const toasts: string[] = []
  const drawn: string[] = []
  const invalidated: string[] = []
  const contents = new Map<string, string>()
  const clock = mock.clock(on)
  const files = new Set(given.files ?? ['/work/notes.md'])

  const gate = { hold: false, release: () => {} }
  on('process.run', async ($, e) => {
    if (given.isMissing === true) {
      ;(e.argv.includes('--version') ? probes : runs).push(e)
      return { deny: 'spawn mercat ENOENT' }
    }
    if (e.argv.includes('--version')) {
      probes.push(e)
      const stdout = `mercat ${given.version ?? MOD_VERSION}\n`
      return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    runs.push(e)
    if (given.isFailing === true && e.argv.includes('-')) return { deny: 'timed out' }
    const isDiagram = e.argv.includes('--format')
    const stdout = isDiagram ? `${ART}\n` : (contents.get(e.argv.at(-1)!) ?? DOC)
    if (gate.hold) await new Promise<void>(resolve => (gate.release = resolve))
    return { value: { exitCode: 0, stdout, stderr: isDiagram ? (given.stderr ?? '') : '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.open', ($, e) => {
    opened.push(e)
    return { value: { isPlaced: true } }
  })
  on('ui.panes', () => ({
    value: opened.slice(-1).map(p => ({ id: p.id, title: p.title ?? p.id, isShown: true, isFocused: true, isPlaced: true })),
  }))
  on('ui.invalidate', ($, e, next) => {
    invalidated.push(e.event)
    return next(e)
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('session.cwd', () => ({ value: '/work' }))
  on('session.messages', () => ({ value: given.messages ?? [] }))
  on('fs.stat', ($, e) =>
    files.has(e.path)
      ? { value: { kind: 'file', size: 1, mtimeMs: 0, isLink: false } }
      : { deny: `ENOENT: ${e.path}` },
  )
  on('tool.call', () => ({ result: 'done' }))
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    drawn.push(e.props.text)
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.text}</Text>
  })

  return { runs, probes, opened, toasts, drawn, invalidated, contents, gate, clock }
}

const reply = (text: string): RenderInput<'AssistantMessage'> => ({
  component: 'AssistantMessage',
  surface: 'terminal',
  requestId: 'msg-1',
  viewport: { columns: 100, rows: 40 },
  props: { text, isFirstOfReply: true },
})

const pane = (surface: 'terminal' | 'desktop') => ({
  plugin: 'mercat',
  surface,
  component: 'Pane' as const,
  requestId: 'mercat',
  viewport: { columns: 160, rows: 40 },
  props: {
    title: 'mercat',
    isFocused: true,
    bodyColumns: 70,
    placement: 'dock' as const,
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
})

const mercat = (args = ''): CommandRunInput => ({
  command: 'mercat',
  args,
  origin: { kind: 'composer' },
  presentation: { isFullscreen: true, columns: 160 },
})

const MERMAID = 'Here:\n\n```mermaid\nflowchart LR\nA-->B\n```\n\nDone.'

async function edit($: Engine, file_path: string) {
  await $.tool.call({ tool: 'Write', file_path, content: '# hi' })
}

describe('replies', () => {
  test('a mermaid fence is drawn once mercat finishes, never awaited while drawing', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)

    await $.ui.render(reply(MERMAID))
    expect(w.drawn.at(-1), 'first draw: raw block').toBe(MERMAID)
    expect(w.runs.map(r => r.argv)).toEqual([['mercat', '--format', 'plain', '-w', '99', '-']])
    expect(w.runs[0]!.init?.stdin).toBe('```mermaid\nflowchart LR\nA-->B\n```\n')

    await w.clock.settle()
    await $.ui.render(reply(MERMAID))
    expect(w.drawn.at(-1)).toBe(`Here:\n\n\`\`\`text\n${ART}\n\`\`\`\n\nDone.`)

    await $.ui.render(reply(MERMAID))
    expect(w.runs, 'cached: no second run').toHaveLength(1)
  })

  test('a clipped diagram is drawn, with its warning under the reply in the warning color', async ($, on) => {
    const w = world(on, { stderr: 'mercat: warning: mermaid: diagram clipped: true width 121 > budget 97\n' })
    await $.session.start(SESSION)
    await $.ui.render(reply(MERMAID))
    await w.clock.settle()
    const tree = JSON.stringify(await $.ui.render(reply(MERMAID)))
    expect(w.drawn.at(-1), 'the engine draws the reply up to the diagram').toBe('Here:\n\n')
    const note = tree.indexOf('needs 121 columns, has 97')
    const art = tree.indexOf('```text')
    expect(note).toBeGreaterThan(-1)
    expect(art, 'the diagram follows its warning').toBeGreaterThan(note)
    expect(tree).toContain('"color":"warning"')
  })

  test('an unterminated fence is left alone and starts nothing', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    const streaming = 'Here:\n```mermaid\nflowchart LR\nA-->'
    await $.ui.render(reply(streaming))
    expect(w.drawn.at(-1)).toBe(streaming)
    expect(w.runs).toEqual([])
  })

  test('mercat missing: raw block stays, one hint, no retries', async ($, on) => {
    const w = world(on, { isMissing: true })
    await $.session.start(SESSION)
    await $.ui.render(reply(MERMAID))
    await w.clock.settle()
    await $.ui.render(reply(MERMAID))
    await $.ui.render(reply(MERMAID.replace('A-->B', 'C-->D')))
    await w.clock.settle()
    expect(w.drawn.every(text => text.includes('```mermaid'))).toBe(true)
    expect(w.toasts).toEqual(['mercat not found on PATH — see https://github.com/tawago/mercat#installation'])
    expect(w.runs.length, 'no render retries').toBeLessThanOrEqual(1)
  })

  test('a failed run with mercat present is cached, no hint', async ($, on) => {
    const w = world(on, { isFailing: true })
    await $.session.start(SESSION)
    await $.ui.render(reply(MERMAID))
    await w.clock.settle()
    await $.ui.render(reply(MERMAID))
    await w.clock.settle()
    expect(w.drawn.at(-1)).toBe(MERMAID)
    expect(w.toasts).toEqual([])
    expect(w.runs.map(r => r.argv.at(-1))).toEqual(['-'])
  })

  test('an older mercat gets one upgrade hint at start; a current one gets none', async ($, on) => {
    const w = world(on, { version: '0.3.1' })
    await $.session.start(SESSION)
    await w.clock.settle()
    expect(w.toasts).toEqual([`mercat 0.3.1 is older than this mod (${MOD_VERSION}) — brew upgrade tawago/tap/mercat`])
  })

  test('a current mercat gets no hint', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await w.clock.settle()
    expect(w.probes).toHaveLength(1)
    expect(w.toasts).toEqual([])
  })
})

describe('redraws', () => {
  test('a diagram evicted from the cache and drawn again asks for no second redraw', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    const many = Array.from({ length: 205 }, (_, i) => `\`\`\`mermaid\nflowchart LR\nN${i}-->M\n\`\`\``).join('\n\n')
    await $.ui.render(reply(many))
    await w.clock.settle()
    const first = w.invalidated.length
    expect(first).toBe(205)
    await $.ui.render(reply(many))
    await w.clock.settle()
    await $.ui.render(reply(many))
    await w.clock.settle()
    expect(w.invalidated.length).toBe(first)
  })
})

describe('/mercat on and off', () => {
  const DRAWN = `Here:\n\n\`\`\`text\n${ART}\n\`\`\`\n\nDone.`

  test('off shows mermaid blocks as written and runs no mercat; on draws them again', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await $.ui.render(reply(MERMAID))
    await w.clock.settle()

    expect(await $.command.run(mercat('off'))).toMatchObject({ text: 'Diagrams off: mermaid blocks show as written' })
    expect(w.invalidated.at(-1)).toBe('ui.render')
    await $.ui.render(reply(MERMAID))
    expect(w.drawn.at(-1)).toBe(MERMAID)
    await $.ui.render(reply(MERMAID.replace('A-->B', 'A-->C')))
    expect(w.runs, 'no run while off').toHaveLength(1)

    expect(await $.command.run(mercat('on'))).toMatchObject({ text: 'Diagrams on' })
    await $.ui.render(reply(MERMAID))
    expect(w.drawn.at(-1)).toBe(DRAWN)
  })

  test('a new session starts on', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await $.command.run(mercat('off'))
    await $.session.start(SESSION)
    await $.ui.render(reply(MERMAID))
    await w.clock.settle()
    await $.ui.render(reply(MERMAID))
    expect(w.drawn.at(-1)).toBe(DRAWN)
  })
})

describe('/mercat', () => {
  test('no edits: says so and opens nothing', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    expect(await $.command.run(mercat())).toMatchObject({
      text: 'No files edited yet. Try: /mercat <file>',
    })
    expect(w.opened).toEqual([])
  })

  test('a missing file is an error, no pane', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    const ran = await $.command.run(mercat('nope.md'))
    expect(ran.text).toBe('No such file: nope.md')
    expect(w.opened).toEqual([])
  })

  test('/mercat <file> opens the pane with the file rendered at the pane width', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await $.command.run(mercat('notes.md'))
    expect(w.opened.at(-1)).toMatchObject({ id: 'mercat', title: 'mercat: notes.md', focus: true, closeOnEscape: true })

    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount(pane(surface))
      await w.clock.settle()
      expect(await ui.find({ type: 'Text', text: /# Title/ })).toBeDefined()
      const links = await ui.findAll({ type: 'Text', text: 'link' })
      expect(links.some(link => link.props.underline === true)).toBe(true)
      expect(await ui.find({ type: 'Text', text: /\x1b|8;;/ })).toBeUndefined()
      await ui.unmount()
    }
    expect(w.runs.map(r => r.argv)).toEqual([['mercat', '-w', '69', '/work/notes.md']])
  })

  test('edits are tracked; the list opens and a pick shows the file, back returns', async ($, on) => {
    const w = world(on, { files: ['/work/a.md', '/work/docs/b.mmd'] })
    await $.session.start(SESSION)
    await edit($, '/work/a.md')
    await edit($, '/work/src/x.ts')
    await edit($, '/work/docs/b.mmd')

    expect(await $.command.run(mercat())).toMatchObject({ text: '2 edited files' })
    expect(w.opened.at(-1)).toMatchObject({ id: 'mercat', title: 'mercat' })

    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount(pane(surface))
      const rows = await ui.findAll({ type: 'Button' })
      expect(rows.map(r => r.key)).toEqual(['/work/docs/b.mmd', '/work/a.md'])

      await ui.press({ key: '/work/a.md' })
      expect(w.opened.at(-1)).toMatchObject({ title: 'mercat: a.md' })
      await w.clock.settle()
      expect(await ui.find({ type: 'Text', text: /# Title/ })).toBeDefined()

      await ui.press({ key: 'back' })
      expect(await ui.find({ key: '/work/a.md' })).toBeDefined()
      await ui.unmount()
    }
  })

  test('edits made before the mod loaded are found in the transcript', async ($, on) => {
    const messages: SessionMessage[] = [
      {
        role: 'assistant',
        text: '',
        toolUses: [{ tool_use_id: 't1', tool: 'Edit', input: { file_path: '/work/old.md' } }],
      },
    ]
    world(on, { messages })
    await $.session.start(SESSION)
    expect(await $.command.run(mercat())).toMatchObject({ text: '1 edited file' })
  })

  test('/clear forgets the edited files', async ($, on) => {
    world(on)
    await $.session.start(SESSION)
    await edit($, '/work/notes.md')
    await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
    expect(await $.command.run(mercat())).toMatchObject({ text: 'No files edited yet. Try: /mercat <file>' })
  })

  test('a file name with control characters still opens a titled pane from the list', async ($, on) => {
    const odd = '/work/a\nb\x1b.md'
    const w = world(on, { files: [odd] })
    await $.session.start(SESSION)
    await edit($, odd)
    await $.command.run(mercat())
    const ui = await $.ui.mount(pane('terminal'))
    await ui.press({ key: odd })
    expect(w.opened.at(-1)).toMatchObject({ title: 'mercat: a?b?.md' })
    await ui.unmount()
  })

  test('an edit during a render in flight is shown, not the pre-edit output', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    w.contents.set('/work/notes.md', 'old\n')
    await $.command.run(mercat('notes.md'))
    w.gate.hold = true
    const ui = await $.ui.mount(pane('terminal'))
    w.contents.set('/work/notes.md', 'new\n')
    await edit($, '/work/notes.md')
    w.gate.hold = false
    w.gate.release()
    await w.clock.settle()
    await ui.unmount()
    const again = await $.ui.mount(pane('terminal'))
    await w.clock.settle()
    expect(await again.find({ type: 'Text', text: 'new' })).toBeDefined()
    await again.unmount()
  })

  test('an edit redraws only when the pane shows that file', async ($, on) => {
    const w = world(on, { files: ['/work/a.md', '/work/b.md'] })
    await $.session.start(SESSION)
    await $.command.run(mercat('a.md'))
    const ui = await $.ui.mount(pane('terminal'))
    await w.clock.settle()
    await ui.unmount()
    const before = w.invalidated.length
    await edit($, '/work/b.md')
    expect(w.invalidated.length).toBe(before)
    await edit($, '/work/a.md')
    expect(w.invalidated.length).toBe(before + 1)
  })
})
