//! Theme Module - Maps semantic styles to concrete colors
//!
//! This module bridges the gap between the semantic SpanStyle (heading, code, link)
//! and the concrete terminal output. It provides:
//!
//!   - Palette: A set of StyleTokens for each semantic style
//!   - token(): Maps SpanStyle → StyleToken for a given palette
//!   - vaxisStyle(): Converts StyleToken → vaxis.Style for TUI rendering
//!
//! The CLI uses StyleToken directly with ansi.writeTokenStyled().
//! The TUI uses vaxisStyle() to convert StyleToken to vaxis.Style.
//!
//! This separation allows the same Span data to render identically in both modes.

const config = @import("config.zig");
const render_model = @import("render_model.zig");
const vaxis = @import("vaxis");

/// Concrete style attributes for terminal output.
/// Contains the actual color index and text decorations.
pub const StyleToken = struct {
    fg_index: u8,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    bg_index: ?u8 = null,
};

pub const Palette = struct {
    heading1: StyleToken,
    heading2: StyleToken,
    heading3: StyleToken,
    heading4: StyleToken,
    heading5: StyleToken,
    heading6: StyleToken,
    body: StyleToken,
    muted: StyleToken,
    emphasis: StyleToken,
    strong: StyleToken,
    strong_emphasis: StyleToken,
    code: StyleToken,
    code_block: StyleToken,
    code_block_keyword: StyleToken,
    code_block_string: StyleToken,
    code_block_number: StyleToken,
    code_block_comment: StyleToken,
    code_keyword: StyleToken,
    code_string: StyleToken,
    code_number: StyleToken,
    code_comment: StyleToken,
    quote: StyleToken,
    link: StyleToken,
    strikethrough: StyleToken,
    image_alt: StyleToken,
    superscript: StyleToken,
    subscript: StyleToken,
    highlight: StyleToken,
    frontmatter_key: StyleToken,
    frontmatter_value: StyleToken,
    frontmatter_cap: StyleToken,
};

pub fn palette(theme: config.Theme, syntax_theme: config.SyntaxTheme) Palette {
    return switch (theme) {
        .dark, .auto => darkPalette(syntax_theme),
        .light => lightPalette(syntax_theme),
    };
}

fn darkPalette(syntax_theme: config.SyntaxTheme) Palette {
    return switch (syntax_theme) {
        .default => .{
            .heading1 = .{ .fg_index = 81, .bold = true },
            .heading2 = .{ .fg_index = 75, .bold = true },
            .heading3 = .{ .fg_index = 74, .bold = false },
            .heading4 = .{ .fg_index = 67, .bold = false },
            .heading5 = .{ .fg_index = 66, .bold = false },
            .heading6 = .{ .fg_index = 59, .bold = false },
            .body = .{ .fg_index = 252 },
            .muted = .{ .fg_index = 244 },
            .emphasis = .{ .fg_index = 188, .italic = true },
            .strong = .{ .fg_index = 231, .bold = true },
            .strong_emphasis = .{ .fg_index = 231, .bold = true, .italic = true },
            .code = .{ .fg_index = 114 },
            .code_block = .{ .fg_index = 250, .bg_index = 236 },
            .code_block_keyword = .{ .fg_index = 141, .bold = true, .bg_index = 236 },
            .code_block_string = .{ .fg_index = 180, .bg_index = 236 },
            .code_block_number = .{ .fg_index = 216, .bg_index = 236 },
            .code_block_comment = .{ .fg_index = 243, .bg_index = 236 },
            .code_keyword = .{ .fg_index = 141, .bold = true },
            .code_string = .{ .fg_index = 180 },
            .code_number = .{ .fg_index = 216 },
            .code_comment = .{ .fg_index = 243 },
            .quote = .{ .fg_index = 109 },
            .link = .{ .fg_index = 117, .underline = true },
            .strikethrough = .{ .fg_index = 244, .strikethrough = true },
            .image_alt = .{ .fg_index = 213 },
            .superscript = .{ .fg_index = 153 },
            .subscript = .{ .fg_index = 152 },
            .highlight = .{ .fg_index = 227, .bold = true },
            .frontmatter_key = .{ .fg_index = 109, .bg_index = 236 },
            .frontmatter_value = .{ .fg_index = 250, .bg_index = 236 },
            .frontmatter_cap = .{ .fg_index = 236 },
        },
        .classic => .{
            .heading1 = .{ .fg_index = 81, .bold = true },
            .heading2 = .{ .fg_index = 75, .bold = true },
            .heading3 = .{ .fg_index = 74, .bold = false },
            .heading4 = .{ .fg_index = 67, .bold = false },
            .heading5 = .{ .fg_index = 66, .bold = false },
            .heading6 = .{ .fg_index = 59, .bold = false },
            .body = .{ .fg_index = 252 },
            .muted = .{ .fg_index = 244 },
            .emphasis = .{ .fg_index = 188, .italic = true },
            .strong = .{ .fg_index = 231, .bold = true },
            .strong_emphasis = .{ .fg_index = 231, .bold = true, .italic = true },
            .code = .{ .fg_index = 114 },
            .code_block = .{ .fg_index = 114, .bg_index = 236 },
            .code_block_keyword = .{ .fg_index = 81, .bold = true, .bg_index = 236 },
            .code_block_string = .{ .fg_index = 186, .bg_index = 236 },
            .code_block_number = .{ .fg_index = 221, .bg_index = 236 },
            .code_block_comment = .{ .fg_index = 243, .bg_index = 236 },
            .code_keyword = .{ .fg_index = 81, .bold = true },
            .code_string = .{ .fg_index = 186 },
            .code_number = .{ .fg_index = 221 },
            .code_comment = .{ .fg_index = 243 },
            .quote = .{ .fg_index = 109 },
            .link = .{ .fg_index = 117, .underline = true },
            .strikethrough = .{ .fg_index = 244, .strikethrough = true },
            .image_alt = .{ .fg_index = 213 },
            .superscript = .{ .fg_index = 153 },
            .subscript = .{ .fg_index = 152 },
            .highlight = .{ .fg_index = 227, .bold = true },
            .frontmatter_key = .{ .fg_index = 109, .bg_index = 236 },
            .frontmatter_value = .{ .fg_index = 250, .bg_index = 236 },
            .frontmatter_cap = .{ .fg_index = 236 },
        },
    };
}

