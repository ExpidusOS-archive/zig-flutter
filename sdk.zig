const std = @import("std");
const Build = std.Build;
const Sdk = @This();

pub const Options = struct {
  builder: *Build,
  gn_args: ?[][]const u8 = null,
  target: std.zig.CrossTarget,
  optimize: std.builtin.OptimizeMode,
  global_cache: bool = false,
};

build: *Build,
options: Options,
gclient_step: Build.Step,
gclient_generated: Build.GeneratedFile,
source_step: Build.Step,
source_generated: Build.GeneratedFile,
generated: Build.GeneratedFile,
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
    \\
  );

  if (self.options.target.getCpu().arch.isWasm()) {
    try output.appendSlice(
      \\    "custom_vars": {
      \\      "download_emsdk": True,
      \\     },
      \\
    );
  }

  try output.appendSlice(
    \\  },
    \\]
  );

  man.hash.addBytes(output.items);
  if (try step.cacheHit(&man)) {
    const digest = man.final();
    const sub_path = try self.getCacheDir().join(b.allocator, &.{
      "o", &digest, "gclient",
    });

    self.gclient_generated.path = sub_path;
    return;
  }

  const digest = man.final();
  const sub_path = try std.fs.path.join(b.allocator, &.{ "o", &digest, "gclient" });
  const sub_path_dirname = std.fs.path.dirname(sub_path).?;

  self.getCacheDir().handle.makePath(sub_path_dirname) catch |err| {
    return step.fail("unable to make path '{}{s}': {s}", .{
      self.getCacheDir(), sub_path_dirname, @errorName(err),
    });
  };

  self.getCacheDir().handle.writeFile(sub_path, output.items) catch |err| {
    return step.fail("unable to write file '{}{s}': {s}", .{
      self.getCacheDir(), sub_path, @errorName(err),
    });
  };

  self.gclient_generated.path = try self.getCacheDir().join(b.allocator, &.{ sub_path });
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
  man.hash.addBytes(try self.options.target.zigTriple(b.allocator));
  man.hash.addBytes("-");
  man.hash.addBytes(switch (self.options.optimize) {
    .Debug => "debug",
    .ReleaseSafe => "release-safe",
    .ReleaseFast => "release-fast",
    .ReleaseSmall => "release-small",
  });
  man.hash.addBytes("-");
  man.hash.addBytes(self.gclient_generated.getPath());

  if (try step.cacheHit(&man)) {
    const digest = man.final();
    const sub_path = try self.getCacheDir().join(b.allocator, &.{
      "o", &digest,
    });

    self.source_generated.path = sub_path;
    return;
  }

  const digest = man.final();
  const sub_path = try std.fs.path.join(b.allocator, &.{ "o", &digest });

  self.getCacheDir().handle.makePath(sub_path) catch |err| {
    return step.fail("unable to make path '{}{s}': {s}", .{
      self.getCacheDir(), sub_path, @errorName(err),
    });
  };

  const gclient_in = try std.fs.openFileAbsolute(self.gclient_generated.getPath(), .{});
  defer gclient_in.close();

  const gclient = try b.allocator.alloc(u8, (try gclient_in.metadata()).size());
  defer b.allocator.free(gclient);
  _ = try gclient_in.readAll(gclient);

  self.getCacheDir().handle.writeFile(try std.fs.path.join(b.allocator, &.{ sub_path, ".gclient" }), gclient) catch |err| {
    return step.fail("unable to write file '{}{s}/.gclient': {s}", .{
      self.getCacheDir(), sub_path, @errorName(err),
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

  child.cwd = try self.getCacheDir().join(b.allocator, &.{ sub_path });

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

  self.source_generated.path = child.cwd;
  try man.writeManifest();
}

fn make(step: *Build.Step, _: *std.Progress.Node) !void {
  const self = @fieldParentPtr(Sdk, "step", step);
  const b = step.owner;

  var man = b.cache.obtain();
  defer man.deinit();

  var args = std.ArrayList([]const u8).init(b.allocator);
  defer args.deinit();

  try args.append(getPath("/src/depot_tools/vpython3"));
  try args.append(try std.fs.path.join(b.allocator, &.{
    self.source_generated.getPath(),
    "src", "flutter", "tools",
    "gn"
  }));

  try args.append("--no-goma");
  try args.append("--no-prebuilt-dart-sdk");

  try args.append("--depot-tools");
  try args.append(getPath("/src/depot_tools"));

  const debug_flag = switch (self.options.optimize) {
    .Debug => "debug",
    .ReleaseSafe => "profile",
    .ReleaseFast => "jit_release",
    .ReleaseSmall => "release",
  };

  try args.append("--runtime-mode");
  try args.append(debug_flag);

  if (self.options.target.getCpuArch().isWasm()) try args.append("--web");

  const target_flag = if (self.options.target.getAbi() == .android) "android"
    else if (self.options.target.getCpuArch().isWasm()) "wasm"
    else switch (self.options.target.getOsTag()) {
      .fuchsia => "fuchsia",
      .linux => "linux",
      .macos => "mac",
      .ios => "ios",
      .windows => "win",
      else => return step.fail("target {s} is not supported", .{ try self.options.target.zigTriple(b.allocator) }),
    };

  try args.append("--target-os");
  try args.append(target_flag);

  const cpu_flag = switch (self.options.target.getCpuArch()) {
    .arm, .armeb => "arm",
    .aarch64, .aarch64_be, .aarch64_32 => "aarch64",
    .x86 => "x86",
    .x86_64 => "x64",
    .wasm32, .wasm64 => null,
    else => return step.fail("target {s} is not supported", .{ try self.options.target.zigTriple(b.allocator) }),
  };

  if (cpu_flag) |value| {
    try args.append(b.fmt("--{s}-cpu", .{ target_flag }));
    try args.append(value);
  }

  try args.append("--target-triple");
  try args.append(try self.options.target.linuxTriple(b.allocator));

  if (self.build.sysroot) |sysroot| {
    try args.append("--target-sysroot");
    try args.append(sysroot);
  }

  man.hash.addBytes("flutter-source-");
  man.hash.addBytes(self.source_generated.getPath());

  if (self.options.gn_args) |arr| {
    for (arr) |item| try args.append(item);
  }

  for (args.items) |item| man.hash.addBytes(item);

  if (try step.cacheHit(&man)) {
    const digest = man.final();
    const sub_path = try self.getCacheDir().join(b.allocator, &.{
      "o", &digest,
    });

    self.generated.path = sub_path;
    return;
  }

  const digest = man.final();
  const sub_path = try self.getCacheDir().join(b.allocator, &.{
    "o", &digest,
  });

  self.getCacheDir().handle.makePath(sub_path) catch |err| {
    return step.fail("unable to make path '{}{s}': {s}", .{
      self.getCacheDir(), sub_path, @errorName(err),
    });
  };

  self.generated.path = sub_path;

  try args.append("--out-dir");
  try args.append(sub_path);

  for (args.items, 0..) |item, i| {
    if (args.items.len == i + 1) std.debug.print("{s}\n", .{ item })
    else std.debug.print("{s} ", .{ item });
  }

  var env_map = std.process.EnvMap.init(b.allocator);

  var child = std.ChildProcess.init(args.items, b.allocator);
  child.stdin_behavior = .Ignore;
  child.stdout_behavior = .Inherit;
  child.stderr_behavior = .Inherit;
  child.cwd = sub_path;
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

  try child.spawn();

  var term = try child.wait();
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

  const ninja = try b.findProgram(&.{
    "ninja",
  }, &.{});

  child = std.ChildProcess.init(&.{
    ninja,
    "-C",
    try std.fs.path.join(b.allocator, &.{
      sub_path,
      "out",
      b.fmt("{s}_{s}", .{ target_flag, debug_flag }),
    }),
  }, b.allocator);
  child.stdin_behavior = .Ignore;
  child.stdout_behavior = .Inherit;
  child.stderr_behavior = .Inherit;
  child.cwd = sub_path;
  child.env_map = &env_map;

  try child.spawn();

  term = try child.wait();
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

  try man.writeManifest();
}

fn getCacheDir(self: *Sdk) *Build.Cache.Directory {
  return if (self.options.global_cache) &self.build.global_cache_root
    else &self.build.cache_root;
}

pub fn new(options: Options) !*Sdk {
  const self = try options.builder.allocator.create(Sdk);
  self.* = .{
    .build = options.builder,
    .options = options,
    .gclient_step = Build.Step.init(.{
      .id = .custom,
      .name = "Generate gclient",
      .owner = options.builder,
      .makeFn = gclient_make,
    }),
    .gclient_generated = .{
      .step = &self.gclient_step,
    },
    .source_step = Build.Step.init(.{
      .id = .custom,
      .name = "gclient sync",
      .owner = options.builder,
      .makeFn = source_make,
    }),
    .source_generated = .{
      .step = &self.source_step,
    },
    .step = Build.Step.init(.{
      .id = .custom,
      .name = "Flutter Engine",
      .owner = options.builder,
      .makeFn = make,
    }),
    .generated = .{
      .step = &self.step,
    },
  };

  self.source_step.dependOn(&self.gclient_step);
  self.step.dependOn(&self.source_step);
  return self;
}
