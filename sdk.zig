const std = @import("std");
const Build = std.Build;
const Sdk = @This();

build: *Build,
target: std.zig.CrossTarget,
optimize: std.builtin.OptimizeMode,
gclient_step: Build.Step,
gclient_generated: Build.GeneratedFile,
source_step: Build.Step,
source_generated: Build.GeneratedFile,
step: Build.Step,

fn getPath(comptime suffix: []const u8) []const u8 {
  if (suffix[0] != '/') @compileError("path requires an absolute path!");
  return comptime blk: {
    const root_dir = std.fs.path.dirname(@src().file) orelse ".";
    break :blk root_dir ++ suffix;
  };
}

fn gclient_make(step: *Build.Step, _: *std.Progress.Node) !void {
  const self = @fieldParentPtr(Sdk, "gclient_step", step);
  const b = step.owner;

  var man = b.cache.obtain();
  defer man.deinit();

  var output = std.ArrayList(u8).init(b.allocator);
  defer output.deinit();

  try output.appendSlice(
    \\solutions = [
    \\  {
    \\    "managed": False,
    \\    "name": "src
  );
  
  try output.appendSlice(std.fs.path.sep_str);

  if (std.mem.eql(u8, std.fs.path.sep_str, "\\")) {
    try output.appendSlice(std.fs.path.sep_str);
  }

  try output.appendSlice(
    \\flutter",
    \\    "url": "file://
  );

  try output.appendSlice(getPath("/src/flutter"));
  try output.appendSlice("\",\n");

  try output.appendSlice(
    \\    "custom_deps": {},
    \\    "deps_file": "DEPS",
    \\    "safesync_url": "",
    \\  },
    \\
  );

  if (self.target.getCpu().arch.isWasm()) {
    try output.appendSlice(
      \\  {
      \\    "custom_vars": {
      \\      "download_emsdk": True,
      \\     },
      \\  },
      \\
    );
  }

  try output.appendSlice(
    \\]
  );

  man.hash.addBytes(output.items);
  if (try step.cacheHit(&man)) {
    const digest = man.final();
    const sub_path = try b.cache_root.join(b.allocator, &.{
      "o", &digest, "gclient",
    });

    self.gclient_generated.path = sub_path;
    return;
  }

  const digest = man.final();
  const sub_path = try std.fs.path.join(b.allocator, &.{ "o", &digest, "gclient" });
  const sub_path_dirname = std.fs.path.dirname(sub_path).?;

  b.cache_root.handle.makePath(sub_path_dirname) catch |err| {
    return step.fail("unable to make path '{}{s}': {s}", .{
      b.cache_root, sub_path_dirname, @errorName(err),
    });
  };

  b.cache_root.handle.writeFile(sub_path, output.items) catch |err| {
    return step.fail("unable to write file '{}{s}': {s}", .{
      b.cache_root, sub_path, @errorName(err),
    });
  };

  self.gclient_generated.path = try b.cache_root.join(b.allocator, &.{ sub_path });
  try man.writeManifest();
}

