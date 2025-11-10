//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

/// Person struct representing a person with basic information
pub const Person = struct {
    name: []const u8,
    age: u32,
    job: []const u8,

    pub fn format(self: Person, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        // If format spec is "any", manually output JSON
        if (comptime std.mem.eql(u8, fmt, "any")) {
            try writer.print("{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ self.name, self.age, self.job });
        } else {
            try writer.print("{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ self.name, self.age, self.job });
        }
    }
};

/// In-memory storage for Person records with thread-safe operations
pub const PersonStore = struct {
    people: std.ArrayList(Person),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) PersonStore {
        return .{
            .people = .empty,
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *PersonStore) void {
        // Free all person data
        for (self.people.items) |person| {
            self.allocator.free(person.name);
            self.allocator.free(person.job);
        }
        self.people.deinit(self.allocator);
    }

    pub fn add(self: *PersonStore, person: Person) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.people.append(self.allocator, person);
    }

    pub fn getAll(self: *PersonStore) ![]Person {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.people.items;
    }

    pub fn get(self: *PersonStore, index: usize) !?Person {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.people.items.len) return null;
        return self.people.items[index];
    }

    pub fn update(self: *PersonStore, index: usize, person: Person) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (index >= self.people.items.len) return false;

        // Free old data
        const old = self.people.items[index];
        self.allocator.free(old.name);
        self.allocator.free(old.job);

        self.people.items[index] = person;
        return true;
    }

    pub fn delete(self: *PersonStore, index: usize) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (index >= self.people.items.len) return false;

        // Free data
        const person = self.people.orderedRemove(index);
        self.allocator.free(person.name);
        self.allocator.free(person.job);

        return true;
    }
};

test "person creation" {
    const person = Person{
        .name = "John Doe",
        .age = 30,
        .job = "Engineer",
    };
    try std.testing.expectEqualStrings("John Doe", person.name);
    try std.testing.expectEqual(@as(u32, 30), person.age);
}

test "person store operations" {
    const allocator = std.testing.allocator;
    var store = PersonStore.init(allocator);
    defer store.deinit();

    const name1 = try allocator.dupe(u8, "Alice");
    const job1 = try allocator.dupe(u8, "Developer");

    const person1 = Person{ .name = name1, .age = 25, .job = job1 };
    try store.add(person1);

    try std.testing.expectEqual(@as(usize, 1), store.people.items.len);

    const retrieved = store.get(0).?;
    try std.testing.expectEqualStrings("Alice", retrieved.name);
}
