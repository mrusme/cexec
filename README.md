## cexec

[![SEGV 
LICENSE](https://img.shields.io/static/v1?label=SEGV%20LICENSE&message=1.1&labelColor=0060A8&color=ffffff)](https://xn--gckvb8fzb.com/segv/)

**Cached Exec**

[<img src="https://xn--gckvb8fzb.com/images/chatroom.png" width="275">](https://xn--gckvb8fzb.com/contact/)

`cexec` runs a command and caches its output for a specific amount of time, so
that re-running the command won't actually run it but instead return the cached
output. Standard output, standard error and the exit code are passed through
unchanged, which lets you drop a caching layer in front of any command in a
shell script.

## Installation

Prebuilt binaries for Linux, macOS, Windows, FreeBSD, NetBSD and OpenBSD are
attached to every [release][releases]. Building from source needs Zig 0.16 or
newer:

```sh
zig build -Doptimize=ReleaseSafe
```

The binary is written to `zig-out/bin/cexec`.

[releases]: https://github.com/mrusme/cexec/releases

## Usage

Run a program and cache its output for 60 seconds, which is the default:

```sh
cexec echo Hello World
```

Run a program and cache its output for 120 seconds:

```sh
cexec -t 120 curl http://localhost:8080
```

Option parsing stops at the first argument that is not an option, so the command
keeps its own options:

```sh
cexec -t 120 curl -H 'Accept: application/json' http://localhost:8080
```

A lifetime of `0` runs the command every time and refreshes the stored output.

## Encryption

Pass a key with `-k` and the cache entry is encrypted:

```sh
cexec -k hunter2 curl https://api.example.com/private
```

A key given on the command line is visible to anyone who can list processes.
`cexec` therefore also reads it from `CEXEC_KEY`:

```sh
CEXEC_KEY=hunter2 cexec curl https://api.example.com/private
```

Reading an entry with the wrong key, or with no key at all, counts as a cache
miss. The command runs again and replaces the entry, so that whatever it is that
you're building, that depends on the output doesn't break. However, keep in mind
that this might lead to exposing the command output in case the key happens to
end up being empty.

## Cache

Entries are stored as one file per command in `$XDG_CACHE_HOME/cexec/`. When
that variable is unset, `cexec` falls back to `$HOME/.cache/cexec/` on Unix,
`$HOME/Library/Caches/cexec/` on macOS and `%LOCALAPPDATA%\cexec\` on Windows.
Deleting a file, or the whole directory, removes what was cached.

## Library

Everything `cexec` does is available as a Zig module, so the same caching can be
used from your own program without shelling out:

```zig
var result = try cexec.run(gpa, io, .{
    .argv = &.{ "curl", "http://localhost:8080" },
    .ttl = .fromSeconds(120),
    .environ = init.minimal.environ,
});
defer result.deinit(gpa);
```

`result.stdout`, `result.stderr` and `result.exit_code` hold what the command
produced, and `result.outcome` tells you whether it ran or came from the cache.
Add the dependency with `zig fetch --save` and import the `cexec` module.

## License

Copyright © 2026 [マリウス](https://xn--gckvb8fzb.com)

cexec is released under Version 1.1 of the
[SEGV License](https://xn--gckvb8fzb.com/segv/), whose full text is included in
the [LICENSE](LICENSE) file. Go read it, there will be a test on it on Monday.