fn source_make(step: *Build.Step, _: *std.Progress.Node) !void {
  const self = @fieldParentPtr(Sdk, "source_step", step);
  const b = step.owner;

  var man = b.cache.obtain();
  defer man.deinit();

  var output = std.ArrayList(u8).init(b.allocator);
  defer output.deinit();

  // TODO: use temp dir to find the hash
  man.hash.addBytes("flutter-source-");
  man.hash.addBytes(try self.target.zigTriple(b.allocator));
  man.hash.addBytes("-");
  man.hash.addBytes(switch (self.optimize) {
    .Debug => "debug",
    .ReleaseSafe => "release-safe",
    .ReleaseFast => "release-fast",
    .ReleaseSmall => "release-small",
  });
  man.hash.addBytes("-");
  man.hash.addBytes(self.gclient_generated.getPath());

  if (try step.cacheHit(&man)) {
    const digest = man.final();
    const sub_path = try b.cache_root.join(b.allocator, &.{
      "o", &digest,
    });

    self.source_generated.path = sub_path;
    return;
  }

  const digest = man.final();
  const sub_path = try std.fs.path.join(b.allocator, &.{ "o", &digest });

  b.cache_root.handle.makePath(sub_path) catch |err| {
    return step.fail("unable to make path '{}{s}': {s}", .{
      b.cache_root, sub_path, @errorName(err),
    });
  };

  const gclient_in = try std.fs.openFileAbsolute(self.gclient_generated.getPath(), .{});
  defer gclient_in.close();

  const gclient = try b.allocator.alloc(u8, (try gclient_in.metadata()).size());
  defer b.allocator.free(gclient);
  _ = try gclient_in.readAll(gclient);

  b.cache_root.handle.writeFile(try std.fs.path.join(b.allocator, &.{ sub_path, ".gclient" }), gclient) catch |err| {
    return step.fail("unable to write file '{}{s}/.gclient': {s}", .{
      b.cache_root, sub_path, @errorName(err),
    });
  };

  const python3 = b.findProgram(&.{
    "python3",
    "python",
  }, &.{}) catch null;

  var args = std.ArrayList([]const u8).init(b.allocator);
  defer args.deinit();

  if (python3) |path| {
    try args.append(path);
    try args.append(getPath("/src/depot_tools/gclient.py"));
  } else {
    try args.append(getPath("/src/depot_tools/gclient"));
  }

  try args.append("sync");

  var env_map = std.process.EnvMap.init(b.allocator);

  var child = std.ChildProcess.init(args.items, b.allocator);
  child.stdin_behavior = .Ignore;
  child.stdout_behavior = .Pipe;
  child.stderr_behavior = .Inherit;
  child.env_map = &env_map;

  const hostenv = try std.process.getEnvMap(b.allocator);

  var env_iter = hostenv.iterator();
  while (env_iter.next()) |item| {
    if (std.mem.eql(u8, item.key_ptr.*, "PATH")) {
      try env_map.put(item.key_ptr.*, try std.mem.join(b.allocator, ":", &.{
        getPath("/src/depot_tools"),
        item.value_ptr.*
      }));
    } else {
      try env_map.put(item.key_ptr.*, item.value_ptr.*);
    }
  }

  if (env_map.get("PATH")) |path| {
    try env_map.put("PATH", try std.mem.join(b.allocator, ":", &.{
      getPath("/src/depot_tools"),
      path
    }));
  }

  child.cwd = try b.cache_root.join(b.allocator, &.{ sub_path });

  try child.spawn();

  const term = try child.wait();
  switch (term) {
    .Exited => |code| {
      if (code != 0) {
        return step.fail("process exited with code {}", .{
          code
        });
      }
    },
    .Signal, .Stopped, .Unknown => |code| {
      return step.fail("process was terminated {}", .{
        code
      });
    }
  }

  self.gclient_generated.path = child.cwd;
  try man.writeManifest();
}

pub fn new(b: *Build, target: std.zig.CrossTarget, optimize: std.builtin.OptimizeMode) !*Sdk {
  const self = try b.allocator.create(Sdk);
  self.* = .{
    .build = b,
    .target = target,
    .optimize = optimize,
    .gclient_step = Build.Step.init(.{
      .id = .custom,
      .name = "Generate gclient",
      .owner = b,
      .makeFn = gclient_make,
    }),
    .gclient_generated = .{
      .step = &self.gclient_step,
    },
    .source_step = Build.Step.init(.{
      .id = .custom,
      .name = "gclient sync",
      .owner = b,
      .makeFn = source_make,
    }),
    .source_generated = .{
      .step = &self.source_step,
    },
    .step = Build.Step.init(.{
      .id = .custom,
      .name = "Flutter Engine",
      .owner = b,
    }),
  };

  self.source_step.dependOn(&self.gclient_step);
  self.step.dependOn(&self.source_step);
  return self;
}
