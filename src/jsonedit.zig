//! Editing `composer.json` in place, without reformatting it.
//!
//! `require` and `remove` change one line of a file a human wrote and reads.
//! Decoding it, mutating the tree and re-encoding is the obvious approach and
//! the wrong one: it rewrites the whole file — key order, indentation, the blank
//! line the author put between `autoload` and `scripts`, `1.0` becoming `1` —
//! and turns a one-line change into a diff nobody can review.
//!
//! Composer solves this with `Composer\Json\JsonManipulator`, a set of PCRE
//! patterns over the raw text. The behaviour reproduced here is that class's,
//! but the mechanism is a small structural scanner instead: `valueEnd` walks a
//! JSON value and reports where it stops, `members` lists an object's entries
//! with their exact byte ranges, and every operation is a splice between two
//! offsets. Bytes outside the range are not touched — which is the whole point,
//! and is a property a regex can only approximate.
//!
//! Agreement with Composer is MEASURED, not asserted: `jsonedit_corpus.json`
//! holds operations applied by `JsonManipulator` itself to real manifests, and
//! the test at the bottom requires this file to produce the same bytes.

const std = @import("std");
const phpjson = @import("phpjson.zig");

/// `JsonFile::encode` — `JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE`.
/// Composer writes manifests with both, which is why a package name keeps its
/// `/` and an author's name keeps its accents.
const encode_opts: phpjson.Options = .{
    .escape_slashes = false,
    .escape_unicode = false,
};

pub const Error = error{NotAnObject};

