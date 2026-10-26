# Dobby upstream patches for MSVC 14.44 compatibility

The Dobby submodule in this directory is pinned to upstream commit
`0932d69` ("Update backend of xnu kernel, and macho_ctx_kit"), which does
not build against MSVC 14.44 (Visual Studio 2022 17.14, the version
shipped in this environment).

This directory carries the patches we apply on top of that pin so that
`cargo build --workspace` and
`cargo build --target x86_64-pc-windows-msvc --package lovely-win --release`
succeed on Windows. The patches are produced with `git format-patch` from
the submodule, so they are stable across `git submodule update --init`
runs as long as the upstream pin stays at `0932d69`.

## Files

| File | Purpose |
|---|---|
| `0001-fix-MSVC-14.44-compatibility.patch` | Five MSVC build error fixes against upstream `0932d69` |
| `0002-fix-MSVC-build-errors-round-2.patch` | Second round: variadic constructor, `const vector<T>&` returns |
| `apply.sh` | Re-applies both patches on top of a fresh submodule checkout |
| `verify.sh` | Sanity check: re-applies patches against a clean checkout and exits 0 if clean |

## When to re-apply

Re-run `apply.sh` whenever:

1. The Dobby submodule pointer changes (e.g. someone runs
   `git submodule update --init --recursive` against a new remote) and the
   submodule lands on a different upstream commit.
2. We bump the upstream Dobby pin in `.gitmodules` to a newer commit.
3. Someone reports that the build broke after a fresh clone.

If the upstream pin moves, regenerate the patches against the new base:

```bash
cd crates/dobby-sys/dobby
git format-patch <new-base>..HEAD -o ../patches
```

## Why this matters

The submodule pointer in the main repo already tracks a custom commit
(`db75236`, see `git ls-tree HEAD crates/dobby-sys/dobby`), so a fresh
clone followed by `cargo build` works out of the box as long as
`git submodule update --init --recursive` is run first. The patches in
this directory are kept for two reasons:

1. **Reproducibility.** Anyone reading this directory can see exactly what
   we changed on top of upstream Dobby, without diffing submodule
   commits.
3. **Recovery.** If the submodule pointer is ever accidentally reset
   upstream (e.g. by a force push or a merge that didn't carry the
   submodule change), `apply.sh` rebuilds the working copy without
   waiting for a manual `git submodule update`.

## What the patches fix (summary)

1. `include/dobby.h` - variadic macro `fn_args_t...` is invalid in MSVC
   strict mode; rewrite with comma-before-`...` and `##__VA_ARGS__`.
2. `source/PlatformUnifiedInterface/platform.h` - add `AllocPageSize`
   (declared on the Windows implementation, missing from the header).
3. `source/Backend/UserMode/UnifiedInterface/platform-windows.cc` -
   rewrite `OSMemory::Allocate/Free/Release/SetPermission` to match the
   header (and the posix implementation) using `size_t` for size args.
4. `source/Backend/UserMode/PlatformUtil/Windows/ProcessRuntimeUtility.cc`
   - `MemRange` has `start/end/size`, not `.address`; the
   `GetProcessMemoryLayout` return type must be `MemRegion` (not
   `MemRange`) to match the header declaration; return
   `const vector<T>&` rather than by value; fix
   `GetProcessModuleMap` to read the right global.
5. `source/Backend/UserMode/ExecMemory/code-patch-tool-windows.cc` -
   `kMemoryOperationError` is referenced but never defined; declare it
   locally.
6. `source/dobby.cpp` - `__attribute__((constructor))` is a GCC/Clang
   extension that MSVC lacks. The constructor only emits a debug log
   on library load, so on MSVC we keep the body but drop the attribute.

## Validation evidence

Built and verified on the host environment:

```
cargo fmt --all -- --check
cargo check -p lovely-core -p lovely-win -p liblovely -p dobby-sys
cargo build -p lovely-core -p lovely-win -p liblovely
cargo build --target x86_64-pc-windows-msvc --package lovely-win --release
```

Last artifact:

```
target/x86_64-pc-windows-msvc/release/winmm.dll (~2.8 MB)
```