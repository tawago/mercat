const sketch = @import("../sketch.zig");
const geo = @import("geometry.zig");

pub fn coveredByOther(s: sketch.Sketch, edge_id: u32, x: i32, y: i32) bool {
    for (s.edges) |other| {
        if (other.id == edge_id) continue;
        if (other.polyline.len < 2) continue;
        for (other.polyline[0 .. other.polyline.len - 1], 0..) |p, i| {
            if (geo.onSegment(p, other.polyline[i + 1], x, y)) return true;
        }
    }
    for (s.rails) |rail| {
        for (rail.stem[0 .. rail.stem.len - 1], 0..) |p, i| {
            if (geo.onSegment(p, rail.stem[i + 1], x, y)) return true;
        }
        if (geo.onSegment(rail.crossbar[0], rail.crossbar[1], x, y)) return true;
        for (rail.taps) |tap| {
            if (tap.edge == edge_id) continue;
            if (geo.onSegment(tap.at, tap.landing, x, y)) return true;
        }
    }
    return false;
}