/// A `composer.json` under edit.
pub const Document = struct {
    allocator: std.mem.Allocator,
    /// The file WITHOUT its trailing newline — Composer trims on the way in and
    /// re-adds on the way out, and every offset here is into this.
    contents: []const u8,
    /// `"\r\n"` when the file has one anywhere, else `"\n"`.
    newline: []const u8,
    /// One level of indentation, detected from the file.
    indent: []const u8,

    /// Read a document. The source is trimmed and must be a JSON object.
    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Document {
        const trimmed = std.mem.trim(u8, source, " \t\r\n\u{FEFF}");
        const body = if (trimmed.len == 0) "{}" else trimmed;
        if (body[0] != '{' or body[body.len - 1] != '}') return Error.NotAnObject;

        const newline: []const u8 = if (std.mem.indexOf(u8, body, "\r\n") != null) "\r\n" else "\n";
        const indent = detectIndent(body);

        return .{
            .allocator = allocator,
            .contents = if (std.mem.eql(u8, body, "{}"))
                try std.fmt.allocPrint(allocator, "{{{s}}}", .{newline})
            else
                body,
            .newline = newline,
            .indent = indent,
        };
    }

    /// The bytes to write back, with the trailing newline Composer adds.
    pub fn output(self: Document) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.contents, self.newline });
    }

    // ── links: require / require-dev / conflict / replace / provide ───────────

    /// Add or update `<section>.<package>: <constraint>`.
    ///
    /// Updating an existing entry rewrites ONLY its value, so a manifest that
    /// spells the key `"vendor\/name"` keeps working (Composer re-encodes the
    /// key it found, normalising the escape) and everything around it is
    /// untouched.
    pub fn addLink(
        self: *Document,
        section: []const u8,
        package: []const u8,
        constraint: []const u8,
        sort: bool,
    ) !bool {
        const top = try self.members(0);
        const entry = find(self.contents, top, section) orelse {
            // No such section yet: create it with this one link inside.
            var obj: std.json.ObjectMap = .empty;
            try obj.put(self.allocator, package, .{ .string = constraint });
            return self.addMainKey(section, .{ .object = obj });
        };

        const links_start = entry.value_start;
        const links_end = entry.value_end;
        if (self.contents[links_start] != '{') return false;

        const inner = try self.members(links_start);
        var links: []const u8 = undefined;

        if (findLoose(self.contents, inner, package)) |existing| {
            // Replace the value, and re-encode the KEY so `vendor\/name`
            // becomes `vendor/name` — Composer does the same, and leaving the
            // escape in place makes the file inconsistent with what it writes.
            links = try std.mem.concat(self.allocator, u8, &.{
                self.contents[links_start..existing.key_start],
                try self.encodeString(unescapeSlashes(self.allocator, self.contents[existing.key_start + 1 .. existing.key_end - 1]) catch package),
                self.contents[existing.key_end..existing.value_start],
                try self.encodeString(constraint),
                self.contents[existing.value_end..links_end],
            });
        } else if (inner.len > 0) {
            // Insert before the closing brace, keeping the whitespace that was
            // already sitting in front of it.
            const close = links_end - 1;
            var ws = close;
            while (ws > links_start and isSpace(self.contents[ws - 1])) ws -= 1;
            links = try std.mem.concat(self.allocator, u8, &.{
                self.contents[links_start..ws],
                ",",
                self.newline,
                self.indent,
                self.indent,
                try self.encodeString(package),
                ": ",
                try self.encodeString(constraint),
                self.contents[ws..links_end],
            });
        } else {
            links = try std.mem.concat(self.allocator, u8, &.{
                "{",                               self.newline,
                self.indent,                       self.indent,
                try self.encodeString(package),    ": ",
                try self.encodeString(constraint), self.newline,
                self.indent,                       "}",
            });
        }

        if (sort) links = try self.sortedLinks(links);

        self.contents = try std.mem.concat(self.allocator, u8, &.{
            self.contents[0..links_start],
            links,
            self.contents[links_end..],
        });
        return true;
    }

    /// Remove `<section>.<package>`, and the section itself when it empties.
    ///
    /// Composer leaves an emptied `require` behind as `{}`; `remove` then calls
    /// `removeMainKeyIfEmpty` separately. `removeLink` does both, because an
    /// empty `"require": {}` left in a manifest is noise the user did not ask
    /// for and `composer remove` does not leave either.
    pub fn removeLink(self: *Document, section: []const u8, package: []const u8) !bool {
        if (!try self.removeSubNode(section, package)) return false;
        _ = try self.removeMainKeyIfEmpty(section);
        return true;
    }

    // ── generic object surgery ───────────────────────────────────────────────

    /// Remove `<main>.<name>`, leaving `<main>` in place (possibly empty).
    ///
    /// Returns true when the manifest no longer has that member — including the
    /// case where it never did, which is Composer's answer too: `remove` on an
    /// absent package is not a failure, it is a no-op that already holds.
    pub fn removeSubNode(self: *Document, main: []const u8, name: []const u8) !bool {
        const top = try self.members(0);
        const entry = find(self.contents, top, main) orelse return true;
        if (self.contents[entry.value_start] != '{') return false;

        const inner = try self.members(entry.value_start);
        const target = findLoose(self.contents, inner, name) orelse return true;

        // Cut the member AND one separating comma — the one after it when there
        // is a following member, otherwise the one before it. Cutting neither
        // leaves `{"a": 1, }`; cutting both leaves `{"a": 1"c": 3}`.
        var cut_from = target.member_start;
        var cut_to = target.value_end;

        if (target.index + 1 < inner.len) {
            cut_to = inner[target.index + 1].member_start;
        } else if (target.index > 0) {
            cut_from = inner[target.index - 1].value_end;
        } else {
            // The only member: leave `{`, whitespace, `}`.
            cut_from = entry.value_start + 1;
            cut_to = entry.value_end - 1;
            self.contents = try std.mem.concat(self.allocator, u8, &.{
                self.contents[0..cut_from],
                self.newline,
                self.indent,
                self.contents[cut_to..],
            });
            return true;
        }

        self.contents = try std.mem.concat(self.allocator, u8, &.{
            self.contents[0..cut_from],
            self.contents[cut_to..],
        });
        return true;
    }

    /// Set `<main>.<name>`, creating `<main>` when it is absent.
    ///
    /// The nested counterpart of `addMainKey`, and the operation `config` is
    /// built on: `config.vendor-dir`, `extra.branch-alias`, `scripts.test`.
    pub fn addSubNode(
        self: *Document,
        main: []const u8,
        name: []const u8,
        value: std.json.Value,
    ) !bool {
        const top = try self.members(0);
        const entry = find(self.contents, top, main) orelse {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(self.allocator, name, value);
            return self.addMainKey(main, .{ .object = obj });
        };
        if (self.contents[entry.value_start] != '{') return false;

        // A string value is the overwhelmingly common case and the one
        // `addLink` already places correctly, formatting and all.
        if (value == .string) return self.addLink(main, name, value.string, false);

        const inner = try self.members(entry.value_start);
        const rendered = try self.format(value, 1, value == .object);

        if (find(self.contents, inner, name)) |existing| {
            self.contents = try std.mem.concat(self.allocator, u8, &.{
                self.contents[0..existing.value_start],
                rendered,
                self.contents[existing.value_end..],
            });
            return true;
        }

        const close = entry.value_end - 1;
        var ws = close;
        while (ws > entry.value_start and isSpace(self.contents[ws - 1])) ws -= 1;
        const lead: []const u8 = if (inner.len > 0) "," else "";

        self.contents = try std.mem.concat(self.allocator, u8, &.{
            self.contents[0..ws],
            lead,
            self.newline,
            self.indent,
            self.indent,
            try self.encodeString(name),
            ": ",
            rendered,
            self.newline,
            self.indent,
            "}",
            self.contents[entry.value_end..],
        });
        return true;
    }

    /// Set a top-level key, replacing its value if the key is already there and
    /// appending it at the end if not.
    pub fn addMainKey(self: *Document, key: []const u8, value: std.json.Value) !bool {
        return self.setMainKeyRaw(key, try self.format(value, 0, value == .object));
    }

    /// Set a top-level key to already-rendered JSON text.
    ///
    /// For a value whose LAYOUT matters and does not come out of the generic
    /// formatter — `repositories`, whose array-of-objects style Composer writes
    /// with its brackets in an unusual place. The caller owns the formatting;
    /// this places it and manages the comma.
    pub fn setMainKeyRaw(self: *Document, key: []const u8, rendered: []const u8) !bool {
        const top = try self.members(0);
        if (find(self.contents, top, key)) |entry| {
            self.contents = try std.mem.concat(self.allocator, u8, &.{
                self.contents[0..entry.value_start],
                rendered,
                self.contents[entry.value_end..],
            });
            return true;
        }

        // Append before the closing brace. When the object already has members
        // the new one needs a comma; when it is empty it does not.
        const close = self.contents.len - 1;
        var ws = close;
        while (ws > 0 and isSpace(self.contents[ws - 1])) ws -= 1;

        const lead: []const u8 = if (top.len > 0) "," else "";
        self.contents = try std.mem.concat(self.allocator, u8, &.{
            self.contents[0..ws],
            lead,
            self.newline,
            self.indent,
            try self.encodeString(key),
            ": ",
            rendered,
            self.newline,
            "}",
        });
        return true;
    }

    /// Remove a top-level key. True when it is gone, including when it was
    /// never there.
    pub fn removeMainKey(self: *Document, key: []const u8) !bool {
        const top = try self.members(0);
        var idx: ?usize = null;
        for (top, 0..) |m, i| {
            if (std.mem.eql(u8, keyOf(self.contents, m), key)) idx = i;
        }
        const at = idx orelse return true;

        var cut_from = top[at].member_start;
        var cut_to = top[at].value_end;
        if (at + 1 < top.len) {
            cut_to = top[at + 1].member_start;
        } else if (at > 0) {
            cut_from = top[at - 1].value_end;
        } else {
            self.contents = try std.fmt.allocPrint(self.allocator, "{{{s}}}", .{self.newline});
            return true;
        }

        self.contents = try std.mem.concat(self.allocator, u8, &.{
            self.contents[0..cut_from],
            self.contents[cut_to..],
        });
        return true;
    }

    /// Remove a top-level key only when its value is an empty object or array.
    pub fn removeMainKeyIfEmpty(self: *Document, key: []const u8) !bool {
        const top = try self.members(0);
        const entry = find(self.contents, top, key) orelse return true;
        const value = std.mem.trim(u8, self.contents[entry.value_start..entry.value_end], " \t\r\n");
        if (!(std.mem.eql(u8, value, "{}") or std.mem.eql(u8, value, "[]"))) {
            // `{\n    }` counts as empty too — it is what removeSubNode leaves.
            if (value.len < 2) return true;
            const body = std.mem.trim(u8, value[1 .. value.len - 1], " \t\r\n");
            if (body.len != 0) return true;
        }
        return self.removeMainKey(key);
    }

    /// Read the current document back as a parsed value.
    pub fn decode(self: Document) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.allocator, self.contents, .{});
    }

    // ── rendering ────────────────────────────────────────────────────────────

    /// `JsonManipulator::format` — the shape Composer gives a value it is
    /// inserting. Lists go on one line, objects go multi-line, and the depth
    /// arithmetic (`depth + 2` for members, `depth + 1` for the brace) is
    /// Composer's, not a simplification of it.
    pub fn format(self: Document, value: std.json.Value, depth: usize, was_object: bool) ![]const u8 {
        switch (value) {
            .object => |o| {
                if (o.count() == 0) {
                    return std.mem.concat(self.allocator, u8, &.{
                        "{", self.newline, try self.repeat(depth + 1), "}",
                    });
                }
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(self.allocator, "{");
                try out.appendSlice(self.allocator, self.newline);
                var it = o.iterator();
                var first = true;
                while (it.next()) |e| {
                    if (!first) {
                        try out.appendSlice(self.allocator, ",");
                        try out.appendSlice(self.allocator, self.newline);
                    }
                    first = false;
                    try out.appendSlice(self.allocator, try self.repeat(depth + 2));
                    try out.appendSlice(self.allocator, try self.encodeString(e.key_ptr.*));
                    try out.appendSlice(self.allocator, ": ");
                    try out.appendSlice(self.allocator, try self.format(e.value_ptr.*, depth + 1, false));
                }
                try out.appendSlice(self.allocator, self.newline);
                try out.appendSlice(self.allocator, try self.repeat(depth + 1));
                try out.appendSlice(self.allocator, "}");
                return out.toOwnedSlice(self.allocator);
            },
            .array => |a| {
                if (a.items.len == 0) return if (was_object)
                    try std.mem.concat(self.allocator, u8, &.{ "{", self.newline, try self.repeat(depth + 1), "}" })
                else
                    "[]";
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(self.allocator, "[");
                for (a.items, 0..) |item, i| {
                    if (i > 0) try out.appendSlice(self.allocator, ", ");
                    try out.appendSlice(self.allocator, try self.format(item, depth + 1, false));
                }
                try out.appendSlice(self.allocator, "]");
                return out.toOwnedSlice(self.allocator);
            },
            else => {
                var out: std.ArrayList(u8) = .empty;
                try phpjson.encode(self.allocator, &out, value, encode_opts);
                return out.toOwnedSlice(self.allocator);
            },
        }
    }

    fn repeat(self: Document, times: usize) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (0..times) |_| try out.appendSlice(self.allocator, self.indent);
        return out.toOwnedSlice(self.allocator);
    }

    fn encodeString(self: Document, s: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try phpjson.encode(self.allocator, &out, .{ .string = s }, encode_opts);
        return out.toOwnedSlice(self.allocator);
    }

    /// Re-render a link object with its keys in Composer's `sort-packages`
    /// order.
    fn sortedLinks(self: Document, links: []const u8) ![]const u8 {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.allocator, links, .{}) catch return links;
        if (parsed != .object) return links;

        var keys: std.ArrayList([]const u8) = .empty;
        var it = parsed.object.iterator();
        while (it.next()) |e| try keys.append(self.allocator, e.key_ptr.*);

        const ctx = SortContext{ .allocator = self.allocator };
        std.mem.sort([]const u8, keys.items, ctx, SortContext.before);

        var ordered: std.json.ObjectMap = .empty;
        for (keys.items) |k| try ordered.put(self.allocator, k, parsed.object.get(k).?);
        return self.format(.{ .object = ordered }, 0, true);
    }

    // ── scanning ─────────────────────────────────────────────────────────────

    /// Every member of the object starting at `obj_start` (which must be `{`).
    fn members(self: Document, obj_start: usize) ![]const Member {
        return membersOf(self.allocator, self.contents, obj_start);
    }
};

