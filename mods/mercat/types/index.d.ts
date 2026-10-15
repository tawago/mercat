export type MercatEdited = string[]
export type MercatShown = string | null

declare module 'claude-code' {
  interface PluginState {
    mercat: { edited: MercatEdited; shown: MercatShown }
  }
}
