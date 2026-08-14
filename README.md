# zigcache

Function-call caching keyed on a checksum of the function's source and its
arguments.

```
cache.zig      library: comptime argument hashing, memo wrappers, disk store
analyser.zig   tool: transitive source checksum + purity checks
demo.zig       example: pure functions, cached wrappers, and a main
impure.zig     example: functions that falsely claim purity, and a main
```

```sh
zig build test                       # runtime tests
zig build run                        # the caching demo; run it twice
zig build run-impure                 # why the impure examples cannot be cached
zig-out/bin/zigcache impure.zig      # the analyser; exits 1 with 5 violations
```

## The key

```
key = sha256( function identity || canonical encoding of the arguments )
```

**Function identity** is not the checksum of one function body. A cache keyed
on that goes stale the moment a callee changes. It is a checksum over the
target function **and every top-level declaration it transitively references**:
callees, consts, and type declarations.

**Canonical** means two things hash alike exactly when a pure function cannot
tell them apart. For source, that is the token stream — `//` comments are not
tokens in Zig, so reformatting and rewording cannot invalidate a cache entry.
For arguments, pointers are followed, all NaNs collapse to one value, `-0.0`
meets `+0.0`, and the type name is part of the encoding so `u32(1)` ≠ `u64(1)`.

## Using it

```zig
const cache = @import("cache");
const ids = @import("cache_ids");

///cache:pure
pub fn score(xs: []const f64, w: Weights) f64 { ... }

const cachedScore = cache.Memo(ids.score, score).call;

cachedScore(.{ xs, w });
```

`build.zig` runs the analyser as a build step, so ids regenerate whenever the
analysed source changes and the generated file never lands in the source tree:

```zig
const gen = b.addRunArtifact(analyser);
gen.addFileArg(b.path("demo.zig"));
const ids_file = gen.addOutputFileArg("cache_ids.zig");
demo_mod.addAnonymousImport("cache_ids", .{ .root_source_file = ids_file });
```

## It works

Cold, then warm in a second process:

```
slowFib(34)        MISS    36589us -> 5702887  |  slowFib(34)     HIT  127us
slowFib(34)        HIT        73us -> 5702887  |  slowFib(34)     HIT   22us
score              MISS       42us -> 2.53     |  score           HIT   33us
score              HIT        26us -> 2.53     |  score           HIT   27us
score (copy)       HIT        24us -> 2.53     |  score (copy)    HIT   27us
score (changed)    MISS       33us -> 2.532    |  score (changed) HIT   27us
hits=3 misses=3                                |  hits=6 misses=0
```

`score (copy)` passes a different backing array with the same contents and
hits, because the key is the contents.

Editing `const scale` — which only `score` reaches, two calls down through
`normalise` — invalidates exactly the right entries, with nobody having to
remember to:

```
slowFib(34)        HIT       114us -> 5702887     <- identity unchanged
score              MISS       75us -> 2.8         <- recomputed, new value (was 2.53)
score              HIT        26us -> 2.8
```

Verified invalidation semantics:

| change to `demo.zig` | `score` | `slowFib` |
|---|---|---|
| baseline | `e097fddc` | `035410b0` |
| rewrote a doc comment, added `//` comment and blank lines | `e097fddc` | `035410b0` |
| renamed a local in callee `sum` | `86355b44` | `035410b0` |
| `const scale` 1000 → 100, read via `normalise` | `cac91ad2` | `035410b0` |
| added a field to `Weights` | `fe9e5b80` | `035410b0` |

## `///cache:pure` is a promise, not a proof

There is no allowlist of blessed namespaces or builtins. Whether `std.foo.bar`
is pure is not a question a syntactic pass can answer, and guessing is worse
than not guessing in both directions: a false positive blocks correct code, and
a false negative is the dangerous one — it reads as a guarantee that was never
checked.

So the annotation is the author's assertion and the tool takes it. What it
still reports is only what it can observe directly, offered as a service rather
than a gate:

- reaching a container-level `var`, transitively through callees
- mutating through a parameter, which contradicts the promise
- parameters whose values cannot be hashed at all: `anytype` and function
  parameters

`impure.zig` is split along exactly that line — five functions the analyser
catches, two it knowingly does not. `zig build run-impure` shows all of them
returning different answers for the same arguments.

Worth noting how visible impurity is in Zig anyway: reaching the outside world
mostly means taking an `Io` or an allocator, so it shows up in the signature.
A function that takes neither is already close to pure by construction.

## Arguments

`///cache:pure` is the only annotation. There is deliberately no per-parameter
opt-in for pointers and slices.

- **value types** (numbers, bools, enums, arrays, structs of those) — hashed
  as-is
- **pointers and slices** — hashed by content, following the pointer. That is
  the only sound choice: a pure function cannot observe an address, so hashing
  identity would be wrong in every case. And that nobody mutates the referent
  behind the cache's back is already part of what `///cache:pure` asserts —
  asking for the same promise twice is ceremony, not safety.
- **`anytype`, function parameters** — rejected. No hashable content.

An earlier version required `///cache:deep <names>` on every reference
parameter. It was dropped for the same reason the namespace allowlists were: a
directive that can only ever say one thing is not a decision, and re-stating a
promise `///cache:pure` already covers does not make it any more true.

## The runtime is all comptime

`@typeInfo` resolves the whole argument encoding and result layout at compile
time. There is no runtime reflection and no encoder, and a type that cannot be
cached is a compile error at the `Memo` call site:

```
error: zigcache: result type []const u8 contains a pointer; a cached result must be self-contained
error: zigcache: cannot hash *const fn (u32) u32; a function has no content a pure function could depend on
```

One wrinkle worth recording: structs are hashed *structurally* — field count,
names, types — rather than by `@typeName`. For an anonymous tuple holding
comptime-known values, `@typeName` embeds the values themselves, so two
argument tuples a pure function could not tell apart would otherwise have
produced different keys. The NaN test caught that.

## Known limits

- **Single file.** The checksum covers one file's top-level declarations.
  Anything imported is invisible to it, which is the largest correctness gap:
  a pure function calling into another module of your own project will not
  invalidate when that module changes.
- **Results must be self-contained.** `assertStorable` rejects any result
  containing a pointer, so returning a `[]const u8` from a cached function is a
  compile error rather than a supported case. Lifting it means writing a
  serialiser and deciding who owns the memory a decoded value lands in.
- **Dependency extraction matches identifiers by name**, so a local shadowing a
  top-level name creates a false dependency. Over-approximating is the safe
  direction — a spurious miss, never a stale hit — but the fix needs real scope
  resolution, and `std.zig.Ast` is purely syntactic. `AstGen`/`Zir` is the
  compiler's own lowering rather than a name-resolution API you would want to
  drive from outside.
- **Structural checks are token patterns.** `std.zig.Ast` has no generic walker
  (no `ast.Inspect` equivalent), so `checkBody`'s mutation-through-parameter
  check matches a token sequence rather than inspecting assignment nodes.
- **No eviction, no size bound, no TTL** on the disk store.

## History

This started as a Go prototype (`purecache`) built to compare the two
languages, on the theory that `go/ast` + `go/types` would make the analyser
easier. That was wrong: `std.zig.Ast` is a complete parser with a canonical
printer and typed accessors, and the port came out at 358 lines against Go's
685 — with a canonicalisation that cannot silently include comments, where the
Go version needed comment fields cleared on six node types and got it wrong on
the first attempt.

The Go prototype was removed once the comparison was settled. It is still in
the history at commit `05813da`.