/// One `"key": value` pair, by byte offset into the document.
pub const Member = struct {
    /// Position in the object's member list.
    index: usize,
    /// The first byte of the member — the opening quote of its key.
    member_start: usize,
    /// The opening quote of the key.
    key_start: usize,
    /// One past the key's closing quote.
    key_end: usize,
    /// The first byte of the value.
    value_start: usize,
    /// One past the last byte of the value.
    value_end: usize,
};

fn keyOf(text: []const u8, m: Member) []const u8 {
    return text[m.key_start + 1 .. m.key_end - 1];
}

/// Exact key match.
fn find(text: []const u8, list: []const Member, name: []const u8) ?Member {
    for (list) |m| if (std.mem.eql(u8, keyOf(text, m), name)) return m;
    return null;
}

/// Composer's match for a package key: case-insensitive, and tolerant of the
/// `\/` escape a hand-edited manifest may carry. Both concessions are in
/// `JsonManipulator::addLink`'s regex (`/i`, and `str_replace('/', '\\\\?/')`),
/// and both are there because package names in the wild are written both ways.
fn findLoose(text: []const u8, list: []const Member, name: []const u8) ?Member {
    for (list) |m| {
        const key = keyOf(text, m);
        if (eqlLoose(key, name)) return m;
    }
    return null;
}

