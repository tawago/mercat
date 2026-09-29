pub const RasterError = error{OutOfMemory};

pub const LabelDiagnostic = struct {
    kind: enum {
        node_label_truncated,
        edge_label_no_space,
        cluster_label_truncated,
    },
    node_or_edge_or_cluster_id: u32,
    original_len: u32,
    placed_len: u32,
};

pub const Report = struct {
    placed: u32,
    dropped: u32,
    displaced: u32,
    diagnostics: []const LabelDiagnostic,
};
