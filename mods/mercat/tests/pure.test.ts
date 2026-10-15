import type { SessionMessage } from 'claude-code'
import { describe, expect, test } from 'claude-code/testing'

import { parseAnsi, plainText, xterm256 } from '../hooks/ansi'
import { mermaidFences, rewrite, split, textFence } from '../hooks/fences'
import {
  diagramInput,
  clipNoteOf,
  diagramOf,
  editedIn,
  paneTitle,
  Lru,
  newestFirst,
  resolvePath,
  transcriptWidth,
} from '../hooks/mercat'

const run = (stdout: string, extra: { exitCode?: number; stderr?: string } = {}) => ({
  exitCode: extra.exitCode ?? 0,
  stdout,
  stderr: extra.stderr ?? '',
  isStdoutTruncated: false,
  isStderrTruncated: false,
})

describe('fences', () => {
  test('finds closed mermaid fences only', () => {
    const text = 'a\n```mermaid\nflowchart LR\nA-->B\n```\nb\n~~~Mermaid\ngraph TD\n~~~\n```mermaid\nopen'
    const found = mermaidFences(text)
    expect(found.map(f => f.source)).toEqual(['flowchart LR\nA-->B', 'graph TD'])
    expect(text.slice(found[0]!.start, found[0]!.end)).toBe('```mermaid\nflowchart LR\nA-->B\n```')
  })

  test('ignores other languages and mismatched closers', () => {
    expect(mermaidFences('```js\nx\n```')).toEqual([])
    expect(mermaidFences('````mermaid\nA\n```\n')).toEqual([])
    expect(mermaidFences('```mermaidx\nA\n```')).toEqual([])
  })

  test('a mermaid example inside another fence is literal', () => {
    expect(mermaidFences('````markdown\n```mermaid\nflowchart TD\nA-->B\n```\n````')).toEqual([])
    expect(mermaidFences('~~~md\n```mermaid\ngraph TD\n```\n~~~\n```mermaid\nX\n```').map(f => f.source)).toEqual(['X'])
  })

  test('CRLF line endings', () => {
    const text = '```mermaid\r\nflowchart TD\r\nA-->B\r\n```\r\nafter'
    const [f] = mermaidFences(text)
    expect(f!.source).toBe('flowchart TD\nA-->B')
    expect(rewrite(text, [f!], () => 'ART')).toBe('```text\nART\n```\nafter')
  })

  test('fences in nested list items', () => {
    const [f] = mermaidFences('- a\n  - b\n\n     ```mermaid\n     graph TD\n     A-->B\n     ```')
    expect(f).toMatchObject({ indent: '     ', source: 'graph TD\nA-->B' })
  })

  test('each warning sits right above its own diagram', () => {
    const text = 'intro\n```mermaid\nA\n```\nmid\n```mermaid\nB\n```\nend'
    const parts = split(text, mermaidFences(text), f => ({ art: f.source, note: `clip ${f.source}` }))
    expect(parts).toEqual([
      { md: 'intro\n' },
      { note: 'clip A' },
      { md: '```text\nA\n```\nmid\n' },
      { note: 'clip B' },
      { md: '```text\nB\n```\nend' },
    ])
  })

  test('rewrites drawn fences and keeps the rest', () => {
    const text = 'x\n```mermaid\nA\n```\ny\n```mermaid\nB\n```'
    const out = rewrite(text, mermaidFences(text), f => (f.source === 'A' ? 'BOX' : undefined))
    expect(out).toBe('x\n```text\nBOX\n```\ny\n```mermaid\nB\n```')
    expect(rewrite(text, mermaidFences(text), () => undefined)).toBe(text)
  })

  test('a text fence outgrows backticks in the art and keeps indent', () => {
    expect(textFence('a ``` b', '  ')).toBe('  ````text\n  a ``` b\n  ````')
  })
})

