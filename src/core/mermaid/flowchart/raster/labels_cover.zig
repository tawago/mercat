const sketch = @import("../sketch.zig");

pub fn coveredByOther(s: sketch.Sketch, edge_id: u32, x: i32, y: i32) bool {
    for (s.edges) |other| {
        if (other.id == edge_id) continue;
        if (other.polyline.len < 2) continue;
        for (other.polyline[0 .. other.polyline.len - 1], 0..) |p, i| {
            if (onSeg(p, other.polyline[i + 1], x, y)) return true;
        }
    }
    for (s.rails) |rail| {
        for (rail.stem[0 .. rail.stem.len - 1], 0..) |p, i| {
            if (onSeg(p, rail.stem[i + 1], x, y)) return true;
        }
        if (onSeg(rail.crossbar[0], rail.crossbar[1], x, y)) return true;
        for (rail.taps) |tap| {
            if (tap.edge == edge_id) continue;
            if (onSeg(tap.at, tap.landing, x, y)) return true;
        }
    }
    return false;
}

fn onSeg(a: sketch.Point, b: sketch.Point, x: i32, y: i32) bool {
    if (a.x != b.x and a.y != b.y) return false;
    return x >= @min(a.x, b.x) and x <= @max(a.x, b.x) and
        y >= @min(a.y, b.y) and y <= @max(a.y, b.y);
}