fn lightPalette(syntax_theme: config.SyntaxTheme) Palette {
    return switch (syntax_theme) {
        .default => .{
            .heading1 = .{ .fg_index = 25, .bold = true },
            .heading2 = .{ .fg_index = 26, .bold = true },
            .heading3 = .{ .fg_index = 33, .bold = false },
            .heading4 = .{ .fg_index = 39, .bold = false },
            .heading5 = .{ .fg_index = 45, .bold = false },
            .heading6 = .{ .fg_index = 109, .bold = false },
            .body = .{ .fg_index = 236 },
            .muted = .{ .fg_index = 245 },
            .emphasis = .{ .fg_index = 60, .italic = true },
            .strong = .{ .fg_index = 18, .bold = true },
            .strong_emphasis = .{ .fg_index = 18, .bold = true, .italic = true },
            .code = .{ .fg_index = 28 },
            .code_block = .{ .fg_index = 239, .bg_index = 254 },
            .code_block_keyword = .{ .fg_index = 97, .bold = true, .bg_index = 254 },
            .code_block_string = .{ .fg_index = 131, .bg_index = 254 },
            .code_block_number = .{ .fg_index = 167, .bg_index = 254 },
            .code_block_comment = .{ .fg_index = 246, .bg_index = 254 },
            .code_keyword = .{ .fg_index = 97, .bold = true },
            .code_string = .{ .fg_index = 131 },
            .code_number = .{ .fg_index = 167 },
            .code_comment = .{ .fg_index = 246 },
            .quote = .{ .fg_index = 60 },
            .link = .{ .fg_index = 27, .underline = true },
            .strikethrough = .{ .fg_index = 245, .strikethrough = true },
            .image_alt = .{ .fg_index = 213 },
            .superscript = .{ .fg_index = 26 },
            .subscript = .{ .fg_index = 31 },
            .highlight = .{ .fg_index = 130, .bold = true },
            .frontmatter_key = .{ .fg_index = 60, .bg_index = 254 },
            .frontmatter_value = .{ .fg_index = 239, .bg_index = 254 },
            .frontmatter_cap = .{ .fg_index = 254 },
        },
        .classic => .{
            .heading1 = .{ .fg_index = 25, .bold = true },
            .heading2 = .{ .fg_index = 26, .bold = true },
            .heading3 = .{ .fg_index = 33, .bold = false },
            .heading4 = .{ .fg_index = 39, .bold = false },
            .heading5 = .{ .fg_index = 45, .bold = false },
            .heading6 = .{ .fg_index = 109, .bold = false },
            .body = .{ .fg_index = 236 },
            .muted = .{ .fg_index = 245 },
            .emphasis = .{ .fg_index = 60, .italic = true },
            .strong = .{ .fg_index = 18, .bold = true },
            .strong_emphasis = .{ .fg_index = 18, .bold = true, .italic = true },
            .code = .{ .fg_index = 28 },
            .code_block = .{ .fg_index = 28, .bg_index = 254 },
            .code_block_keyword = .{ .fg_index = 25, .bold = true, .bg_index = 254 },
            .code_block_string = .{ .fg_index = 94, .bg_index = 254 },
            .code_block_number = .{ .fg_index = 130, .bg_index = 254 },
            .code_block_comment = .{ .fg_index = 246, .bg_index = 254 },
            .code_keyword = .{ .fg_index = 25, .bold = true },
            .code_string = .{ .fg_index = 94 },
            .code_number = .{ .fg_index = 130 },
            .code_comment = .{ .fg_index = 246 },
            .quote = .{ .fg_index = 60 },
            .link = .{ .fg_index = 27, .underline = true },
            .strikethrough = .{ .fg_index = 245, .strikethrough = true },
            .image_alt = .{ .fg_index = 213 },
            .superscript = .{ .fg_index = 26 },
            .subscript = .{ .fg_index = 31 },
            .highlight = .{ .fg_index = 130, .bold = true },
            .frontmatter_key = .{ .fg_index = 60, .bg_index = 254 },
            .frontmatter_value = .{ .fg_index = 239, .bg_index = 254 },
            .frontmatter_cap = .{ .fg_index = 254 },
        },
    };
}

