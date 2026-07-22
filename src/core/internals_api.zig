//! Single public facade over the renderer internals the out-of-tree `eval/`
//! scorer needs. Rooted at `src/core/` so its relative imports into
//! `mermaid_v2/` and `mermaid/` resolve inside the module path (Zig 0.15
//! forbids a module rooted under `eval/` from importing across into `src/`).
//!
//! CRITICAL: this must be wired as a SINGLE named module (`internals`) in
//! build.zig. `sem_graph.zig` and `parse.zig` are re-exported from the same
//! module here, so they compile exactly once and share type identity. Rooting
//! them as two separate modules would compile two copies of `SemGraph` and
//! break type identity across the scorer.
//!
//! Requires the `prim` module (mermaid_v2 dependency) wired on the importing
//! module. Consumed as the named module `internals` by the `eval/` code.

pub const sem_graph = @import("mermaid_v2/sem_graph.zig");
pub const parse = @import("mermaid_v2/parse.zig");
pub const mermaid_types = @import("mermaid/types.zig");
