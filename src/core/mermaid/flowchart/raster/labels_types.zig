pub const RasterError = error{OutOfMemory};

pub const Report = struct {
    placed: u32,
    dropped: u32,
    displaced: u32,
};
