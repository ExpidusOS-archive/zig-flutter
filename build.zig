const std = @import("std");
const Build = std.Build;
const Sdk = @import("sdk.zig");

pub fn build(b: *Build) !void {
  const target = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});

  const sdk = try Sdk.new(b, target, optimize);
  b.default_step.dependOn(&sdk.step);
}
