pub const SwayMessages = @import("sway-messages.zig");

pub const Payload = enum(u32) {
    RUN_COMMAND = 0, // Runs the payload as sway commands
    GET_WORKSPACES = 1, // Get the list of current workspaces
    SUBSCRIBE = 2, // Subscribe the IPC connection to the events listed in the payload
    GET_OUTPUTS = 3, // Get the list of current outputs
    GET_TREE = 4, // Get the node layout tree
    GET_MARKS = 5, // Get the names of all athe marks currently set
    GET_BAR_CONFIG = 6, // Get the specified bar config or a list of bar config names
    GET_VERSION = 7, // Get the version of sway that owns the IPC socket
    GET_BINDING_MODES = 8, // Get the list of binding mode names
    GET_CONFIG = 9, // Returns the config that was last loaded
    SEND_TICK = 10, // Sends a tick event with the specified payload
    SYNC = 11, // Replies failure object for i3 compatibility
    GET_BINDING_STATE = 12, // Request the current binding state, e.g. the currently active binding mode name.
    GET_INPUTS = 100, // Get the list of input devices
    GET_SEATS = 101, // Get the list of seats

    _,
    pub fn fromInt(i: u32) Payload {
        _ = i;
        return .RUN_COMMAND;
    }
};

const Subscribe = Message{
    .header = .{
        .length = 10,
        .payload_type = .SUBSCRIBE,
    },
    .data = "[\"window\"]",
};

pub const Message = struct {
    header: Header = .{},
    data: []const u8,

    pub const Header = struct {
        magic: []const u8 = "i3-ipc",
        length: u32 = 0,
        payload_type: Payload = undefined,
    };

    pub fn raze(m: Message, a: Allocator) void {
        a.free(m.data);
    }

    pub fn read(a: Allocator, r: *Reader) !Message {
        var m = Message{ .data = undefined };
        _ = try r.discard(.limited(6)); // we just assume it's the magic bytes
        errdefer r.tossBuffered();
        m.header = .{
            .length = try r.takeInt(u32, .little),
            .payload_type = try r.takeEnumNonexhaustive(Payload, .little),
        };
        // TODO specify a better max size
        if (m.header.length == 0 or m.header.length > 0x2ffff) unreachable;
        m.data = try r.readAlloc(a, m.header.length);
        std.debug.assert(m.header.length == m.data.len);
        return m;
    }

    pub fn send(m: Message, w: *Writer) !void {
        std.debug.assert(m.header.length == m.data.len);
        try w.writeAll(m.header.magic);
        try w.writeInt(u32, m.header.length, .little);
        try w.writeInt(u32, @intFromEnum(m.header.payload_type), .little);
        try w.writeAll(m.data);
    }

    /// Leaks if you don't use an gc'd allocator
    pub fn toStruct(m: Message, a: Allocator) !SwayMessages.MsgKind {
        const thing = try std.json.parseFromSlice(SwayMessages.WindowChange, a, m.data, .{
            .ignore_unknown_fields = true,
        });
        return .{ .window = thing.value };
    }
};

pub fn getSockPath(buffer: []u8, io: std.Io) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sway", "--get-socketpath" },
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    });

    var stdout: Writer = .fixed(buffer);
    defer if (child.stdout) |out| out.close(io);
    var outr = child.stdout.?.reader(io, &.{});
    // We just assume the prefix doesn't change
    while (outr.interface.stream(&stdout, .limited(256))) |_| {
        // continue until we hit EOS
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    _ = try child.wait(io);

    return std.mem.trim(u8, stdout.buffered(), " \n\t");
}

pub const Connection = struct {
    alloc: Allocator,
    stream: ?std.Io.net.Stream = null,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    socket_path: ?[]const u8 = null,

    pub fn init(a: Allocator, io: std.Io) !Connection {
        var b: [256]u8 = undefined;
        const path = try a.dupe(u8, try getSockPath(&b, io));
        errdefer a.free(path);
        const stream = try (try std.Io.net.UnixAddress.init(path)).connect(io);
        return .{
            .alloc = a,
            .socket_path = path,
            .stream = stream,
            .reader = stream.reader(io, try a.alloc(u8, 2048)),
            .writer = stream.writer(io, try a.alloc(u8, 2048)),
        };
    }

    pub fn raze(c: *Connection, io: std.Io) void {
        if (c.socket_path) |path| c.alloc.free(path);
        c.socket_path = null;
        if (c.stream) |stream| {
            stream.close(io);
            c.alloc.free(c.reader.interface.buffer);
            c.alloc.free(c.writer.interface.buffer);
        }
    }

    pub fn subscribe(c: *Connection) !void {
        try Subscribe.send(&c.writer.interface);
        try c.writer.interface.flush();
    }

    pub fn loop(c: *Connection) !Message {
        return try Message.read(c.alloc, &c.reader.interface);
    }
};

test "sway get socketpath" {
    //const a = std.testing.allocator;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sway", "--get-socketpath" },
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    });
    defer if (child.stdout) |out| out.close(io);

    var buffer: [0x8000]u8 = undefined;
    var w: Writer = .fixed(&buffer);

    var stdout = child.stdout.?.reader(io, &.{});
    _ = try stdout.interface.stream(&w, .unlimited);

    const out = try child.wait(io);
    _ = out;
    std.debug.print("sway socket path {s}\n", .{stdout.interface.buffered()});
}

test "sending" {
    var buf: [0xff]u8 = undefined;

    var w: std.Io.Writer = .fixed(&buf);
    const m = Subscribe;

    try w.writeAll(m.header.magic);
    try w.writeInt(u32, m.header.length, .little);
    try w.writeInt(u32, @intFromEnum(m.header.payload_type), .little);
    try w.writeAll(m.data);
}

test "waiting" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var sway = try Connection.init(a, io);
    defer sway.raze(io);
    try sway.subscribe();
    try (std.Io.Clock.Duration{ .clock = .real, .raw = .fromMilliseconds(1) }).sleep(io);
    for (0..3) |_| {
        const msg = try sway.loop();
        defer msg.raze(a);
        try (std.Io.Clock.Duration{ .clock = .real, .raw = .fromMilliseconds(1) }).sleep(io);
        const thing = std.json.parseFromSlice(
            SwayMessages.WindowChange,
            a,
            msg.data,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.print("error {}\n", .{err});
            std.debug.print("msg {s}\n", .{msg.data});
            continue;
        };
        //std.debug.print("value {}\n", .{thing.value});
        //std.debug.print("marks {s}\n", .{thing.value.container.marks});
        if (thing.value.container.marks.len > 0) {
            try std.testing.expectEqualStrings("test", thing.value.container.marks[0]);
        }
        defer thing.deinit();
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
