// 3-line fixture for the zig2asm end-to-end smoke test.
// `export` keeps the symbol alive so it appears in both .s and .ll output.
export fn add(a: i32, b: i32) i32 {
    return a + b;
}
