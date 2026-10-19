Output ../assets/demo-hero.gif
Output ../assets/demo-hero.mp4

Set Shell bash
Set FontSize 20
Set Width 900
Set Height 900
Set Padding 24
Set Theme "Dracula"
Set TypingSpeed 50ms
Set Framerate 15

Hide
Type "export PATH=$PWD/../../zig-out/bin:$PATH PS1='$ ' EDITOR='vim -u NONE -N' && rm -rf /tmp/mercat-hero && mkdir /tmp/mercat-hero && cp demo.md flow.mmd guide.md /tmp/mercat-hero/ && cd /tmp/mercat-hero && clear"
Enter
Sleep 500ms
Show

# Scene 1: CLI markdown
Type "mercat demo.md"
Sleep 300ms
Enter
Sleep 3s

# Scene 2: CLI mermaid from a pipe
Type "clear"
Enter
Type "cat flow.mmd | mercat"
Sleep 300ms
Enter
Sleep 3s

# Scene 3: TUI, scroll, edit, reload
Type "clear"
Enter
Type "mercat -t guide.md"
Sleep 300ms
Enter
Sleep 1.5s
Type@70ms "jjjjjjjjjjjjjjjjjjjjjjjj"
Sleep 2s
Type "e"
Sleep 1s
Type "/Send receipt"
Enter
Sleep 500ms
Type "o"
Type@80ms "  F --> G[Ship package]"
Escape
Sleep 500ms
Type ":wq"
Sleep 300ms
Enter
Sleep 3s
Type "q"
Sleep 300ms
