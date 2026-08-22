# Building bwa 0.7.17 with Flox

A build-only Flox environment that compiles [bwa](https://github.com/lh3/bwa)
0.7.17 from source **for the three target systems** (x86_64-linux, aarch64-linux,
aarch64-darwin), for publishing to the `flox-labs`
catalog. The recipe is a Nix-expression build at
[`.flox/pkgs/bwa/default.nix`](.flox/pkgs/bwa/default.nix).

```bash
flox build bwa          # -> ./result-bwa  (native to the current system)
./result-bwa/bin/bwa    # Version: 0.7.17-r1188
```

---

## Why this can't just be `flox install`

The Flox catalog has `bwa@0.7.17`, but **only for x86_64** (`x86_64-linux`,
`x86_64-darwin`); there is no aarch64 build. bwa 0.7.17 (2017) hard-codes x86
**SSE2 intrinsics** (`#include <emmintrin.h>` in `ksw.c`) and predates upstream
ARM support, so on aarch64 it fails with `fatal error: emmintrin.h: No such file
or directory`. That's the gap this build closes: a bwa 0.7.17 that compiles on
aarch64 too, so `flox-labs/bwa` covers the three target systems at the exact version.
(The catalog already has x86_64-darwin, which isn't a target here.)

## The two things the recipe restores

### 1. aarch64: shim x86 SSE2 → ARM NEON with sse2neon

On aarch64 there is no system `<emmintrin.h>`. We drop in
[sse2neon](https://github.com/DLTcollab/sse2neon), a header that maps Intel SSE2
intrinsics onto ARM NEON, under the name for which bwa reaches, and put it first on
the include path so bwa's SIMD code compiles unchanged:

```nix
postPatch = lib.optionalString stdenv.hostPlatform.isAarch64 ''
  cp ${sse2neon}/sse2neon.h .
  printf '#include "sse2neon.h"\n' > emmintrin.h
'';
env.NIX_CFLAGS_COMPILE = "-fcommon" + lib.optionalString isAarch64 " -I. -D__SSE2__";
```

> **Reusable lesson.** Old x86-SIMD C code (`emmintrin.h`/`<*mmintrin.h>`) is the
> usual reason a pre-ARM release is x86-only. `sse2neon` (SSE→NEON) and `simde`
> (broader) are header-only translators; provide the header under the name the
> code includes and add `-I.`; you rarely need to touch the source.

### 2. modern gcc: `-fcommon`

gcc ≥ 10 defaults to `-fno-common`, which turns bwa 0.7.17's tentative global
definitions (`bwa_verbose`, `bwa_rg_id`, …) into "multiple definition" link
errors. `-fcommon` restores the old behavior. (This is also why the original
Dockerfile pinned `gcc-9`.)

Sources are hash-pinned (`fetchFromGitHub` for both bwa and sse2neon); no
build-time network beyond those.

---

## Verifying + publishing across platforms

`flox build`/`flox publish` build **natively for the current system**, so the
full-platform `flox-labs/bwa` is produced by running the build on each target:

| System | How it builds | Status |
|---|---|---|
| x86_64-linux | native SSE2 | ✅ built, published, `bwa 0.7.17-r1188` indexes + aligns |
| aarch64-linux | sse2neon shim | ✅ built and published |
| aarch64-darwin | sse2neon shim | ✅ built and published |

The aarch64 path (sse2neon + `-D__SSE2__`) has since been built on both aarch64
targets. `flox show flox-labs/bwa` lists all three systems, and since `flox publish`
builds natively, a system appearing there means the build succeeded on it.

On each platform:

```bash
flox build bwa                       # native build for that system
./result-bwa/bin/bwa                 # sanity: Version: 0.7.17-r1188
flox publish -o flox-labs bwa        # needs a clean, pushed git tree
```

Once published on all three, `flox-labs/bwa` resolves everywhere and the runtime
env `wgs/bwa_0-7-17` installs it uniformly.
