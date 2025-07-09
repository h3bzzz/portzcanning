const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const process = std.process;
const Thread = std.Thread;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

// std.net.getAddressList is the high-level function for resolution
// check std.net.getAddressList docs

const MAX_THREADS = 1000;
const TIMEOUT_MS = 1000;

const ErrorTypes = error{
    InvalidArgument,
    MissingArgument,
    InvalidPortRange,
    WouldBlock,
    ConnectionRefused,
};

const common_ports = [_]u16{
    20, 21, 22, 23, 53, 67, 68, 69, 80, 88, 110, 123, 135, 137, 138, 139,
    143, 161, 162, 179, 194, 389, 443, 445, 464, 514, 515, 587, 636, 993, 995,
    1433, 1434, 1521, 1723, 2049, 2083, 3128, 3306, 3268, 3269, 3389, 5432,
    5900, 5985, 5986, 6379, 8080, 8443, 9090, 9200, 9389, 10000, 27017, 49443,
};

const Options = struct {
    targets: ArrayList([]const u8),
    ports: ArrayList([]const u8),
    timeout_ms: u32 = TIMEOUT_MS,
    max_threads: u32 = MAX_THREADS,
    allocator: Allocator,

    fn init(allocator: Allocator) Options {
        return .{
            .targets = ArrayList([]const u8).init(allocator),
            .ports = ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Options) void {
        for (self.targets.items) |target| {
            self.allocator.free(target);
        }
        self.targets.deinit();

        for (self.ports.items) |port| {
            self.allocator.free(port);
        }
        self.ports.deinit();
    }
};

// New struct to hold our results
const ScanResult = struct {
    address: net.Address,
    port: u16,
};

fn parseArgs(allocator: Allocator) !Options {
    var options = Options.init(allocator);
    errdefer options.deinit();

    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    var expecting_target = false;
    var expecting_port = false;

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "-t")) {
            expecting_target = true;
            expecting_port = false;
        } else if (mem.eql(u8, arg, "-p")) {
            expecting_port = true;
            expecting_target = false;
        } else if (expecting_target) {
            const target_copy = try allocator.dupe(u8, arg); // Duplicate the target string 
            try options.targets.append(target_copy);
            expecting_target = false;
        } else if (expecting_port) {
            const port_copy = try allocator.dupe(u8, arg);
            try options.ports.append(port_copy);
            expecting_port = false;
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            std.debug.print("Usage: port_scanner -t <target> -p <common_ports>\n", .{});
            return error.InvalidArgument;
        }
    }

    if (options.targets.items.len == 0 or options.ports.items.len == 0) {
        std.debug.print("Usage: port_scanner -t <target> -p <common_ports>\n", .{});
        return error.MissingArgument;
    }
    return options;
}

fn resolveTargets(allocator: Allocator, targets: []const []const u8) !ArrayList(net.Address) {
    var addrs = ArrayList(net.Address).init(allocator);
    errdefer addrs.deinit();

    for (targets) |target| {
        if (net.Address.parseIp(target, 0)) |addr| {
            try addrs.append(addr);
        } else |_| {
            const addr_list = net.getAddressList(allocator, target, 0) catch |err| {
                std.debug.print("Failed to resolve host address '{s}': {}\n", .{ target, err });
                continue;
            };
            defer addr_list.deinit();

            for (addr_list.addrs) |addr| {
                try addrs.append(addr);
            }
        }
    }
    return addrs;
}