fn eqlLoose(key: []const u8, name: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < key.len and j < name.len) {
        var kc = key[i];
        if (kc == '\\' and i + 1 < key.len and key[i + 1] == '/') {
            kc = '/';
            i += 1;
        }
        if (std.ascii.toLower(kc) != std.ascii.toLower(name[j])) return false;
        i += 1;
        j += 1;
    }
    return i == key.len and j == name.len;
}

fn unescapeSlashes(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "\\/") == null) return s;
    const size = std.mem.replacementSize(u8, s, "\\/", "/");
    const out = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, s, "\\/", "/", out);
    return out;
}

fn membersOf(allocator: std.mem.Allocator, text: []const u8, obj_start: usize) ![]const Member {
    var out: std.ArrayList(Member) = .empty;
    if (obj_start >= text.len or text[obj_start] != '{') return out.toOwnedSlice(allocator);

    var i = obj_start + 1;
    while (true) {
        i = skipSpace(text, i);
        if (i >= text.len or text[i] == '}') break;
        if (text[i] == ',') {
            i += 1;
            continue;
        }
        if (text[i] != '"') break;

        const key_start = i;
        const key_end = stringEnd(text, i) orelse break;
        var j = skipSpace(text, key_end);
        if (j >= text.len or text[j] != ':') break;
        j = skipSpace(text, j + 1);
        const value_end = valueEnd(text, j) orelse break;

        try out.append(allocator, .{
            .index = out.items.len,
            .member_start = key_start,
            .key_start = key_start,
            .key_end = key_end,
            .value_start = j,
            .value_end = value_end,
        });
        i = value_end;
    }
    return out.toOwnedSlice(allocator);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn skipSpace(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and isSpace(text[i])) i += 1;
    return i;
}

