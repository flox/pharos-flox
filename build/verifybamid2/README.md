# Building VerifyBamID2 1.0.5 with Flox

A build-only Flox environment that compiles [VerifyBamID2](https://github.com/Griffan/VerifyBamID)
1.0.5 from source, including a pinned htslib and the bundled SVD reference
panels, for publishing to the `flox-labs` catalog. The recipe is a
Nix-expression build at
[`.flox/pkgs/verifybamid2/default.nix`](.flox/pkgs/verifybamid2/default.nix).

```bash
flox build verifybamid2     # -> ./result-verifybamid2
./result-verifybamid2/bin/VerifyBamID    # prints usage
```

---

## Why this can't just be `flox install`

VerifyBamID2 was never in the Flox catalog, and it isn't in nixpkgs. It's a 2018
C++/CMake tool whose build assumes a 2018 world: an old CMake, an old bundled
Eigen, and (the interesting part) a build script that **`git clone`s htslib
from the network at build time.** None of that survives contact with a modern,
hermetic Nix build, so this is the most involved of the three recipes. It's also
the best teaching example, because it exercises nearly every category of problem
you meet porting old native software.

Two themes run through everything below:

1. **A hermetic build has no network and no host tools.** Anything the upstream
   build fetches or assumes-is-installed has to be turned into a pinned,
   pre-provided input.
2. **Modern toolchains are stricter than 2018 ones.** The compiler, the config
   scripts and CMake will all reject things that used to be fine, so you either
   go back in time (older compiler) or nudge the tool forward (flags/patches).

---

## The obstacles, in order, and what each teaches

### 1. The build git-clones htslib → pin it and cut the network

`CMakeLists.txt` has `ExternalProject_Add(HTSLIB GIT_REPOSITORY …github.com/samtools/htslib.git GIT_TAG master)`.
In a pure sandbox there is no network, and "clone master" isn't reproducible
anyway. We replace it with a **pinned Nix source** and pre-place it where the
build expects it:

```nix
htslibSrc = fetchFromGitHub { owner = "samtools"; repo = "htslib"; rev = "1.9"; sha256 = "…"; };
# postPatch: cp -r ${htslibSrc}/. samtools/htslib/
```

> **Reusable lesson.** Any build-time download (`git clone`, `wget`, `pip
> install`, `go get`) must become a hash-pinned Nix fetch provided up front.
> Grep the build system for `GIT_REPOSITORY`, `DOWNLOAD`, `URL`, `curl`, `wget`
> before you start.

### 2. Which htslib? Pin a version *contemporary with the tool*

The upstream build cloned htslib `master`, unpinned. We pin **1.9**, a release
contemporary with this circa-2018 tool, rather than today's 1.2x.

This is a **conservative choice we did not empirically test the alternative to**:
we neither audited which htslib symbols VerifyBamID's `libVcf` actually calls nor
tried building against a current htslib. The reasoning is precautionary, htslib
has deprecated and removed API across its 1.x line, and 2018-era C that links it
is a common place for that drift to surface, so pinning a contemporary release
avoids the question entirely. If you need a newer htslib (e.g. for a CVE fix), the
honest next step is to try it and see what breaks, not to assume 1.9 is required.

> **Reusable lesson.** When you replace a floating `master`/`latest` dependency
> with a pin, a version contemporary with the dependent is the low-risk default —
> the newest release can carry API drift the original author never coded against.
> Treat this as a starting point to validate, not a proven constraint.

### 3. Git sources omit generated autotools files → supply them

htslib's `./configure` (regenerated with `autoheader && autoconf`) immediately
failed: `cannot find required auxiliary files: config.guess config.sub`. Those
files are *generated*, so a git archive doesn't ship them. nixpkgs packages them
as `gnu-config`; we copy them in before configuring.

> **Reusable lesson.** Release *tarballs* bundle `configure`, `config.guess`,
> `config.sub`, `install-sh`; git *archives* do not. If you fetch autotools
> software from a git tag, expect to run `autoreconf` and to provide the aux
> scripts (`gnu-config`, or `autoreconfHook`'s machinery).

### 4. Old autoconf mis-detects the host → force `--build`/`--host`

htslib 1.9's own configure then died: `Invalid configuration 'unknown-Linux'` —
its host-detection step handed `config.sub` a triplet `config.sub` would not
accept. Passing the triplet explicitly skips that auto-detection entirely:

```sh
./configure --disable-lzma \
  --build=${stdenv.buildPlatform.config} --host=${stdenv.hostPlatform.config}
```

> **Reusable lesson.** For `Invalid configuration '…'` or `machine … not
> recognized` from an old configure, pass `--build`/`--host` explicitly (Nix
> hands you the right triplets via `stdenv.*Platform.config`). Don't fight the
> detection: bypass it.

### 5. `ExternalProject` has *default* steps you didn't write

Even after neutralizing the clone and the upstream configure/build commands, the
build failed in an htslib `make install` we never asked for.
`ExternalProject_Add` runs a **download → update/patch → configure → build →
install** pipeline, and any stage you leave unspecified gets a *default*; for a
Make project the install stage defaults to `make install`. Because we build
htslib ourselves in `preConfigure`, we no-op every stage, including the install
(and, defensively, the optional test step):

```
DOWNLOAD_COMMAND "" CONFIGURE_COMMAND "true" BUILD_COMMAND "true"
INSTALL_COMMAND "true" TEST_COMMAND ""
```

> **Reusable lesson.** When you take over a dependency's build from
> `ExternalProject_Add` (or CMake's `FetchContent`, or a submodule build),
> neutralize *every* stage, not just the obvious one. Here it was the default
> `INSTALL` stage, the one you never wrote, that bit us after the download was
> already handled.

### 6. Build order isn't guaranteed → build the dependency first, explicitly

VerifyBamID links `samtools/htslib/libhts.a`, but the line that would order that
(`add_dependencies(VerifyBamID HTSLIB)`) is commented out upstream. Rather than
rely on luck under `make -j`, we compile htslib fully in `preConfigure` before
CMake ever links: `make` leaves the static `libhts.a` in the tree (the path
VerifyBamID links against), and `make install prefix=$PWD` populates the
`include/` tree the compile needs.

> **Reusable lesson.** If a project links a sub-dependency by hard path without a
> declared build-order dependency, build that sub-dependency deterministically in
> an earlier phase. Don't trust parallel `make` to get the order right.

### 7. CMake 4.x refuses old projects → `CMAKE_POLICY_VERSION_MINIMUM`

Same as elsewhere: `cmake_minimum_required(VERSION 2.8.4)` is fatal under CMake
≥4. Set `CMAKE_POLICY_VERSION_MINIMUM=3.5` for the whole build.

### 8. Bundled Eigen won't parse on gcc-15 → drop to gcc-13

VerifyBamID vendors an old copy of Eigen. gcc-15's stricter template-body parsing
rejects it outright (`… has no member named 'derived' [-Wtemplate-body]`). The
oldest compiler still in the nixpkgs base, **gcc-13**, parses it fine:

```nix
gcc13Stdenv = overrideCC stdenv gcc13;
```

> **Reusable lesson.** Modern gcc parses template bodies more eagerly and
> strictly than gcc-13 and earlier. Old header-only C++ (Eigen, Boost, various
> single-header libs) is where this bites. `overrideCC stdenv gcc13` is the
> lowest-risk fix: the same move strelka needed. (`gcc9`–`gcc12` are *gone* from
> the base; `gcc13`/`gcc14` are what remain.)

### 9. The tool is more than a binary → ship its data

VerifyBamID needs its **SVD reference panels** (104 MB of `.UD/.mu/.bed/.V` files
for the 1000 Genomes markers) to do anything. They're bundled in the source
tree, so we install `resource/` into `$out/resource` alongside the binary. Users
point `--SVDPrefix` (or `--UDPath/--BedPath/--MeanPath`) at them; once installed
via Flox they live at `$FLOX_ENV/resource/…`.

> **Reusable lesson.** For scientific tools, the reference data is part of the
> package, not an afterthought. Install it into `$out` and document the path, so
> the published package is genuinely turnkey.

---

## Verifying the result

The build produces `$out/bin/VerifyBamID` (runs and prints its full usage) plus
the 51 resource files. `ldd` on the binary shows every shared library resolving
into `/nix/store` with no dangling `/build` or `/tmp` references: it is fully
self-contained. (A full contamination estimate needs real WGS data overlapping
the panel markers, which is beyond a build-time smoke test.)

## Publishing

```bash
# commit .flox/ to a git remote first (publish needs a clean, pushed tree)
flox auth login
flox publish -o flox-labs verifybamid2
```

---

## If you're adapting your own old recipe

The order that worked here generalizes well:

1. **Make it hermetic first.** Turn every download into a pinned fetch; provide
   the host tools the build assumes (autotools aux files, interpreters).
2. **Get past configuration.** Force platform triplets, raise CMake policy
   minimums, neutralize every stage of any `ExternalProject`/`FetchContent` you
   take over.
3. **Then fight the compiler.** If old C++ won't parse, step back to `gcc13`
   before reaching for source patches; use `CXXFLAGS` force-includes
   (`-include limits …`) for the narrower "missing transitive header" errors.
4. **Finally, package the whole tool**: the binary *and* its data, and check the
   closure is self-contained (`ldd`) and free of build-tool leaks (`nix-store
   -qR`).
