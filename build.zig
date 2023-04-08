const std = @import("std");
const Build = std.Build;
const Sdk = @import("sdk.zig");

pub fn build(b: *Build) !void {
  const target = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});

  const sdk = try Sdk.new(.{
    .builder = b,
    .target = target,
    .optimize = optimize,
  });

  sdk.gclient_generated.path = b.option([]const u8, "gclient", "Override the gclient file");
  sdk.source_generated.path = b.option([]const u8, "source", "Override the source code pull path");

  const gclient_step = b.step("gclient", "Generate gclient file & install it");
  gclient_step.dependOn(&sdk.gclient_step);

  const gclient_install = b.addInstallFile(.{
    .generated = &sdk.gclient_generated
  }, ".gclient");
  gclient_step.dependOn(&gclient_install.step);

  const source_step = b.step("source", "Download source & install it");
  source_step.dependOn(&sdk.source_step);

  const source_install = sdk.addInstallSourceStep("src");
  source_step.dependOn(&source_install.step);

  b.default_step.dependOn(&sdk.step);
  sdk.install();
}
