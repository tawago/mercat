koino vendoring pin
===================

Source repository : https://github.com/kivikakk/koino
Pinned commit     : 0f10363e02ff575b008f219e54dc30ef8fad55db
Package hash      : koino-0.1.0-S9LuWkK-AgAjKVVFM7QfdiGiab87w3H9iSJJLI0ynuHr
License           : MIT (LICENSE in this directory)

The tree is the upstream package at the pinned commit, unmodified except for
the local patches listed below. koino's own dependencies (libpcre.zig,
htmlentities.zig, uucode, clap) are still fetched by hash through
vendor/koino/build.zig.zon.

Local patches
-------------

1. src/inlines.zig, `Subject.processEmphasis`: stop before the stack bottom.

   When a link closes, koino processes emphasis above the delimiter that was
   on top of the stack when `[` was seen. If the link text holds no delimiter,
   the backwards walk stopped on that bottom delimiter itself and processed
   it; finding no opener above the bottom, it was removed. The closing
   delimiter of emphasis directly before a link was lost, so
   `**bold** [link](u)` rendered a literal `**bold**`. cmark processes
   nothing in that case; the patch matches it.

   Regression tests: src/core/markdown/parser_test.zig ("emphasis before a
   link").

To update: replace this tree with the new upstream package, re-apply the
patches above (drop any that upstream has fixed), and update this file.
