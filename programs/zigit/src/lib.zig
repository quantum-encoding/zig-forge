// Zigit library root. Re-exports the modules that the CLI and any
// future embedders use. Tests for every sub-module are pulled in
// here so `zig build test` runs the whole suite.

pub const object = @import("object/mod.zig");
pub const index = @import("index/mod.zig");
pub const refs = @import("refs/mod.zig");
pub const config = @import("config.zig");
pub const repo = @import("repo.zig");
pub const workdir = @import("workdir.zig");
pub const worktree = @import("worktree.zig");
pub const diff = @import("diff/mod.zig");

pub const Oid = object.Oid;
pub const Kind = object.Kind;
pub const LooseStore = object.LooseStore;
pub const Repository = repo.Repository;
pub const Index = index.Index;

test {
    _ = object;
    _ = index;
    _ = refs;
    _ = config;
    _ = repo;
    _ = workdir;
    _ = worktree;
    _ = diff;
}
