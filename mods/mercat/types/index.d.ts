export type MercatEdited = string[]
export type MercatShown = string | null
export type MercatIsOff = boolean

declare module 'claude-code' {
  interface PluginState {
    mercat: { edited: MercatEdited; shown: MercatShown; isOff: MercatIsOff }
  }
}