/// One past the closing quote of the string starting at `from`.
fn stringEnd(text: []const u8, from: usize) ?usize {
    if (from >= text.len or text[from] != '"') return null;
    var i = from + 1;
    while (i < text.len) {
        if (text[i] == '\\') {
            i += 2;
            continue;
        }
        if (text[i] == '"') return i + 1;
        i += 1;
    }
    return null;
}

/// One past the last byte of the JSON value starting at `from`.
///
/// The reason this file does not use a parser: a parser gives back a tree, and
/// what an in-place edit needs is the RANGE the value occupies, so the bytes on
/// either side of it can be kept exactly as the author typed them.
pub fn valueEnd(text: []const u8, from: usize) ?usize {
    if (from >= text.len) return null;
    return switch (text[from]) {
        '"' => stringEnd(text, from),
        '{' => spanEnd(text, from, '{', '}'),
        '[' => spanEnd(text, from, '[', ']'),
        else => blk: {
            var i = from;
            while (i < text.len and !isSpace(text[i]) and text[i] != ',' and
                text[i] != '}' and text[i] != ']') i += 1;
            break :blk if (i == from) null else i;
        },
    };
}

fn spanEnd(text: []const u8, from: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    var i = from;
    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            i = stringEnd(text, i) orelse return null;
            continue;
        }
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
        i += 1;
    }
    return null;
}

/// `JsonFile::detectIndenting` — the leading whitespace of the first line that
/// starts with a quote.
pub fn detectIndent(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i > 0 and i < line.len and line[i] == '"') return line[0..i];
    }
    return "    ";
}

// ── sort-packages ─────────────────────────────────────────────────────────────

const SortContext = struct {
    allocator: std.mem.Allocator,

    fn before(self: SortContext, a: []const u8, b: []const u8) bool {
        const pa = sortPrefix(self.allocator, a) catch a;
        const pb = sortPrefix(self.allocator, b) catch b;
        return natCompare(pa, pb) < 0;
    }
};

/// `JsonManipulator::sortPackages`'s prefix function: platform requirements
/// come first, in a fixed order, and everything else follows.
///
/// The prefix is prepended to the NAME and the pair compared with `strnatcmp`,
/// so the ordering is `php`, `hhvm`, `ext-*`, `lib-*`, other non-alphabetic
/// platform names, then real packages.
fn sortPrefix(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (!isPlatformPackage(name)) return std.fmt.allocPrint(allocator, "5-{s}", .{name});
    const group: u8 = if (std.mem.startsWith(u8, name, "php"))
        '0'
    else if (std.mem.startsWith(u8, name, "hhvm"))
        '1'
    else if (std.mem.startsWith(u8, name, "ext"))
        '2'
    else if (std.mem.startsWith(u8, name, "lib"))
        '3'
    else
        '4';
    return std.fmt.allocPrint(allocator, "{c}-{s}", .{ group, name });
}

/// `PlatformRepository::isPlatformPackage` — the regex
/// `{^(?:php(?:-64bit|-ivm)?|hhvm|(?:ext|lib)-[a-z0-9](?:[_.-]?[a-z0-9]+)*|composer(?:-(?:plugin|runtime)-api)?)$}iD`.
fn isPlatformPackage(name: []const u8) bool {
    if (std.mem.eql(u8, name, "php") or std.mem.eql(u8, name, "php-64bit") or
        std.mem.eql(u8, name, "php-ipv6") or std.mem.eql(u8, name, "php-zts") or
        std.mem.eql(u8, name, "php-debug") or std.mem.eql(u8, name, "hhvm")) return true;
    if (std.mem.eql(u8, name, "composer") or
        std.mem.eql(u8, name, "composer-plugin-api") or
        std.mem.eql(u8, name, "composer-runtime-api")) return true;
    return std.mem.startsWith(u8, name, "ext-") or std.mem.startsWith(u8, name, "lib-");
}

