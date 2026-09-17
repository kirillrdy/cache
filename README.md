# zimo

Function-call caching keyed on a checksum of the function's source and its arguments.

```
zimo.zig       library: memo wrappers, comptime argument hashing, disk store
identity.zig   library: transitive source checksum, computed at comptime
demo.zig       example: ONNX YOLOv3 inference with cached execution
```

```sh
zig build test                       # runtime tests
zig build run                        # object detection demo; run twice to see cache hit
```

The demo needs nothing installed beyond a GPU driver. Inference runs on the [onnx](https://github.com/kirillrdy/onnx) package, a Zig ONNX runtime with OpenCL, CUDA and Metal backends (OpenCL by default; pass `-Dbackend=cuda` or `-Dbackend=metal`), and the model and test image are fetched by the build.

## The key

```
key = sha256( function identity || canonical encoding of the arguments )
```

**Function identity** is not just the checksum of a single function body. A cache keyed on that would go stale the moment a helper function, constant, or type definition changes. Instead, it is a checksum computed over the target function **and every top-level declaration it transitively references**: callees, constants, and type declarations.

**Canonical** means two things hash alike exactly when a pure function cannot tell them apart:
- **Source**: Token stream hashing. In Zig, `//` comments and whitespace are not tokens, so reformatting or rewriting comments will not invalidate a cache entry.
- **Arguments**: Pointers and slices are followed to hash their contents, all NaNs collapse to a single canonical value, `-0.0` equals `+0.0`, and the type name is part of the encoding (e.g. `u32(1)` ≠ `u64(1)`).

## Using it

```zig
const std = @import("std");
const zimo = @import("zimo");

const here = zimo.bind(@This(), @embedFile("my_module.zig"));

pub fn score(xs: []const f64, w: Weights) f64 { ... }

// Initialize disk cache store (optional, enables cross-process persistence)
try zimo.open(allocator, io, ".zimo");
defer zimo.close();

// Call memoised function
const result = here.call(.score, .{ xs, w });
```

That is the entire setup. One binding per file, one line per cached call. No code generation step, no build artifacts to wire up, and no risk of the checksum going out of sync with the source — the compiler derives the identity directly from the file bytes at compile time.

## How it works at comptime

Zig's `std.zig.Tokenizer` and `std.crypto.hash.sha2.Sha256` do not allocate, meaning **they run entirely at compile time**.

`identity.zig` tokenizes the `@embedFile`'d source during compilation, identifies container-level declarations by tracking brace depth, builds the transitive closure of referenced symbols, and computes the SHA-256 hash — all before runtime execution begins.

Because `std.zig.Ast` allocates while `std.zig.Tokenizer` does not, declaration boundaries are resolved via brace depth. This provides container-level granularity without requiring memory allocation at comptime.

## Invalidation semantics

Invalidations track transitive dependencies with declaration-level precision:

| Change to source | Target function identity | Unrelated function identity |
|---|---|---|
| Edit unrelated function (`main`) | **Unchanged** | **Unchanged** |
| Rewrite doc comments, add `//` comments, reformat | **Unchanged** | **Unchanged** |
| Rename a local variable in a referenced callee | **Changed** | **Unchanged** |
| Modify a referenced `const` value | **Changed** | **Unchanged** |
| Add or change a field in a referenced `struct` | **Changed** | **Unchanged** |

Granularity comes from the transitive dependency graph rather than file-level checksums, ensuring unrelated edits do not cause false cache invalidations.

## Purity and correctness

The library requires no manual annotations or compiler directives. Deciding whether arbitrary code is semantically pure cannot be solved syntactically, so `Memo` verifies structural guarantees at compile time via `@typeInfo`:

- **Arguments** must have hashable content (e.g. no `anytype`, no function pointers).
- **Pointers and slices** in arguments are hashed by value/contents, not memory addresses.
- **Results** must be storable (value types or slices). Single unmanaged pointers (`*T`) are rejected because their pointee lifetime cannot be safely restored across processes.
- **Environment arguments** (`std.mem.Allocator`, `std.Io`) are recognized and left out of the key; a slice result is allocated with the allocator given to `zimo.open` on a cache hit.

## Supported types

- **Value types** (integers, floats, bools, enums, arrays, structs) — hashed and stored by value.
- **Slices** (`[]T`, `[]const u8`, etc.) — arguments hashed by element contents; slice return types are stored to disk and re-allocated via the caller's allocator on cache hits.
- **Pointers** (`*const T`) — argument referents are dereferenced and hashed by content. Single pointer return types are rejected at compile time.
- **Structs** — hashed structurally (field names, types, and values) rather than by `@typeName`, ensuring anonymous tuples with comptime values hash predictably.

## Known limits

- **Single file scope**: Transitive dependency hashing currently inspects declarations within the embedded file. External `@import` modules are not yet transitively walked.
- **Lexical dependency extraction**: Identifier references are matched by symbol name. A local variable that shadows a top-level declaration will over-approximate dependencies (causing a safe miss, never a stale hit).
- **Disk store**: The default store does not implement eviction policies, size quotas, or TTL.
