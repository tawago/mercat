import type { ProcessRunResult, SessionMessage } from 'claude-code'

export const MOD_VERSION = '0.3.4'
export const MIN_WIDTH = 20
export const MAX_WIDTH = 1000
export const TRANSCRIPT_MARGIN = 1
export const MISSING_HINT = 'mercat not found on PATH — brew install tawago/tap/mercat'

export const clampWidth = (n: number) => Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, Math.floor(n)))

export const transcriptWidth = (columns: number | undefined) =>
  columns === undefined ? 80 : clampWidth(columns - TRANSCRIPT_MARGIN)

export const diagramArgv = (width: number) => ['mercat', '--format', 'plain', '-w', String(width), '-']

export const documentArgv = (width: number, path: string) => ['mercat', '-w', String(width), path]

export function diagramInput(source: string): string {
  const runs = source.match(/`{3,}/g) ?? []
  const ticks = '`'.repeat(Math.max(3, ...runs.map(r => r.length + 1)))
  return `${ticks}mermaid\n${source}\n${ticks}\n`
}

export function diagramOf(run: ProcessRunResult): string | undefined {
  const out = run.stdout.trimEnd()
  const isDrawn =
    run.exitCode === 0 &&
    out.trim() !== '' &&
    !run.stderr.split('\n').some(l => /warning:/.test(l) && !/diagram clipped/.test(l)) &&
    !out.includes('<PARSE ERROR') &&
    !/^[ \t]*`{3,}mermaid/im.test(out)
  return isDrawn ? out : undefined
}

export const versionOf = (stdout: string) => /(\d+)\.(\d+)\.(\d+)/.exec(stdout)?.[0]

export function isOlder(have: string, want: string): boolean {
  const a = have.split('.').map(Number)
  const b = want.split('.').map(Number)
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i]! < b[i]!
  return false
}

export const upgradeHint = (have: string) =>
  `mercat ${have} is older than this mod (${MOD_VERSION}) — brew upgrade tawago/tap/mercat`

export function clipNoteOf(stderr: string): string | undefined {
  const m = /diagram clipped: true width (\d+) > budget (\d+)/.exec(stderr)
  return m === null
    ? undefined
    : `⚠ mercat: diagram clipped, needs ${m[1]} columns, has ${m[2]}. Widen the terminal to see it whole.`
}

export class Lru<V> {
  private readonly map = new Map<string, V>()
  constructor(private readonly limit: number) {}

  get(key: string): V | undefined {
    const value = this.map.get(key)
    if (value !== undefined) {
      this.map.delete(key)
      this.map.set(key, value)
    }
    return value
  }

  has(key: string): boolean {
    return this.map.has(key)
  }

  set(key: string, value: V): void {
    this.map.delete(key)
    this.map.set(key, value)
    while (this.map.size > this.limit) this.map.delete(this.map.keys().next().value!)
  }

  dropWhere(test: (key: string) => boolean): boolean {
    let dropped = false
    for (const key of [...this.map.keys()]) if (test(key) && this.map.delete(key)) dropped = true
    return dropped
  }
}

const DOC = /\.(md|markdown|mmd|mermaid)$/i

export const isDoc = (path: string) => DOC.test(path)

export const basename = (path: string) => path.replace(/[\\/]+$/, '').split(/[\\/]/).pop() ?? path

export const printable = (s: string) => s.replace(/[\x00-\x1f\x7f-\x9f]/g, '?')

export const paneTitle = (path: string) => `mercat: ${printable(basename(path))}`

export function resolvePath(cwd: string, arg: string): string {
  const path = arg.trim().replace(/^(["'])(.*)\1$/, '$2')
  if (/^([\\/]|[A-Za-z]:[\\/])/.test(path)) return path
  const parts = `${cwd}/${path}`.split('/')
  const out: string[] = []
  for (const part of parts) {
    if (part === '..') out.length > 1 && out.pop()
    else if (part !== '.' && !(part === '' && out.length > 0)) out.push(part)
  }
  return out.join('/')
}

export function relativeTo(cwd: string, path: string): string {
  const root = cwd.replace(/\/+$/, '') + '/'
  return path.startsWith(root) ? path.slice(root.length) : path
}

export const EDIT_TOOLS = ['Edit', 'Write'] as const

export function editedIn(messages: readonly SessionMessage[]): string[] {
  const paths: string[] = []
  for (const message of messages)
    for (const use of message.toolUses)
      if ((EDIT_TOOLS as readonly string[]).includes(use.tool) && use.isError !== true) {
        const path = use.input.file_path
        if (typeof path === 'string' && isDoc(path)) paths.push(path)
      }
  return paths.reverse()
}

export function newestFirst(...lists: readonly (readonly string[])[]): string[] {
  return [...new Set(lists.flat())].slice(0, 100)
}