/// Maps a semantic SpanStyle to a concrete StyleToken using the given palette.
/// This is the key function that bridges semantic styles to terminal colors.
pub fn token(palette_value: Palette, style: render_model.SpanStyle) StyleToken {
    return switch (style) {
        .heading1 => palette_value.heading1,
        .heading2 => palette_value.heading2,
        .heading3 => palette_value.heading3,
        .heading4 => palette_value.heading4,
        .heading5 => palette_value.heading5,
        .heading6 => palette_value.heading6,
        .body => palette_value.body,
        .muted => palette_value.muted,
        .emphasis => palette_value.emphasis,
        .strong => palette_value.strong,
        .strong_emphasis => palette_value.strong_emphasis,
        .code => palette_value.code,
        .code_block => palette_value.code_block,
        .code_block_keyword => palette_value.code_block_keyword,
        .code_block_string => palette_value.code_block_string,
        .code_block_number => palette_value.code_block_number,
        .code_block_comment => palette_value.code_block_comment,
        .code_keyword => palette_value.code_keyword,
        .code_string => palette_value.code_string,
        .code_number => palette_value.code_number,
        .code_comment => palette_value.code_comment,
        .quote => palette_value.quote,
        .link => palette_value.link,
        .strikethrough => palette_value.strikethrough,
        .image_alt => palette_value.image_alt,
        .superscript => palette_value.superscript,
        .subscript => palette_value.subscript,
        .highlight => palette_value.highlight,
        .frontmatter_key => palette_value.frontmatter_key,
        .frontmatter_value => palette_value.frontmatter_value,
        .frontmatter_cap => palette_value.frontmatter_cap,
    };
}

/// Styling for the copy-confirmation toast: a soft panel with a subtle green
/// rounded border and readable text, tuned per light/dark mode so it reads as a
/// gentle confirmation rather than a harsh reverse-video block.
pub const ToastStyle = struct {
    fill: vaxis.Style,
    border: vaxis.Style,
    text: vaxis.Style,
};

pub fn toastStyle(theme: config.Theme) ToastStyle {
    // Track the theme's own panel (code-block background) and body text so the
    // toast stays in sync with the palette; only the green accent is bespoke.
    const active = palette(theme, .default);
    const bg: vaxis.Color = if (active.code_block.bg_index) |index| .{ .index = index } else .default;
    const accent: u8 = switch (theme) {
        .light => 65,
        .dark, .auto => 108,
    };
    return .{
        .fill = .{ .bg = bg },
        .border = .{ .fg = .{ .index = accent }, .bg = bg },
        .text = .{ .fg = .{ .index = active.body.fg_index }, .bg = bg, .bold = true },
    };
}

/// Styling for the TUI metadata overlay (front matter panel toggled with
/// `m`): the same soft panel as the toast but with a neutral blue accent so
/// it reads as reference information, not a confirmation.
pub fn metadataPanelStyle(theme: config.Theme) ToastStyle {
    const active = palette(theme, .default);
    const bg: vaxis.Color = if (active.code_block.bg_index) |index| .{ .index = index } else .default;
    const accent: u8 = switch (theme) {
        .light => 25,
        .dark, .auto => 67,
    };
    return .{
        .fill = .{ .bg = bg },
        .border = .{ .fg = .{ .index = accent }, .bg = bg },
        .text = .{ .fg = .{ .index = active.body.fg_index }, .bg = bg },
    };
}

/// Converts a StyleToken to vaxis.Style for TUI rendering.
/// The CLI equivalent is ansi.writeTokenStyled() which emits ANSI escape codes.
pub fn vaxisStyle(token_value: StyleToken) vaxis.Style {
    return .{
        .fg = .{ .index = token_value.fg_index },
        .bg = if (token_value.bg_index) |bg| .{ .index = bg } else .default,
        .bold = token_value.bold,
        .italic = token_value.italic,
        .strikethrough = token_value.strikethrough,
        .ul_style = if (token_value.underline) .single else .off,
    };
}
