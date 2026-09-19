pub fn codepointWidth(cp: u21) u32 {
    return if (cp >= 0x1100) 2 else 1;
}
