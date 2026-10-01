pub const NodeGeom = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    layer: u32,

    pub fn right(self: NodeGeom) i32 {
        return self.x + @as(i32, @intCast(self.w));
    }

    pub fn centerX(self: NodeGeom) i32 {
        return self.x + @divTrunc(@as(i32, @intCast(self.w)), 2);
    }
};