/// `strnatcmp`, the comparator PHP's `uksort` is handed above.
///
/// Ported rather than approximated with `strcmp`, because the two disagree
/// exactly where package names carry version numbers —
/// `symfony/polyfill-php72` against `symfony/polyfill-php8` — and a sorted
/// `require` block that differs from Composer's in one line is a diff on every
/// subsequent `composer require`.
pub fn natCompare(a: []const u8, b: []const u8) i32 {
    if (a.len == 0 or b.len == 0) {
        if (a.len == b.len) return 0;
        return if (a.len > b.len) 1 else -1;
    }

    var ai: usize = 0;
    var bi: usize = 0;
    var leading = true;

    while (true) {
        // Leading zeros are not significant: `007` and `7` are the same number.
        while (leading and ai < a.len and a[ai] == '0' and
            ai + 1 < a.len and isDigit(a[ai + 1])) ai += 1;
        while (leading and bi < b.len and b[bi] == '0' and
            bi + 1 < b.len and isDigit(b[bi + 1])) bi += 1;
        leading = false;

        while (ai < a.len and isSpace(a[ai])) ai += 1;
        while (bi < b.len and isSpace(b[bi])) bi += 1;

        if (ai >= a.len or bi >= b.len) break;

        const ca = a[ai];
        const cb = b[bi];

        if (isDigit(ca) and isDigit(cb)) {
            // A run starting with `0` is read as a fraction — compared left to
            // right — and any other run as an integer, compared by length first.
            const result = if (ca == '0' or cb == '0')
                compareLeft(a, &ai, b, &bi)
            else
                compareRight(a, &ai, b, &bi);
            if (result != 0) return result;
            if (ai >= a.len and bi >= b.len) return 0;
            continue;
        }

        if (ca < cb) return -1;
        if (ca > cb) return 1;
        ai += 1;
        bi += 1;

        if (ai >= a.len and bi >= b.len) return 0;
        if (ai >= a.len) return -1;
        if (bi >= b.len) return 1;
    }

    if (ai >= a.len and bi >= b.len) return 0;
    return if (ai >= a.len) -1 else 1;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Fractional comparison: the first differing digit decides, and the shorter
/// run loses only if the other still has digits.
fn compareLeft(a: []const u8, ai: *usize, b: []const u8, bi: *usize) i32 {
    while (true) {
        const da = ai.* < a.len and isDigit(a[ai.*]);
        const db = bi.* < b.len and isDigit(b[bi.*]);
        if (!da and !db) return 0;
        if (!da) return -1;
        if (!db) return 1;
        if (a[ai.*] < b[bi.*]) return -1;
        if (a[ai.*] > b[bi.*]) return 1;
        ai.* += 1;
        bi.* += 1;
    }
}

/// Integer comparison: the longer run of digits is the larger number, and only
/// if the lengths match does the first difference decide.
fn compareRight(a: []const u8, ai: *usize, b: []const u8, bi: *usize) i32 {
    var bias: i32 = 0;
    while (true) {
        const da = ai.* < a.len and isDigit(a[ai.*]);
        const db = bi.* < b.len and isDigit(b[bi.*]);
        if (!da and !db) return bias;
        if (!da) return -1;
        if (!db) return 1;
        if (bias == 0) {
            if (a[ai.*] < b[bi.*]) bias = -1;
            if (a[ai.*] > b[bi.*]) bias = 1;
        }
        ai.* += 1;
        bi.* += 1;
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn edited(a: std.mem.Allocator, source: []const u8, comptime op: anytype) ![]const u8 {
    var doc = try Document.init(a, source);
    _ = try op(&doc);
    return doc.output();
}

test "adding a link touches only the line it adds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\{
        \\    "name": "acme/app",
        \\    "require": {
        \\        "php": "^8.1"
        \\    },
        \\    "autoload": {
        \\        "psr-4": { "Acme\\": "src/" }
        \\    }
        \\}
    ;
    var doc = try Document.init(a, source);
    try testing.expect(try doc.addLink("require", "psr/log", "^3.0", false));

    try testing.expectEqualStrings(
        \\{
        \\    "name": "acme/app",
        \\    "require": {
        \\        "php": "^8.1",
        \\        "psr/log": "^3.0"
        \\    },
        \\    "autoload": {
        \\        "psr-4": { "Acme\\": "src/" }
        \\    }
        \\}
        \\
    , try doc.output());
}

test "an existing link has its value replaced and nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.init(a,
        \\{
        \\    "require": {
        \\        "psr/log":    "^1.0",
        \\        "php": "^8.1"
        \\    }
        \\}
    );
    try testing.expect(try doc.addLink("require", "psr/log", "^3.0", false));

    // The odd spacing around the colon is the author's and survives.
    try testing.expectEqualStrings(
        \\{
        \\    "require": {
        \\        "psr/log":    "^3.0",
        \\        "php": "^8.1"
        \\    }
        \\}
        \\
    , try doc.output());
}

