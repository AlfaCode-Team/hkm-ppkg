//! `auth.json`, `COMPOSER_AUTH`, and the `config` credential blocks.
//!
//! Without this, a private package is not "slow" or "degraded" — it is a 404
//! that looks like the package does not exist. Composer says
//! `Could not find a matching version of package acme/private`, which sends
//! the reader to look for a typo in a name that is spelled correctly. So the
//! goal here is not only to send the right header but to make the failure
//! legible when there is no credential to send.
//!
//! ## Where a credential comes from, and which one wins
//!
//! Composer merges four sources, and a later merge overwrites an earlier one
//! for the same key. In ascending precedence:
//!
//!   1. `$COMPOSER_HOME/auth.json`      — the machine's credentials
//!   2. `composer.json` → `config`      — the project's, committed
//!   3. `<project>/auth.json`           — the project's, NOT committed
//!   4. `$COMPOSER_AUTH`                — the environment, usually CI
//!
//! That order is Composer's, from `Factory::createConfig` and
//! `Factory::createComposer`: the home file is merged into the config first,
//! the local `auth.json` after the project manifest, and `loadComposerAuthEnv`
//! runs last in both paths. CI overriding a checked-in credential is the
//! property that matters, and it falls out of the ordering rather than being
//! special-cased.
//!
//! ## One deliberate divergence
//!
//! Composer's GitHub driver reads file contents from `api.github.com`, so
//! `AuthHelper::findAuthOrigin` only needs to map `api.github.com` back to
//! `github.com`. This package deliberately reads from
//! `raw.githubusercontent.com` and `codeload.github.com` instead — that is the
//! whole reason it is not rate-limited — so both are mapped to `github.com`
//! here as well. Without the mapping a `github-oauth` token would authenticate
//! the resolve and then silently fail to authenticate the download of the very
//! package it resolved.
//!
//! `GITHUB_TOKEN` / `GH_TOKEN` are also read, at the LOWEST precedence, which
//! Composer does not do. It is an addition rather than a compatibility claim,
//! and it is documented as one: in CI those variables are present for free, and
//! the alternative is 60 requests an hour shared with everything else on the
//! runner.
//!
//! ## What is never done here
//!
//! No credential is ever written to a cache path, a log line, a lock file or an
//! error message. `Credential.redacted` exists so that reporting which
//! credential was used cannot become reporting the credential.

const std = @import("std");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

/// How a credential is presented on the wire.
pub const Scheme = enum {
    /// `Authorization: Basic base64(user:pass)`
    basic,
    /// `Authorization: Bearer <token>`
    bearer,
    /// `Authorization: token <token>` — GitHub's own spelling.
    github_token,
    /// `PRIVATE-TOKEN: <token>` — GitLab personal/project access tokens.
    gitlab_private,
    /// `custom-headers` — whatever the operator wrote, verbatim.
    ///
    /// The escape hatch for a repository behind something with its own scheme:
    /// a signed proxy header, an API key in a vendor-specific field. Composer
    /// sends the lines as given and so does this.
    custom_headers,
    /// `client-certificate` — mutual TLS.
    ///
    /// Not a header at all, which is why it is the one scheme that changes HOW
    /// the request is made rather than what it carries. See `fetch.zig`.
    client_certificate,
};

