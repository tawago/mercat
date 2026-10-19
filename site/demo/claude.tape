# Demo of the mercat Claude Code mod: a real `claude` session draws a mermaid reply,
# then `/mercat off` flips it to the raw mermaid block and `/mercat on` back.
#
# Setup, once: an empty project that loads the mod from this checkout.
#
#   mkdir -p /tmp/mercat-demo/.claude
#   echo '{"enabledPlugins":{"mercat@mercat":false}}' > /tmp/mercat-demo/.claude/settings.json
#   (cd /tmp/mercat-demo && claude)   # answer the folder-trust prompt, then quit
#
# Record from the repo root (after `zig build`, logged in to claude):
#
#   vhs site/demo/claude.tape
#
# Then crop the session header (Claude Code's welcome lines) off the top and
# write the published files. If a take shows the usage-limit notice above the
# input box, blank its row for those frames first, e.g. prepend
# drawbox=x=0:y=<row px>:w=iw:h=21:color=0x1e1e2e:t=fill:enable='between(t,<a>,<b>)'
# to the -vf chain (rows and times differ per take).
#
#   CROP=150
#   ffmpeg -y -i /tmp/demo-claude-raw.mp4 -an -vf "crop=iw:ih-$CROP:0:$CROP" site/assets/demo-claude.mp4
#   ffmpeg -y -i site/assets/demo-claude.mp4 -vf "fps=12,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=none" site/assets/demo-claude.gif

Output "/tmp/demo-claude-raw.mp4"

Set Shell bash
Set FontSize 16
Set Width 1240
Set Height 1160
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 30ms
Set Framerate 24

Hide
Type `export REPO=$PWD PS1='$ '; cd /tmp/mercat-demo`
Enter
Type `clear; env -i HOME="$HOME" USER="$USER" CLAUDE_CONFIG_DIR="$HOME/.claude" LANG=en_US.UTF-8 TERM=xterm-256color CLAUDE_CODE_NO_FLICKER=1 PATH="$REPO/zig-out/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin" claude --no-chrome --strict-mcp-config --setting-sources project --plugin-dir "$REPO/mods/mercat"`
Enter
Sleep 8s
Show

Sleep 300ms
Set TypingSpeed 12ms
Type "Draw our login flow as a mermaid flowchart: user enters password, check it, if wrong retry, if right load the dashboard"
Sleep 400ms
Enter
Sleep 300ms

Hide
Sleep 45s
Show

Sleep 3s
Set TypingSpeed 40ms
Type "/mercat off"
Sleep 300ms
Enter
Sleep 1800ms
Type "/mercat on"
Sleep 300ms
Enter
Sleep 3s
