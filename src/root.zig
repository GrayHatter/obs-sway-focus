pub const module_defaults: obs.ModuleInfo = .{
    .name = "obs_sway_focus",
    .version = "0.0.1",
    .author = "grayhatter",
    .description = "tracks focus of sway windows",

    .on_load_fn = on_load,
    .on_unload_fn = on_unload,
};

comptime {
    obs.includeExports();
}

var arena: std.heap.ArenaAllocator = undefined;
var alloc: Allocator = undefined;
var io: std.Io = undefined;
var running = true;
var threads: [1]std.Thread = undefined;

var last: i64 = 0;
var on_build = false;

fn requestBuild() void {
    //std.debug.print("request build\n", .{});
    if (!on_build) obs.Scene.swapPreview();
    on_build = true;
    last = std.Io.Clock.awake.now(io).toMilliseconds();
}

fn requestCode() void {
    //std.debug.print("request code\n", .{});
    if (last < std.Io.Clock.awake.now(io).toMilliseconds() and on_build) {
        obs.Scene.swapPreview();
    }
    on_build = false;
    last = std.Io.Clock.awake.now(io).toMilliseconds();
}

fn watchSway(_: ?*anyopaque) void {
    obs.log("sway thread running");
    std.debug.print("sway thread running\n", .{});
    var sway = sway_ipc.Connection.init(alloc, io) catch |err| {
        obs.logFmt("connection error {}", .{err});
        return;
    };
    sway.subscribe() catch {
        obs.log("crash trying to subscribe");
        unreachable;
    };
    io.sleep(.fromSeconds(10), .awake) catch return;
    obs.Scene.findScenes();
    while (running) {
        const msg = sway.loop() catch {
            obs.log("unexpected read error");
            unreachable;
        };

        io.sleep(.fromMilliseconds(10), .awake) catch return;
        switch (msg.toStruct(alloc) catch {
            obs.log("unable to build struct");
            continue;
        }) {
            .window => |w| {
                for (w.container.marks) |mark| {
                    if (std.mem.eql(u8, mark, "build")) {
                        //std.debug.print("found {}\n", .{w.container});
                        requestBuild();
                        break;
                    }
                } else {
                    requestCode();
                }
            },
        }
    }
    obs.log("sway-focus thread exit");
}

var threaded: std.Io.Threaded = .init_single_threaded;

fn on_load() bool {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    alloc = arena.allocator();
    io = threaded.io();
    threads[0] = std.Thread.spawn(.{}, watchSway, .{null}) catch unreachable;

    if (!obs.QtShim.newDock("Sway Focus")) {
        obs.log("Unable to create dock");
    }
    return true;
}

fn on_unload() void {
    running = false;
    std.Thread.join(threads[0]);
    arena.deinit();
}

test {
    //_ = &std.testing.refAllDecls(@This());
    _ = &sway_ipc;
}

comptime {
    _ = &on_load;
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const sway_ipc = @import("sway-ipc.zig");
const obs = @import("OBS");