pub const Credential = struct {
    /// The origin this applies to, without scheme or port: `github.com`.
    host: []const u8,
    scheme: Scheme,
    username: []const u8 = "",
    password: []const u8 = "",
    /// `custom-headers` — complete `Name: value` lines, as written.
    lines: []const []const u8 = &.{},
    /// `client-certificate` — paths, and the key's passphrase if it has one.
    cert: []const u8 = "",
    key: []const u8 = "",
    passphrase: []const u8 = "",

    pub fn isClientCertificate(self: Credential) bool {
        return self.scheme == .client_certificate;
    }

    /// What may be printed. Never the secret — and for a client certificate
    /// that includes the passphrase, which is the field most likely to be
    /// pasted into an issue by someone debugging a handshake.
    pub fn redacted(self: Credential, allocator: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(allocator, "{s} ({s})", .{ self.host, @tagName(self.scheme) }) catch self.host;
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Store = struct {
    credentials: []const Credential = &.{},

    /// The credential for a URL, or none.
    pub fn forUrl(self: Store, url: []const u8) ?Credential {
        const host = hostOf(url) orelse return null;
        return self.forHost(host);
    }

    pub fn forHost(self: Store, host: []const u8) ?Credential {
        // Exact origin first, as Composer does.
        for (self.credentials) |c| {
            if (std.ascii.eqlIgnoreCase(c.host, host)) return c;
        }
        // Then the canonical origin an API/content host belongs to.
        if (canonicalOrigin(host)) |canonical| {
            for (self.credentials) |c| {
                if (std.ascii.eqlIgnoreCase(c.host, canonical)) return c;
            }
        }
        return null;
    }

    /// The HTTP header to send with a request to `url`, or none.
    ///
    /// The single-header convenience. `custom-headers` can carry several, so
    /// anything that actually makes a request uses `headersFor`.
    pub fn header(self: Store, allocator: std.mem.Allocator, url: []const u8) ?Header {
        const all = self.headersFor(allocator, url);
        return if (all.len == 0) null else all[0];
    }

    /// Every header a request to `url` should carry.
    pub fn headersFor(self: Store, allocator: std.mem.Allocator, url: []const u8) []const Header {
        const cred = self.forUrl(url) orelse return &.{};

        if (cred.scheme == .custom_headers) {
            var out: std.ArrayList(Header) = .empty;
            for (cred.lines) |line| {
                // `Name: value`. A line without a colon is not a header, and
                // sending it as one produces a malformed request rather than an
                // error the operator can see — so it is dropped here.
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const name = std.mem.trim(u8, line[0..colon], " \t");
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (name.len == 0) continue;
                out.append(allocator, .{
                    .name = lowered(allocator, name) orelse continue,
                    .value = value,
                }) catch break;
            }
            return out.toOwnedSlice(allocator) catch &.{};
        }

        // A client certificate is presented during the handshake, not in a
        // header. There is nothing to add here, and adding an empty
        // Authorization would be worse than nothing.
        if (cred.scheme == .client_certificate) return &.{};

        const one = headerFor(allocator, cred) orelse return &.{};
        const slice = allocator.alloc(Header, 1) catch return &.{};
        slice[0] = one;
        return slice;
    }

    /// A git remote URL carrying the credential in its userinfo.
    ///
    /// `git ls-remote` has no header to set, so the only way to authenticate an
    /// https remote without an interactive prompt is the userinfo field. The
    /// result is a SECRET: it must not be logged, and it is never written to a
    /// cache key or an error message.
    pub fn gitUrl(self: Store, allocator: std.mem.Allocator, url: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return null;
        const cred = self.forUrl(url) orelse return null;

        const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return null) + 3;
        const rest = url[scheme_end..];
        // Already carries userinfo — leave it alone rather than fight over it.
        if (std.mem.indexOfScalar(u8, rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len], '@') != null) return null;

        const pair = switch (cred.scheme) {
            // Neither can be spelled in a URL. git gets them from its own
            // config (`http.sslCert`), which is the operator's to set.
            .custom_headers, .client_certificate => return null,
            .github_token => .{ cred.username, "x-oauth-basic" },
            .gitlab_private => .{ "private-token", cred.username },
            .bearer => .{ "oauth2", cred.password },
            .basic => .{ cred.username, cred.password },
        };
        return std.fmt.allocPrint(allocator, "{s}{s}:{s}@{s}", .{
            url[0..scheme_end],
            urlEncode(allocator, pair[0]) catch return null,
            urlEncode(allocator, pair[1]) catch return null,
            rest,
        }) catch null;
    }

    pub fn hasAny(self: Store) bool {
        return self.credentials.len > 0;
    }

    /// The client certificate for `url`, when there is one.
    pub fn clientCertificate(self: Store, url: []const u8) ?Credential {
        const cred = self.forUrl(url) orelse return null;
        return if (cred.isClientCertificate()) cred else null;
    }
};