fn parsePorts(allocator: Allocator, port_inputs: []const []const u8) !ArrayList(u16) {
    var ports = ArrayList(u16).init(allocator);
    errdefer ports.deinit();

    var port_set = std.AutoHashMap(u16, void).init(allocator);
    defer port_set.deinit();

    for (port_inputs) |port_input| {
        var it = mem.tokenizeAny(u8, port_input, ",");
        while (it.next()) |token| {
            const trimmed = mem.trim(u8, token, " \t");

            if (mem.eql(u8, trimmed, "common_ports")) {
                for (common_ports) |port| {
                    try port_set.put(port, {});
                }
            } else if (mem.eql(u8, trimmed, "all")) {
                var i: u16 = 1;
                while (i < 65535) : (i += 1) {
                    try port_set.put(i, {});
                }
                // Add the last port separately to avoid overflow
                try port_set.put(65535, {});
            } else if (mem.indexOf(u8, trimmed, "-")) |dash_pos| {
                const start_str = trimmed[0..dash_pos];
                const end_str = trimmed[dash_pos + 1..];
                const start = try std.fmt.parseInt(u16, start_str, 10);
                const end = try std.fmt.parseInt(u16, end_str, 10);

                if (start > end) {
                    std.debug.print("Invalid port range: {s}\n", .{trimmed});
                    return error.InvalidPortRange;
                }

                var port = start;
                while (port <= end) : (port += 1) {
                    try port_set.put(port, {});
                }
            } else {
                const port = try std.fmt.parseInt(u16, trimmed, 10);
                try port_set.put(port, {});
            }
        }
    }

    var it = port_set.iterator();
    while (it.next()) |entry| {
        try ports.append(entry.key_ptr.*);
    }

    std.sort.heap(u16, ports.items, {}, std.sort.asc(u16));
    return ports;
}

fn scanPort(addr: net.Address, port: u16, timeout_ms: i32) !bool {
    const sockfd = posix.socket(
        addr.any.family,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
        posix.IPPROTO.TCP 
    ) catch {
        return false;
    };
    defer posix.close(sockfd);

    var target_addr = addr;
    target_addr.setPort(port);

    // Try to connect (non-blocking)
    const connect_result = posix.connect(sockfd, &target_addr.any, target_addr.getOsSockLen());
    
    if (connect_result) |_| {
        return true;
    } else |err| {
        switch (err) {
            error.WouldBlock => {
                // Connection is in progress, use poll to wait
                var pfd = [_]posix.pollfd{.{
                    .fd = sockfd,
                    .events = posix.POLL.OUT, 
                    .revents = 0,
                }};

                const ready = posix.poll(&pfd, timeout_ms) catch return false;

                // Check if poll returned and socket is writable
                if (ready > 0 and (pfd[0].revents & posix.POLL.OUT) != 0) {
                    // Make sure there are no error flags
                    const error_flags = posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL;
                    if ((pfd[0].revents & error_flags) == 0) {
                        return true;
                    }
                }
                return false;
            },
            error.ConnectionRefused => return false,
            else => return false,
        }
    }
}