test "a missing section is created" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.init(a,
        \\{
        \\    "name": "acme/app"
        \\}
    );
    try testing.expect(try doc.addLink("require-dev", "phpunit/phpunit", "^11.0", false));

    try testing.expectEqualStrings(
        \\{
        \\    "name": "acme/app",
        \\    "require-dev": {
        \\        "phpunit/phpunit": "^11.0"
        \\    }
        \\}
        \\
    , try doc.output());
}

test "an empty section is filled rather than appended to" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.init(a,
        \\{
        \\    "require": {}
        \\}
    );
    try testing.expect(try doc.addLink("require", "psr/log", "^3.0", false));
    try testing.expectEqualStrings(
        \\{
        \\    "require": {
        \\        "psr/log": "^3.0"
        \\    }
        \\}
        \\
    , try doc.output());
}

test "a two-space manifest stays two-space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.init(a,
        \\{
        \\  "require": {
        \\    "php": "^8.1"
        \\  }
        \\}
    );
    try testing.expectEqualStrings("  ", doc.indent);
    try testing.expect(try doc.addLink("require", "psr/log", "^3.0", false));
    try testing.expectEqualStrings(
        \\{
        \\  "require": {
        \\    "php": "^8.1",
        \\    "psr/log": "^3.0"
        \\  }
        \\}
        \\
    , try doc.output());
}

test "removing a link takes its comma with it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Middle member: the comma AFTER it goes.
    var mid = try Document.init(a,
        \\{
        \\    "require": {
        \\        "php": "^8.1",
        \\        "psr/log": "^3.0",
        \\        "psr/cache": "^3.0"
        \\    }
        \\}
    );
    try testing.expect(try mid.removeLink("require", "psr/log"));
    try testing.expectEqualStrings(
        \\{
        \\    "require": {
        \\        "php": "^8.1",
        \\        "psr/cache": "^3.0"
        \\    }
        \\}
        \\
    , try mid.output());

    // Last member: the comma BEFORE it goes, or the result is `"^8.1",\n}`.
    var last = try Document.init(a,
        \\{
        \\    "require": {
        \\        "php": "^8.1",
        \\        "psr/log": "^3.0"
        \\    }
        \\}
    );
    try testing.expect(try last.removeLink("require", "psr/log"));
    try testing.expectEqualStrings(
        \\{
        \\    "require": {
        \\        "php": "^8.1"
        \\    }
        \\}
        \\
    , try last.output());
}

test "emptying a section removes the section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.init(a,
        \\{
        \\    "name": "acme/app",
        \\    "require": {
        \\        "psr/log": "^3.0"
        \\    }
        \\}
    );
    try testing.expect(try doc.removeLink("require", "psr/log"));
    try testing.expectEqualStrings(
        \\{
        \\    "name": "acme/app"
        \\}
        \\
    , try doc.output());
}

test "removing a package that is not there is a no-op, not a failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\{
        \\    "require": {
        \\        "php": "^8.1"
        \\    }
        \\}
    ;
    var doc = try Document.init(a, source);
    try testing.expect(try doc.removeLink("require", "psr/log"));
    try testing.expect(try doc.removeLink("suggest", "anything"));
    try testing.expectEqualStrings(source ++ "\n", try doc.output());
}

test "a key written with an escaped slash is found, and normalised on write" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.init(a,
        \\{
        \\    "require": {
        \\        "psr\/log": "^1.0"
        \\    }
        \\}
    );
    try testing.expect(try doc.addLink("require", "psr/log", "^3.0", false));
    try testing.expect(std.mem.indexOf(u8, doc.contents, "\"psr/log\": \"^3.0\"") != null);
}

test "sort-packages puts platform requirements first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.init(a,
        \\{
        \\    "require": {
        \\        "psr/log": "^3.0",
        \\        "ext-json": "*"
        \\    }
        \\}
    );
    try testing.expect(try doc.addLink("require", "php", "^8.1", true));
    try testing.expectEqualStrings(
        \\{
        \\    "require": {
        \\        "php": "^8.1",
        \\        "ext-json": "*",
        \\        "psr/log": "^3.0"
        \\    }
        \\}
        \\
    , try doc.output());
}