fn lowered(allocator: std.mem.Allocator, s: []const u8) ?[]const u8 {
    const out = allocator.alloc(u8, s.len) catch return null;
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn headerFor(allocator: std.mem.Allocator, cred: Credential) ?Header {
    return switch (cred.scheme) {
        // Handled by `headersFor`, which is the only caller that can express
        // "several headers" and "none".
        .custom_headers, .client_certificate => null,
        .github_token => .{
            .name = "authorization",
            .value = std.fmt.allocPrint(allocator, "token {s}", .{cred.username}) catch return null,
        },
        .bearer => .{
            .name = "authorization",
            .value = std.fmt.allocPrint(allocator, "Bearer {s}", .{cred.password}) catch return null,
        },
        .gitlab_private => .{
            .name = "private-token",
            .value = allocator.dupe(u8, cred.username) catch return null,
        },
        .basic => blk: {
            const raw = std.fmt.allocPrint(allocator, "{s}:{s}", .{ cred.username, cred.password }) catch return null;
            const enc = std.base64.standard.Encoder;
            const buf = allocator.alloc(u8, enc.calcSize(raw.len)) catch return null;
            _ = enc.encode(buf, raw);
            break :blk .{
                .name = "authorization",
                .value = std.fmt.allocPrint(allocator, "Basic {s}", .{buf}) catch return null,
            };
        },
    };
}

/// The origin whose credential covers a content host.
///
/// Composer maps only `api.github.com` and `api.bitbucket.org`. The two
/// `*.github*` content hosts are added because this package reads from them by
/// design — see the file header.
fn canonicalOrigin(host: []const u8) ?[]const u8 {
    const map = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "api.github.com", .to = "github.com" },
        .{ .from = "raw.githubusercontent.com", .to = "github.com" },
        .{ .from = "codeload.github.com", .to = "github.com" },
        .{ .from = "objects.githubusercontent.com", .to = "github.com" },
        .{ .from = "api.bitbucket.org", .to = "bitbucket.org" },
    };
    for (map) |m| {
        if (std.ascii.eqlIgnoreCase(host, m.from)) return m.to;
    }
    return null;
}

/// The host of a URL, lower-cased, without userinfo or port.
pub fn hostOf(url: []const u8) ?[]const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return null;
    var rest = url[scheme + 3 ..];

    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    rest = rest[0..end];

    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        // Not an IPv6 literal.
        if (std.mem.indexOfScalar(u8, rest, ']') == null) rest = rest[0..colon];
    }
    return if (rest.len == 0) null else rest;
}

