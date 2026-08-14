# zigcache

Function-call caching keyed on a checksum of the function's source and its
arguments.

```
cache.zig      library: memo wrappers, comptime argument hashing, disk store
identity.zig   library: transitive source checksum, computed at comptime
demo.zig       example: pure functions, cached wrappers, and a main
impure.zig     example: impure functions and a main
```

```sh
zig build test                       # runtime tests
zig build run                        # the caching demo; run it twice
zig build run-impure                 # why the impure examples cannot be cached
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

const here = cache.Source(@embedFile("demo.zig"));

pub fn score(xs: []const f64, w: Weights) f64 { ... }

const cachedScore = here.memo("score", score);

cachedScore(.{ xs, w });
```

That is the whole setup. One binding for the file, one line per cached
function. No generated file to import, no build step to wire up, and no way for
the checksum to be stale with respect to the source — the compiler derives it
from the same bytes it is compiling.

## The checksum is computed at comptime

`std.zig.Tokenizer` does not allocate, which means **it runs at compile time**,
and so does `std.crypto.hash.sha2.Sha256`. So `identity.zig` tokenizes
`@embedFile`'d source inside the compiler, finds container-level declarations
by tracking brace depth, walks the transitive closure of the names each one
mentions, and hashes the lot — all before the program exists.

That removes the parts a normal codegen approach needs: no `cache_ids.zig`, no
`addRunArtifact`/`addOutputFileArg` plumbing, no import of a generated module,
and no separate tool that has to be kept in sync with the runtime.

Only a tokenizer is available — `std.zig.Ast` allocates — so declaration
boundaries come from brace depth rather than a parse. That is enough for
container-level declarations, which is all a cache identity needs.

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
| baseline | `bb35898d` | `ec859488` |
| edited `main`, unrelated to either | `bb35898d` | `ec859488` |
| rewrote a doc comment, added `//` comment and blank lines | `bb35898d` | `ec859488` |
| renamed a local in callee `sum` | `3bf28b3e` | `ec859488` |
| `const scale` 1000 → 100, read via `normalise` | `f346a75b` | `ec859488` |
| added a field to `Weights` | `797753f8` | `ec859488` |

The second row matters most: the embedded source is the *whole file*, including
`main` and the wrappers, yet an edit to `main` moves nothing. Granularity comes
from the transitive closure, not from what was embedded.

## Purity and correctness

The library requires no annotations or source directives. There is no allowlist
of blessed namespaces or builtins either. Deciding whether `std.foo.bar` is pure
is not something a syntactic pass can do, and guessing is worse than not guessing:
a false positive blocks correct code, and a false negative reads as a guarantee
that was never checked.

Nothing verifies semantic purity at compile time: `Memo` will happily cache an
impure function if you pass it one. What *is* verified at compile time via
`@typeInfo` are structural guarantees:
- arguments must be hashable by content (e.g. no `anytype`, no function pointers)
- results must be self-contained (no pointers that would dangle across processes)

`impure.zig` demonstrates various forms of impurity — from container-level mutable
state to wall-clock reads — and `zig build run-impure` shows why caching them yields
stale or incorrect results.

In Zig, reaching the outside world mostly means taking an `Io` or an allocator,
which naturally surfaces in the function signature. A function taking neither is
already close to pure by construction.

## Arguments

There is deliberately no per-parameter configuration for pointers and slices.

- **value types** (numbers, bools, enums, arrays, structs of those) — hashed
  as-is
- **pointers and slices** — hashed by content, following the pointer. That is
  the only sound choice: a pure function cannot observe an address, so hashing
  identity would be wrong in every case. And that caller code does not mutate
  the referent behind the cache's back is part of what memoisation assumes.
- **`anytype`, function parameters** — rejected at compile time (no hashable
  content).

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
- **Comptime cost.** Deriving identities runs a tokenizer and SHA-256 inside
  the compiler, with `@setEvalBranchQuota(2_000_000)`. Fine for a file this
  size; a large file with many cached functions would want measuring.
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