// Scan function for Thread Pool
fn scanTask(
    address: net.Address,
    port: u16,
    timeout_ms: i32,
    wait_group: *Thread.WaitGroup,
    mutex: *Thread.Mutex,
    open_ports: *ArrayList(ScanResult),
) void {
    defer wait_group.finish();
    const is_open = scanPort(address, port, @intCast(timeout_ms)) catch false;

    if (is_open) {
        // Lock the mutex before modifying the shared list
        mutex.lock();
        defer mutex.unlock();

        // Append the result to the list. We ignore potential allocation 
        // errors here for simplicity, but in robust code you might handle it. 
        open_ports.append(.{ .address = address, .port = port }) catch {};
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Your memory is leaking!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    var options = try parseArgs(allocator);
    defer options.deinit();

    var addrs = try resolveTargets(allocator, options.targets.items);
    defer addrs.deinit();

    if (addrs.items.len == 0) {
        std.debug.print("No valid targets found\n", .{});
        return;
    }

    var ports = try parsePorts(allocator, options.ports.items);
    defer ports.deinit();

    std.debug.print("Scanning {} addrs x {} ports = {} total...\n", .{
        addrs.items.len,
        ports.items.len,
        addrs.items.len * ports.items.len,
    });

    var pool: Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = @min(128, Thread.getCpuCount() catch 4),
    });
    defer pool.deinit();

    var wait_group: Thread.WaitGroup = .{};
    var mutex = Thread.Mutex{};
    var open_ports = ArrayList(ScanResult).init(allocator);
    defer open_ports.deinit();

    const timeout_ms = 1000;
    for (addrs.items) |address| {
        for (ports.items) |port| {
            wait_group.start();
            try pool.spawn(scanTask, .{ address, port, timeout_ms, &wait_group, &mutex, &open_ports });
        }
    }
    wait_group.wait();

    std.debug.print("\nScan complete. Open ports found:\n", .{});
    if (open_ports.items.len == 0) {
        std.debug.print("None\n", .{});
    } else {
        std.sort.block(ScanResult, open_ports.items, {}, struct {
            fn lessThan(_: void, a: ScanResult, b: ScanResult) bool {
                if (a.address.any.family != b.address.any.family) {
                    return a.address.any.family < b.address.any.family;
                }

                // Compare the raw IP address bytes.
                switch (a.address.any.family) {
                    posix.AF.INET => {
                        // For IPv4 compare the u32 integers.
                        if (a.address.in.sa.addr != b.address.in.sa.addr) {
                            return a.address.in.sa.addr < b.address.in.sa.addr;
                        }
                    },
                    posix.AF.INET6 => {
                        // For IPv6 compare the [16]u8 arrays.
                        const order = std.mem.order(u8, &a.address.in6.sa.addr, &b.address.in6.sa.addr);
                        if (order != .eq) {
                            return order == .lt;
                        }
                    },
                    else => {},
                }

                // If addresses are identical, sort by port number.
                return a.port < b.port;
            }
        }.lessThan);

        for (open_ports.items) |result| {
            // Use the built-in formatter for net.Address - it handles IPv4 and IPv6 elegantly
            std.debug.print("  {} - Port {} is OPEN\n", .{ result.address, result.port });
        }
    }
}

// TESTS
const testing = std.testing;

test "Options initialization and cleanup" {
    const allocator = testing.allocator;
    var options = Options.init(allocator);
    defer options.deinit();
    
    try testing.expect(options.targets.items.len == 0);
    try testing.expect(options.ports.items.len == 0);
    try testing.expect(options.timeout_ms == TIMEOUT_MS);
    try testing.expect(options.max_threads == MAX_THREADS);
}

test "parsePorts - single port" {
    const allocator = testing.allocator;
    const port_inputs = [_][]const u8{"80"};
    
    var ports = try parsePorts(allocator, &port_inputs);
    defer ports.deinit();
    
    try testing.expect(ports.items.len == 1);
    try testing.expect(ports.items[0] == 80);
}

test "parsePorts - multiple ports" {
    const allocator = testing.allocator;
    const port_inputs = [_][]const u8{"80,443,22"};
    
    var ports = try parsePorts(allocator, &port_inputs);
    defer ports.deinit();
    
    try testing.expect(ports.items.len == 3);
    // Should be sorted
    try testing.expect(ports.items[0] == 22);
    try testing.expect(ports.items[1] == 80);
    try testing.expect(ports.items[2] == 443);
}

test "parsePorts - port range" {
    const allocator = testing.allocator;
    const port_inputs = [_][]const u8{"80-82"};
    
    var ports = try parsePorts(allocator, &port_inputs);
    defer ports.deinit();
    
    try testing.expect(ports.items.len == 3);
    try testing.expect(ports.items[0] == 80);
    try testing.expect(ports.items[1] == 81);
    try testing.expect(ports.items[2] == 82);
}

test "parsePorts - common_ports" {
    const allocator = testing.allocator;
    const port_inputs = [_][]const u8{"common_ports"};
    
    var ports = try parsePorts(allocator, &port_inputs);
    defer ports.deinit();
    
    try testing.expect(ports.items.len == common_ports.len);
    // Check that port 80 is in the list (it's in common_ports)
    var found_80 = false;
    for (ports.items) |port| {
        if (port == 80) {
            found_80 = true;
            break;
        }
    }
    try testing.expect(found_80);
}