fn urlEncode(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(allocator, c);
        } else {
            try out.print(allocator, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── loading ───────────────────────────────────────────────────────────────────

/// Read every credential source, lowest precedence first.
pub fn load(
    allocator: std.mem.Allocator,
    io: Io,
    env: ?*EnvMap,
    root_dir: []const u8,
) Store {
    var acc: Accumulator = .{ .allocator = allocator };

    // 0. Environment tokens that are not Composer's, at the very bottom.
    if (env) |e| {
        for ([_][]const u8{ "GH_TOKEN", "GITHUB_TOKEN" }) |name| {
            const v = e.get(name) orelse continue;
            if (v.len == 0) continue;
            acc.put(.{ .host = "github.com", .scheme = .github_token, .username = v });
        }
    }

    // 1. $COMPOSER_HOME/auth.json
    if (composerHome(allocator, env)) |home| {
        const path = std.fs.path.join(allocator, &.{ home, "auth.json" }) catch return acc.finish();
        acc.mergeFile(io, path);
    }

    // 2. composer.json → config
    {
        const path = std.fs.path.join(allocator, &.{ root_dir, "composer.json" }) catch return acc.finish();
        if (readJson(allocator, io, path)) |root| {
            if (root == .object) {
                if (root.object.get("config")) |cfg| {
                    if (cfg == .object) acc.mergeConfig(cfg.object);
                }
            }
        }
    }

    // 3. <project>/auth.json
    {
        const path = std.fs.path.join(allocator, &.{ root_dir, "auth.json" }) catch return acc.finish();
        acc.mergeFile(io, path);
    }

    // 4. $COMPOSER_AUTH
    if (env) |e| {
        if (e.get("COMPOSER_AUTH")) |raw| {
            if (raw.len > 0) {
                if (std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{}) catch null) |v| {
                    if (v == .object) acc.mergeConfig(v.object);
                }
            }
        }
    }

    return acc.finish();
}

/// `$COMPOSER_HOME`, else the platform default Composer itself uses.
pub fn composerHome(allocator: std.mem.Allocator, env: ?*EnvMap) ?[]const u8 {
    const e = env orelse return null;
    if (e.get("COMPOSER_HOME")) |v| {
        if (v.len > 0) return allocator.dupe(u8, util.trimSlash(v)) catch null;
    }
    const home = e.get("HOME") orelse return null;
    if (home.len == 0) return null;

    // Composer prefers XDG when any XDG_ variable is set, and `~/.composer`
    // otherwise; on macOS it uses `~/.composer` unless XDG is in play.
    if (e.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(allocator, &.{ util.trimSlash(xdg), "composer" }) catch null;
    }
    return std.fs.path.join(allocator, &.{ util.trimSlash(home), ".composer" }) catch null;
}

const Accumulator = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(Credential) = .empty,

    /// Later sources replace earlier ones for the same host.
    fn put(self: *Accumulator, cred: Credential) void {
        for (self.list.items) |*existing| {
            if (std.ascii.eqlIgnoreCase(existing.host, cred.host)) {
                existing.* = cred;
                return;
            }
        }
        self.list.append(self.allocator, cred) catch {};
    }

    fn mergeFile(self: *Accumulator, io: Io, path: []const u8) void {
        const v = readJson(self.allocator, io, path) orelse return;
        if (v != .object) return;
        self.mergeConfig(v.object);
    }

    /// An `auth.json` is the credential block itself; a `composer.json`
    /// `config` is that block plus everything else. Reading both with one
    /// function is safe because only the credential keys are looked at.
    fn mergeConfig(self: *Accumulator, obj: std.json.ObjectMap) void {
        // Order within one source matters only when a host appears twice, which
        // means the file contradicts itself. Composer's own order is kept so
        // that it resolves the same way.
        self.simpleTokens(obj, "github-oauth", .github_token);
        self.gitlabOauth(obj);
        self.gitlabTokens(obj);
        self.pairs(obj, "bitbucket-oauth", "consumer-key", "consumer-secret");
        self.pairs(obj, "http-basic", "username", "password");
        self.bearer(obj);
        self.customHeaders(obj);
        self.clientCertificates(obj);
    }

    fn simpleTokens(self: *Accumulator, obj: std.json.ObjectMap, key: []const u8, scheme: Scheme) void {
        const block = objectAt(obj, key) orelse return;
        var it = block.iterator();
        while (it.next()) |e| {
            const token = stringOf(e.value_ptr.*) orelse continue;
            self.put(.{ .host = e.key_ptr.*, .scheme = scheme, .username = token });
        }
    }

    fn gitlabOauth(self: *Accumulator, obj: std.json.ObjectMap) void {
        const block = objectAt(obj, "gitlab-oauth") orelse return;
        var it = block.iterator();
        while (it.next()) |e| {
            // Composer accepts both `"host": "token"` and `"host": {"token": …}`.
            const token = switch (e.value_ptr.*) {
                .string => |s| s,
                .object => |o| stringOf(o.get("token") orelse continue) orelse continue,
                else => continue,
            };
            self.put(.{ .host = e.key_ptr.*, .scheme = .bearer, .password = token });
        }
    }

    fn gitlabTokens(self: *Accumulator, obj: std.json.ObjectMap) void {
        const block = objectAt(obj, "gitlab-token") orelse return;
        var it = block.iterator();
        while (it.next()) |e| {
            switch (e.value_ptr.*) {
                // A bare string is a PRIVATE-TOKEN, not basic auth: Composer
                // sets the password to the literal `private-token`, which
                // `addAuthenticationOptions` then recognises.
                .string => |s| self.put(.{ .host = e.key_ptr.*, .scheme = .gitlab_private, .username = s }),
                .object => |o| {
                    const user = stringOf(o.get("username") orelse continue) orelse continue;
                    const token = stringOf(o.get("token") orelse continue) orelse continue;
                    self.put(.{ .host = e.key_ptr.*, .scheme = .basic, .username = user, .password = token });
                },
                else => continue,
            }
        }
    }

    fn pairs(self: *Accumulator, obj: std.json.ObjectMap, key: []const u8, a: []const u8, b: []const u8) void {
        const block = objectAt(obj, key) orelse return;
        var it = block.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .object) continue;
            const o = e.value_ptr.*.object;
            const user = stringOf(o.get(a) orelse continue) orelse continue;
            const pass = stringOf(o.get(b) orelse continue) orelse continue;
            self.put(.{ .host = e.key_ptr.*, .scheme = .basic, .username = user, .password = pass });
        }
    }

    fn bearer(self: *Accumulator, obj: std.json.ObjectMap) void {
        const block = objectAt(obj, "bearer") orelse return;
        var it = block.iterator();
        while (it.next()) |e| {
            const token = stringOf(e.value_ptr.*) orelse continue;
            self.put(.{ .host = e.key_ptr.*, .scheme = .bearer, .password = token });
        }
    }

    fn customHeaders(self: *Accumulator, obj: std.json.ObjectMap) void {
        const block = objectAt(obj, "custom-headers") orelse return;
        var it = block.iterator();
        while (it.next()) |e| {
            // Composer accepts a list of lines, and `null` to mean "no headers
            // for this host" — which is how a project turns off a header the
            // machine's own auth.json set.
            const array = switch (e.value_ptr.*) {
                .array => |a| a,
                else => continue,
            };
            var lines: std.ArrayList([]const u8) = .empty;
            for (array.items) |item| {
                if (item == .string) lines.append(self.allocator, item.string) catch break;
            }
            if (lines.items.len == 0) continue;
            self.put(.{
                .host = e.key_ptr.*,
                .scheme = .custom_headers,
                .lines = lines.toOwnedSlice(self.allocator) catch continue,
            });
        }
    }

    fn clientCertificates(self: *Accumulator, obj: std.json.ObjectMap) void {
        const block = objectAt(obj, "client-certificate") orelse return;
        var it = block.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .object) continue;
            const o = e.value_ptr.*.object;
            // `local_cert` is the only required field: a PEM holding both the
            // certificate and the key is the common shape, and demanding
            // `local_pk` would reject it.
            const cert = stringOf(o.get("local_cert") orelse continue) orelse continue;
            self.put(.{
                .host = e.key_ptr.*,
                .scheme = .client_certificate,
                .cert = cert,
                .key = if (o.get("local_pk")) |v| stringOf(v) orelse "" else "",
                .passphrase = if (o.get("passphrase")) |v| stringOf(v) orelse "" else "",
            });
        }
    }

    fn finish(self: *Accumulator) Store {
        return .{ .credentials = self.list.toOwnedSlice(self.allocator) catch &.{} };
    }
};

