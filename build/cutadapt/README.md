# Building cutadapt 5.2 with Flox

A build-only Flox environment that builds [cutadapt](https://cutadapt.readthedocs.io)
5.2 and its dependency tree from PyPI, for publishing to the `flox-labs` catalog.
The recipe is a Nix-expression build at
[`.flox/pkgs/cutadapt/default.nix`](.flox/pkgs/cutadapt/default.nix).

```bash
flox build cutadapt         # -> ./result-cutadapt
./result-cutadapt/bin/cutadapt --version   # 5.2
```

---

## Why this can't just be `flox install`

cutadapt is a widely-used, actively-maintained tool, but it is **not in the
Flox catalog, and not in the nixpkgs base either.** In addition, its two direct
dependencies, `dnaio` and `xopen`, were also dropped from nixpkgs. (Only the
lower-level C-extension libraries `isal` and `zlib-ng` survive.)

This is a different failure mode from strelka. Nothing here is *old* or hard to
compile; cutadapt 5.2 is current. The problem is purely **upstream supply**:
the distro removed the packages. When that happens, the fix is to rebuild the
small tree yourself from the authoritative upstream (PyPI), pinned by hash. Nix's
`buildPythonPackage`/`buildPythonApplication` make this mechanical.

Unlike strelka, cutadapt's C extensions compile fine on the modern default
compiler (gcc-15); no `overrideCC` needed. The interesting decisions here are
all about **taming the dependency tree**.

---

## The obstacles, in order, and what each teaches

### 1. Confirm what's *actually* missing before you package it

We probed the nixpkgs base for `cutadapt`, `python3Packages.dnaio`,
`python3Packages.xopen`, `python3Packages.isal` and `cython`. Result: the first
three are absent; `isal` and `cython` are present.

> **Reusable lesson.** The Flox Base Catalog and the `flox build` base nixpkgs are
> *different* package sources: a name can be in one and not the other. Probe the
> base directly ('a tiny `runCommand` that forces `pkg.version`) before deciding
> what you must build vs. what you can reuse. And **force** the value: a lazy,
> unused function argument won't trigger a "missing"/"removed" error, so a naive
> probe can report a false "present."

### 2. Package the tree, reusing what nixpkgs still has

The tree is `cutadapt → dnaio → xopen → {isal}`. We build cutadapt, dnaio and
xopen from their PyPI sdists (hash-pinned) and let `isal` come from nixpkgs.

> **Reusable lesson.** You rarely have to rebuild *everything*. Rebuild the
> packages that were removed and splice in the lower-level libraries the distro
> still ships. Fewer from-source builds = fewer things that can break.

### 3. Pick dependency *versions* that prune the transitive tree

This is the crux. cutadapt 5.2 requires `xopen >= 1.6.0`. We initially took the
newest, **xopen 2.1.0**, which dragged in three hard dependencies: `isal`,
`zlib-ng`, and (on Python < 3.14) `backports.zstd`. Walking back through the
versions shows where each entered: 2.x added `backports.zstd`; **1.9.0** added
`zlib-ng`; but **1.6.0–1.8.0** need only `isal`. We pinned **xopen 1.7.0**, whose
sole hard dependency is `isal` (already in nixpkgs), which dropped both `zlib-ng`
and `backports.zstd` while still satisfying cutadapt's `>= 1.6.0` constraint. The
`backports.zstd` marker mattered specifically because of the Python version in
play (#4 below).

> **Reusable lesson.** When a dependency constraint is a *range*, the newest
> version often has the fattest dependency tree. Deliberately choosing an older
> in-range version can eliminate whole sub-trees of C-extension packages you'd
> otherwise have to build. Read `requires_dist` across a few versions and pick
> the one that minimizes work while satisfying the constraint.

### 4. Know which interpreter your build actually uses

A trap worth calling out: the base's top-level `python3` is 3.14, but its default
**`python3Packages` set is built for Python 3.13.** The build produces
`python3.13-*` derivations. That mattered because xopen 2.x's `backports.zstd`
dependency is conditional on `python_version < "3.14"`, true for 3.13. Choosing
xopen 1.7.0 sidestepped it, but only once we knew *which* Python was in play.

> **Reusable lesson.** Don't assume `python3` and `python3Packages` are the same
> minor version. Check the actual interpreter the package set targets — dependency
> markers (`; python_version < "…"`) hinge on it.

### 5. Read the build error for the missing *build backend*

The first build failed with `Missing dependencies: setuptools_scm[toml]>=6.2`.
Runtime deps go in `dependencies`; **build-time** backends go in `build-system`.
xopen and dnaio and cutadapt all build with `setuptools` + `setuptools_scm`
(+ `cython` for the two with C extensions), which we declare explicitly.

> **Reusable lesson.** In `pyproject = true` builds, `build-system` and
> `dependencies` are distinct lists. A "Missing dependencies: setuptools_scm /
> cython / hatchling…" error at the *wheel-building* stage means a `build-system`
> entry, not a runtime one. Check the sdist's `pyproject.toml [build-system]`.

---

## About the closure (and the "leaks" question)

`dnaio`, `xopen` and `isal` appear in the runtime closure **because cutadapt
imports them** ; that is correct, not a leak. What you *don't* want is
build-only tooling (Cython, setuptools, the gcc compiler, cmake) ending up in
the runtime closure. We verified it doesn't:

```
runtime closure: cutadapt-5.2, python3.13-dnaio, python3.13-xopen,
                 python3.13-isal, python3-3.13.13, gcc-*-lib   (libstdc++/libgcc only)
```

The only `gcc-*` entries are the `-lib` outputs, `libstdc++`/`libgcc_s`, which
the compiled `.so`s legitimately link against. `buildPythonApplication` keeps the
compiler, Cython, and setuptools out of the runtime closure automatically.

> **Reusable lesson.** "Is X in the closure?" has two answers: required runtime
> deps *should* be there; build tools should *not*. `nix-store -qR ./result` and
> eyeball it: seeing `libstdc++`/`libgcc` is fine, seeing `gcc-wrapper`, `cython`
> or `cmake` means a build input leaked into runtime.

---

## Verifying the result

`pythonImportsCheck = [ "cutadapt" ]` runs at build time. The built binary was
also smoke-tested self-contained (nothing else on `PATH`): trimming a `AACCGGTT`
5' adapter off a read yielded the correctly trimmed sequence.

## Publishing

```bash
# commit .flox/ to a git remote first (publish needs a clean, pushed tree)
flox auth login
flox publish -o flox-labs cutadapt
```