test "parsePorts - mixed input" {
    const allocator = testing.allocator;
    const port_inputs = [_][]const u8{"22,80-82,443"};
    
    var ports = try parsePorts(allocator, &port_inputs);
    defer ports.deinit();
    
    try testing.expect(ports.items.len == 5); // 22, 80, 81, 82, 443
    try testing.expect(ports.items[0] == 22);
    try testing.expect(ports.items[1] == 80);
    try testing.expect(ports.items[2] == 81);
    try testing.expect(ports.items[3] == 82);
    try testing.expect(ports.items[4] == 443);
}

test "parsePorts - invalid range" {
    const allocator = testing.allocator;
    const port_inputs = [_][]const u8{"100-50"}; // Invalid: start > end
    
    const result = parsePorts(allocator, &port_inputs);
    try testing.expectError(ErrorTypes.InvalidPortRange, result);
}

test "parsePorts - duplicate removal" {
    const allocator = testing.allocator;
    const port_inputs = [_][]const u8{"80,80,443,80"};
    
    var ports = try parsePorts(allocator, &port_inputs);
    defer ports.deinit();
    
    try testing.expect(ports.items.len == 2); // Should remove duplicates
    try testing.expect(ports.items[0] == 80);
    try testing.expect(ports.items[1] == 443);
}

test "resolveTargets - IP address" {
    const allocator = testing.allocator;
    const targets = [_][]const u8{"127.0.0.1"};
    
    var addrs = try resolveTargets(allocator, &targets);
    defer addrs.deinit();
    
    try testing.expect(addrs.items.len == 1);
    try testing.expect(addrs.items[0].any.family == posix.AF.INET);
}

test "resolveTargets - localhost" {
    const allocator = testing.allocator;
    const targets = [_][]const u8{"localhost"};
    
    var addrs = try resolveTargets(allocator, &targets);
    defer addrs.deinit();
    
    try testing.expect(addrs.items.len >= 1); // Should resolve to at least one address
}

test "ScanResult struct" {
    const addr = try net.Address.parseIp("127.0.0.1", 80);
    const result = ScanResult{
        .address = addr,
        .port = 80,
    };
    
    try testing.expect(result.port == 80);
    try testing.expect(result.address.any.family == posix.AF.INET);
}

test "scanPort - closed port" {
    // Test scanning a port that should be closed
    const addr = try net.Address.parseIp("127.0.0.1", 0);
    const is_open = try scanPort(addr, 1, 100); // Very short timeout for speed
    
    // Port 1 should be closed on most systems
    try testing.expect(is_open == false);
}

test "common_ports array validity" {
    // Test that common_ports contains expected values
    var found_80 = false;
    var found_443 = false;
    var found_22 = false;
    
    for (common_ports) |port| {
        if (port == 80) found_80 = true;
        if (port == 443) found_443 = true;
        if (port == 22) found_22 = true;
        
        // All ports should be valid (1-65535)
        try testing.expect(port >= 1 and port <= 65535);
    }
    
    try testing.expect(found_80);
    try testing.expect(found_443);
    try testing.expect(found_22);
}

test "ErrorTypes enum" {
    // Test that our error types are properly defined
    const invalid_arg: ErrorTypes = ErrorTypes.InvalidArgument;
    const missing_arg: ErrorTypes = ErrorTypes.MissingArgument;
    const invalid_range: ErrorTypes = ErrorTypes.InvalidPortRange;
    
    try testing.expect(invalid_arg == ErrorTypes.InvalidArgument);
    try testing.expect(missing_arg == ErrorTypes.MissingArgument);
    try testing.expect(invalid_range == ErrorTypes.InvalidPortRange);
}
