const types = @import("types.zig");

const RenderOptions = types.RenderOptions;
const CompactionLevel = types.CompactionLevel;
const CompactionHints = types.CompactionHints;
const Direction = types.Direction;

pub const sequence_levels = [_]CompactionLevel{
    .default,
    .reduced,
    .tight,
    .direction_switch,
};

pub const CompactionController = struct {
    options: RenderOptions,

    pub fn init(options: RenderOptions) CompactionController {
        return .{ .options = options };
    }

    pub fn sequenceHints(self: CompactionController, level: CompactionLevel, base_direction: Direction, direction_explicit: bool) ?CompactionHints {
        return switch (level) {
            .default => self.makeHints(level, self.options.horizontal_spacing, self.options.vertical_spacing, 8),
            .reduced => self.makeHints(level, self.options.horizontal_spacing, self.options.vertical_spacing, 4),
            .tight => self.makeHints(level, self.options.horizontal_spacing, self.options.vertical_spacing, 2),
            .direction_switch => if (!direction_explicit and base_direction == .TB)
                CompactionHints{
                    .level = level,
                    .render_options = self.options,
                    .sequence_participant_spacing = 2,
                    .sequence_padding = 1,
                    .sequence_direction = .LR,
                }
            else
                null,
        };
    }

    fn makeHints(self: CompactionController, level: CompactionLevel, horizontal_spacing: u32, vertical_spacing: u32, sequence_participant_spacing: u32) CompactionHints {
        var render_options = self.options;
        render_options.horizontal_spacing = horizontal_spacing;
        render_options.vertical_spacing = vertical_spacing;
        return .{
            .level = level,
            .render_options = render_options,
            .sequence_participant_spacing = sequence_participant_spacing,
            .sequence_padding = 2,
        };
    }
};