fn objectAt(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn stringOf(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn readJson(allocator: std.mem.Allocator, io: Io, path: []const u8) ?std.json.Value {
    const bytes = Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch return null;
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{}) catch null;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn storeFrom(allocator: std.mem.Allocator, json: []const u8) Store {
    var acc: Accumulator = .{ .allocator = allocator };
    const v = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch unreachable;
    acc.mergeConfig(v.object);
    return acc.finish();
}

test "a github token is sent in GitHub's own spelling, not as basic auth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const store = storeFrom(a, "{\"github-oauth\": {\"github.com\": \"ghp_secret\"}}");
    const h = store.header(a, "https://api.github.com/repos/x/y/zipball/abc").?;
    try testing.expectEqualStrings("authorization", h.name);
    try testing.expectEqualStrings("token ghp_secret", h.value);
}

test "the content hosts this package reads from resolve to the github.com credential" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The divergence documented in the header: Composer never asks these hosts
    // for a file, so it never had to map them. Without the mapping a private
    // package resolves and then fails to download.
    const store = storeFrom(a, "{\"github-oauth\": {\"github.com\": \"tok\"}}");
    for ([_][]const u8{
        "https://raw.githubusercontent.com/o/r/sha/composer.json",
        "https://codeload.github.com/o/r/legacy.zip/sha",
        "https://api.github.com/repos/o/r/zipball/sha",
    }) |url| {
        try testing.expect(store.forUrl(url) != null);
    }

    // And an unrelated host gets nothing.
    try testing.expect(store.forUrl("https://evil.example.com/o/r") == null);
}