describe('ansi', () => {
  test('parses 256-color, bold, background and reset', () => {
    const lines = parseAnsi('\x1b[1;38;5;81m# T\x1b[0m\n\x1b[38;5;250;48;5;236m code \x1b[0m')
    expect(lines).toHaveLength(2)
    expect(lines[0]![0]).toEqual({ text: '# T', style: { bold: true, color: '#5fd7ff' } })
    expect(lines[1]![0]!.style).toEqual({ color: '#bcbcbc', backgroundColor: '#303030' })
  })

  test('strips OSC 8 hyperlinks and other escapes', () => {
    const lines = parseAnsi('\x1b]8;;https://x\x1b\\\x1b[4;38;5;117mlink\x1b[0m\x1b]8;;\x1b\\ \x1b[2Kdone\x07')
    expect(plainText(lines[0]!)).toBe('link done')
    expect(lines[0]![0]!.style).toEqual({ underline: true, color: '#87d7ff' })
  })

  test('truecolor, 16 colors and resets of one attribute', () => {
    const [line] = parseAnsi('\x1b[38;2;1;2;3mA\x1b[91;1mB\x1b[22;39mC')
    expect(line!.map(s => s.style)).toEqual([{ color: '#010203' }, { color: '#ff0000', bold: true }, {}])
  })

  test('colon-form truecolor with a colorspace field', () => {
    const [line] = parseAnsi('\x1b[38:2::10:20:30mX\x1b[48:2:1:2:3mY')
    expect(line!.map(s => s.style)).toEqual([{ color: '#0a141e' }, { color: '#0a141e', backgroundColor: '#010203' }])
  })

  test('blank lines stay', () => {
    expect(parseAnsi('a\n\nb').map(plainText)).toEqual(['a', '', 'b'])
    expect(xterm256(232)).toBe('#080808')
    expect(xterm256(16)).toBe('#000000')
  })
})

describe('mercat helpers', () => {
  test('a drawing is told from an echoed fence and a parse error', () => {
    expect(diagramOf(run('┌─┐\n└─┘\n'))).toBe('┌─┐\n└─┘')
    expect(diagramOf(run('  ```mermaid\n   pie title *Key*\n  ```\n'))).toBeUndefined()
    expect(diagramOf(run('  <PARSE ERROR: x>'))).toBeUndefined()
    expect(diagramOf(run('art', { stderr: 'warning: mermaid parse failed' }))).toBeUndefined()
    expect(diagramOf(run('art»', { stderr: 'mercat: warning: mermaid: diagram clipped: true width 121 > budget 70\n' }))).toBe('art»')
    expect(diagramOf(run('art', { exitCode: 1 }))).toBeUndefined()
    expect(clipNoteOf('mercat: warning: mermaid: diagram clipped: true width 121 > budget 93\n')).toBe(
      '⚠ mercat: diagram clipped, needs 121 columns, has 93. Widen the terminal to see it whole.',
    )
    expect(clipNoteOf('')).toBeUndefined()
    expect(diagramOf(run('  \n'))).toBeUndefined()
  })

  test('the source goes to mercat as a mermaid fence that outgrows its backticks', () => {
    expect(diagramInput('flowchart\nA-->B')).toBe('```mermaid\nflowchart\nA-->B\n```\n')
    expect(diagramInput('A["```"]')).toBe('````mermaid\nA["```"]\n````\n')
    expect(paneTitle('/w/a\tb.md')).toBe('mercat: a?b.md')
  })

  test('widths', () => {
    expect(transcriptWidth(undefined)).toBe(80)
    expect(transcriptWidth(100)).toBe(99)
    expect(transcriptWidth(10)).toBe(20)
    expect(transcriptWidth(5000)).toBe(1000)
  })

  test('paths', () => {
    expect(resolvePath('/work/a', 'b/c.md')).toBe('/work/a/b/c.md')
    expect(resolvePath('/work/a', '../x.md')).toBe('/work/x.md')
    expect(resolvePath('/work', '"/abs/y.md"')).toBe('/abs/y.md')
    expect(resolvePath('/work', './z.md')).toBe('/work/z.md')
  })

  test('edited files from messages: docs only, successful, newest first, deduped', () => {
    const use = (tool: string, file_path: string, isError?: true) => ({
      tool_use_id: file_path,
      tool,
      input: { file_path },
      ...(isError ? { isError } : {}),
    })
    const messages: SessionMessage[] = [
      { role: 'assistant', text: '', toolUses: [use('Write', '/w/a.md'), use('Edit', '/w/b.ts')] },
      { role: 'assistant', text: '', toolUses: [use('Edit', '/w/c.mmd'), use('Edit', '/w/d.md', true)] },
      { role: 'assistant', text: '', toolUses: [use('Read', '/w/e.md'), use('Edit', '/w/a.md')] },
    ]
    expect(newestFirst(editedIn(messages))).toEqual(['/w/a.md', '/w/c.mmd'])
    expect(newestFirst(['/w/n.md'], editedIn(messages))).toEqual(['/w/n.md', '/w/a.md', '/w/c.mmd'])
  })

  test('lru evicts the least recently used', () => {
    const lru = new Lru<number>(2)
    lru.set('a', 1)
    lru.set('b', 2)
    lru.get('a')
    lru.set('c', 3)
    expect([lru.has('a'), lru.has('b'), lru.has('c')]).toEqual([true, false, true])
    expect(lru.dropWhere(k => k === 'a')).toBe(true)
    expect(lru.has('a')).toBe(false)
  })
})
