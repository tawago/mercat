export type Fence = { start: number; end: number; indent: string; source: string }

const OPEN = /^( *)(`{3,}|~{3,})([^\r]*)\r?$/
const CLOSE = /^( *)(`{3,}|~{3,})[ \t]*\r?$/

export function mermaidFences(text: string): Fence[] {
  const fences: Fence[] = []
  let offset = 0
  let open: { start: number; indent: string; mark: string; isMermaid: boolean; body: string[] } | null = null

  for (const line of text.split('\n')) {
    const lineEnd = offset + line.length
    if (open === null) {
      const m = OPEN.exec(line)
      const info = m?.[3]?.trim() ?? ''
      if (m !== null && !(m[2]![0] === '`' && info.includes('`'))) {
        const isMermaid = /^mermaid(?:[ \t]|$)/i.test(info)
        open = { start: offset, indent: m[1]!, mark: m[2]!, isMermaid, body: [] }
      }
    } else {
      const close = CLOSE.exec(line)
      if (
        close !== null &&
        close[1]!.length <= open.indent.length + 3 &&
        close[2]![0] === open.mark[0] &&
        close[2]!.length >= open.mark.length
      ) {
        if (open.isMermaid)
          fences.push({ start: open.start, end: lineEnd, indent: open.indent, source: open.body.join('\n') })
        open = null
      } else if (open.isMermaid) {
        open.body.push(stripIndent(line.replace(/\r$/, ''), open.indent.length))
      }
    }
    offset = lineEnd + 1
  }
  return fences
}

function stripIndent(line: string, n: number): string {
  let i = 0
  while (i < n && line[i] === ' ') i++
  return line.slice(i)
}

export function textFence(rendered: string, indent = ''): string {
  const runs = rendered.match(/`+/g) ?? []
  const ticks = '`'.repeat(Math.max(3, ...runs.map(r => r.length + 1)))
  const body = rendered.replace(/\n+$/, '').split('\n').map(l => indent + l)
  return [`${indent}${ticks}text`, ...body, `${indent}${ticks}`].join('\n')
}

export type Drawn = { art: string; note?: string }
export type Part = { md: string } | { note: string }

export function split(text: string, fences: readonly Fence[], drawn: (f: Fence) => Drawn | undefined): Part[] {
  const parts: Part[] = []
  let md = ''
  let at = 0
  for (const f of fences) {
    const d = drawn(f)
    if (d === undefined) continue
    md += text.slice(at, f.start)
    if (d.note !== undefined) {
      if (md.trim() !== '') parts.push({ md })
      parts.push({ note: d.note })
      md = ''
    }
    md += textFence(d.art, f.indent)
    at = f.end
  }
  md += text.slice(at)
  if (md.trim() !== '') parts.push({ md })
  return parts
}

export function rewrite(text: string, fences: readonly Fence[], drawn: (f: Fence) => string | undefined): string {
  return split(text, fences, f => {
    const art = drawn(f)
    return art === undefined ? undefined : { art }
  })
    .map(p => ('md' in p ? p.md : ''))
    .join('')
}