test "a gitlab-token string is a PRIVATE-TOKEN header, an object is basic auth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bare = storeFrom(a, "{\"gitlab-token\": {\"gitlab.com\": \"glpat-x\"}}");
    const h1 = bare.header(a, "https://gitlab.com/api/v4/x").?;
    try testing.expectEqualStrings("private-token", h1.name);
    try testing.expectEqualStrings("glpat-x", h1.value);

    const paired = storeFrom(a, "{\"gitlab-token\": {\"gitlab.com\": {\"username\": \"u\", \"token\": \"t\"}}}");
    const h2 = paired.header(a, "https://gitlab.com/x").?;
    try testing.expectEqualStrings("authorization", h2.name);
    try testing.expectEqualStrings("Basic dTp0", h2.value); // base64("u:t")
}

test "http-basic and bearer produce the headers their names promise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const basic = storeFrom(a, "{\"http-basic\": {\"repo.example.com\": {\"username\": \"u\", \"password\": \"p\"}}}");
    try testing.expectEqualStrings("Basic dTpw", basic.header(a, "https://repo.example.com/packages.json").?.value);

    const bearer_store = storeFrom(a, "{\"bearer\": {\"repo.example.com\": \"tok\"}}");
    try testing.expectEqualStrings("Bearer tok", bearer_store.header(a, "https://repo.example.com/x").?.value);
}

test "a later source replaces an earlier one for the same host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The CI-overrides-checked-in-credential property, at the level it is
    // actually implemented: `put` replaces rather than appends.
    var acc: Accumulator = .{ .allocator = a };
    acc.put(.{ .host = "github.com", .scheme = .github_token, .username = "from-home" });
    acc.put(.{ .host = "github.com", .scheme = .github_token, .username = "from-env" });
    const store = acc.finish();

    try testing.expectEqual(@as(usize, 1), store.credentials.len);
    try testing.expectEqualStrings("from-env", store.credentials[0].username);
}

test "a host is extracted without its userinfo or port" {
    try testing.expectEqualStrings("github.com", hostOf("https://github.com/a/b").?);
    try testing.expectEqualStrings("github.com", hostOf("https://user:pw@github.com/a/b").?);
    try testing.expectEqualStrings("repo.example.com", hostOf("https://repo.example.com:8443/x").?);
    try testing.expectEqualStrings("gitlab.com", hostOf("https://gitlab.com").?);
    try testing.expect(hostOf("/not/a/url") == null);
}