test "CRLF survives an edit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.init(a, "{\r\n    \"require\": {\r\n        \"php\": \"^8.1\"\r\n    }\r\n}");
    try testing.expectEqualStrings("\r\n", doc.newline);
    try testing.expect(try doc.addLink("require", "psr/log", "^3.0", false));
    try testing.expect(std.mem.indexOf(u8, doc.contents, "\"php\": \"^8.1\",\r\n        \"psr/log\"") != null);
    // And no bare LF was introduced anywhere.
    try testing.expectEqual(
        std.mem.count(u8, doc.contents, "\r\n"),
        std.mem.count(u8, doc.contents, "\n"),
    );
}

test "an empty file becomes an object with the key in it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.init(a, "");
    try testing.expect(try doc.addLink("require", "psr/log", "^3.0", false));
    try testing.expectEqualStrings(
        \\{
        \\    "require": {
        \\        "psr/log": "^3.0"
        \\    }
        \\}
        \\
    , try doc.output());
}

test "valueEnd spans nested structures and strings containing braces" {
    const text =
        \\{"a": {"b": [1, {"c": "}"}]}, "d": 2}
    ;
    const list = try membersOf(testing.allocator, text, 0);
    defer testing.allocator.free(list);

    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("a", keyOf(text, list[0]));
    try testing.expectEqualStrings("{\"b\": [1, {\"c\": \"}\"}]}", text[list[0].value_start..list[0].value_end]);
    try testing.expectEqualStrings("d", keyOf(text, list[1]));
    try testing.expectEqualStrings("2", text[list[1].value_start..list[1].value_end]);
}

// The corpus is 1920 operations that `Composer\Json\JsonManipulator` itself
// applied to 109 real manifests from this workspace — the kernel, its modules,
// every plugin, and their vendor trees. Each row is stored as the minimal
// splice (offset, deleted length, inserted text) between the original and
// Composer's result, which is both compact and exactly the property under
// test: that an edit touches those bytes and no others.
//
// Rows Composer itself turns into invalid JSON are not in the corpus. Matching
// a bug is not the goal; matching the behaviour a manifest depends on is.
test "agrees with Composer's own JsonManipulator over the recorded corpus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        @embedFile("testdata/jsonedit_corpus.json"),
        .{},
    );
    const sources = parsed.object.get("sources").?.array.items;
    const rows = parsed.object.get("rows").?.array.items;

    var checked: usize = 0;
    for (rows) |row| {
        const o = row.object;
        const source = sources[@intCast(o.get("s").?.integer)].string;
        const op = o.get("op").?.array.items;

        // Rebuild Composer's answer from the splice.
        const at: usize = @intCast(o.get("at").?.integer);
        const del: usize = @intCast(o.get("del").?.integer);
        const want = try std.mem.concat(a, u8, &.{
            source[0..at],
            o.get("ins").?.string,
            source[at + del ..],
        });

        var doc = try Document.init(a, source);
        const name = op[0].string;
        const applied = if (std.mem.eql(u8, name, "addLink"))
            try doc.addLink(op[1].string, op[2].string, op[3].string, op[4].bool)
        else if (std.mem.eql(u8, name, "removeSubNode"))
            try doc.removeSubNode(op[1].string, op[2].string)
        else if (std.mem.eql(u8, name, "removeMainKey"))
            try doc.removeMainKey(op[1].string)
        else
            unreachable;
        try testing.expect(applied);

        const got = try doc.output();
        testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("op={s} {s} {s}\n", .{
                name,
                op[1].string,
                if (op.len > 2) op[2].string else "",
            });
            return e;
        };
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 1920), checked);
}

test "addSubNode creates the parent, then adds beside what is there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try Document.init(a,
        \\{
        \\    "name": "acme/app"
        \\}
    );
    try testing.expect(try doc.addSubNode("config", "vendor-dir", .{ .string = "lib/vendor" }));
    try testing.expect(try doc.addSubNode("config", "sort-packages", .{ .bool = true }));
    try testing.expectEqualStrings(
        \\{
        \\    "name": "acme/app",
        \\    "config": {
        \\        "vendor-dir": "lib/vendor",
        \\        "sort-packages": true
        \\    }
        \\}
        \\
    , try doc.output());

    // Setting an existing key replaces only its value.
    try testing.expect(try doc.addSubNode("config", "sort-packages", .{ .bool = false }));
    try testing.expect(std.mem.indexOf(u8, doc.contents, "\"sort-packages\": false") != null);
}

test "strnatcmp orders embedded numbers numerically" {
    // The case strcmp gets wrong: "8" sorts before "72" alphabetically.
    try testing.expect(natCompare("polyfill-php8", "polyfill-php72") < 0);
    try testing.expect(natCompare("php10", "php9") > 0);
    try testing.expect(natCompare("a", "a") == 0);
    try testing.expect(natCompare("a1b", "a1b") == 0);
    try testing.expect(natCompare("", "a") < 0);
}
