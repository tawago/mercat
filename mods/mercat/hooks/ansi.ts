export type Style = {
  color?: string
  backgroundColor?: string
  bold?: boolean
  dimColor?: boolean
  italic?: boolean
  underline?: boolean
  inverse?: boolean
  strikethrough?: boolean
}

export type Span = { text: string; style: Style }
export type Line = Span[]

const BASE16 = [
  '#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd', '#00cdcd', '#e5e5e5',
  '#7f7f7f', '#ff0000', '#00ff00', '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff',
]

const hex2 = (n: number) => Math.max(0, Math.min(255, n | 0)).toString(16).padStart(2, '0')
const rgb = (r: number, g: number, b: number) => `#${hex2(r)}${hex2(g)}${hex2(b)}`

export function xterm256(n: number): string | undefined {
  if (!Number.isInteger(n) || n < 0 || n > 255) return undefined
  if (n < 16) return BASE16[n]
  if (n >= 232) {
    const v = 8 + (n - 232) * 10
    return rgb(v, v, v)
  }
  const i = n - 16
  const step = (c: number) => (c === 0 ? 0 : 55 + c * 40)
  return rgb(step(Math.floor(i / 36)), step(Math.floor(i / 6) % 6), step(i % 6))
}

function applySgr(style: Style, params: number[]): Style {
  const s = { ...style }
  for (let i = 0; i < params.length; i++) {
    const p = params[i]!
    if (p === 0) for (const k of Object.keys(s)) delete s[k as keyof Style]
    else if (p === 1) s.bold = true
    else if (p === 2) s.dimColor = true
    else if (p === 3) s.italic = true
    else if (p === 4) s.underline = true
    else if (p === 7) s.inverse = true
    else if (p === 9) s.strikethrough = true
    else if (p === 22) (delete s.bold, delete s.dimColor)
    else if (p === 23) delete s.italic
    else if (p === 24) delete s.underline
    else if (p === 27) delete s.inverse
    else if (p === 29) delete s.strikethrough
    else if (p >= 30 && p <= 37) s.color = BASE16[p - 30]
    else if (p >= 90 && p <= 97) s.color = BASE16[p - 82]
    else if (p >= 40 && p <= 47) s.backgroundColor = BASE16[p - 40]
    else if (p >= 100 && p <= 107) s.backgroundColor = BASE16[p - 92]
    else if (p === 39) delete s.color
    else if (p === 49) delete s.backgroundColor
    else if (p === 38 || p === 48) {
      const key = p === 38 ? 'color' : 'backgroundColor'
      let c: string | undefined
      if (params[i + 1] === 5) {
        c = xterm256(params[i + 2] ?? -1)
        i += 2
      } else if (params[i + 1] === 2) {
        c = rgb(params[i + 2] ?? 0, params[i + 3] ?? 0, params[i + 4] ?? 0)
        i += 4
      }
      if (c !== undefined) s[key] = c
    }
  }
  return s
}

const num = (x: string) => (x === '' ? 0 : Number(x))

function sgrGroup(group: string): number[] {
  const sub = group.split(':').map(num)
  if (sub.length > 1 && (sub[0] === 38 || sub[0] === 48) && sub[1] === 2 && sub.length >= 6)
    return [sub[0], 2, ...sub.slice(3, 6)]
  return sub
}

// CSI, OSC (BEL or ST), other two-byte escapes, stray control bytes.
const ESCAPE = /\x1b\[([0-?]*)[ -/]*([@-~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[@-Z\\-_]|[\x00-\x08\x0b-\x1f\x7f]/g

export function parseAnsi(input: string): Line[] {
  const lines: Line[] = [[]]
  let style: Style = {}
  const push = (text: string) => {
    const parts = text.split('\n')
    parts.forEach((part, k) => {
      if (k > 0) lines.push([])
      if (part === '') return
      const line = lines[lines.length - 1]!
      const last = line[line.length - 1]
      if (last !== undefined && last.style === style) last.text += part
      else line.push({ text: part, style })
    })
  }
  const text = input.replace(/\r\n?/g, '\n')
  let at = 0
  for (const m of text.matchAll(ESCAPE)) {
    push(text.slice(at, m.index))
    at = m.index + m[0].length
    if (m[2] === 'm') {
      const params = m[1] === '' ? [0] : m[1]!.split(';').flatMap(sgrGroup)
      style = applySgr(style, params)
    }
  }
  push(text.slice(at))
  while (lines.length > 1 && lines[lines.length - 1]!.length === 0) lines.pop()
  return lines
}

export function plainText(line: Line): string {
  return line.map(s => s.text).join('')
}