test "a git remote carries the credential in userinfo, url-encoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const store = storeFrom(a, "{\"github-oauth\": {\"github.com\": \"ghp_a/b\"}}");
    try testing.expectEqualStrings(
        "https://ghp_a%2Fb:x-oauth-basic@github.com/o/r.git",
        store.gitUrl(a, "https://github.com/o/r.git").?,
    );

    // An ssh remote has no userinfo slot to fill, and one already carrying
    // credentials is left exactly as the author wrote it.
    try testing.expect(store.gitUrl(a, "git@github.com:o/r.git") == null);
    try testing.expect(store.gitUrl(a, "https://me:pw@github.com/o/r.git") == null);
}

test "a credential never prints its secret" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cred: Credential = .{ .host = "github.com", .scheme = .github_token, .username = "ghp_secret" };
    const shown = cred.redacted(a);
    try testing.expect(std.mem.indexOf(u8, shown, "ghp_secret") == null);
    try testing.expect(std.mem.indexOf(u8, shown, "github.com") != null);
}

test "custom-headers are sent verbatim, and several of them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const store = storeFrom(a,
        \\{"custom-headers": {"repo.example.com": ["X-Api-Key: abc", "X-Tenant: acme"]}}
    );
    const headers = store.headersFor(a, "https://repo.example.com/packages.json");
    try testing.expectEqual(@as(usize, 2), headers.len);
    try testing.expectEqualStrings("x-api-key", headers[0].name);
    try testing.expectEqualStrings("abc", headers[0].value);
    try testing.expectEqualStrings("x-tenant", headers[1].name);
    try testing.expectEqualStrings("acme", headers[1].value);

    // A line that is not a header at all is dropped rather than sent — an
    // unparseable header produces a malformed request, not a visible error.
    const broken = storeFrom(a, "{\"custom-headers\": {\"h.example\": [\"not-a-header\", \"X-Ok: 1\"]}}");
    const kept = broken.headersFor(a, "https://h.example/x");
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("x-ok", kept[0].name);
}

test "a client certificate is not a header, and never reaches a git url" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const store = storeFrom(a,
        \\{"client-certificate": {"mtls.example": {
        \\  "local_cert": "/etc/ssl/client.pem",
        \\  "local_pk": "/etc/ssl/client.key",
        \\  "passphrase": "s3cret"
        \\}}}
    );

    // Presented during the handshake. An empty Authorization would be worse
    // than none at all.
    try testing.expectEqual(@as(usize, 0), store.headersFor(a, "https://mtls.example/x").len);

    const cert = store.clientCertificate("https://mtls.example/x").?;
    try testing.expectEqualStrings("/etc/ssl/client.pem", cert.cert);
    try testing.expectEqualStrings("/etc/ssl/client.key", cert.key);

    // Nothing about a certificate can be spelled in a URL, so `git` gets it
    // from its own config rather than from a userinfo field this invented.
    try testing.expect(store.gitUrl(a, "https://mtls.example/o/r.git") == null);

    // And the passphrase must not be printable.
    try testing.expect(std.mem.indexOf(u8, cert.redacted(a), "s3cret") == null);
}

test "a certificate with no separate key file is accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A single PEM holding both is the common shape; requiring `local_pk`
    // would reject it.
    const store = storeFrom(a, "{\"client-certificate\": {\"h.example\": {\"local_cert\": \"/both.pem\"}}}");
    const cert = store.clientCertificate("https://h.example/x").?;
    try testing.expectEqualStrings("/both.pem", cert.cert);
    try testing.expectEqualStrings("", cert.key);

    // And one with no `local_cert` is not a certificate at all.
    const bad = storeFrom(a, "{\"client-certificate\": {\"h.example\": {\"local_pk\": \"/k.pem\"}}}");
    try testing.expect(bad.clientCertificate("https://h.example/x") == null);
}
