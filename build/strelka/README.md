# Building strelka 2.9.10 with Flox

A build-only Flox environment that compiles [Strelka2](https://github.com/Illumina/strelka)
2.9.10 from source and publishes it to the `flox-labs` catalog. The recipe is a
Nix-expression build at [`.flox/pkgs/strelka/default.nix`](.flox/pkgs/strelka/default.nix).

```bash
flox build strelka          # -> ./result-strelka
./result-strelka/bin/configureStrelkaGermlineWorkflow.py --version   # 2.9.10
```

---

## Why this can't just be `flox install`

Strelka *is* in the Flox catalog, but it won't install: it depends on **Python
2.7**, and modern nixpkgs first marked CPython 2.7 as insecure (refusing to
evaluate) and then removed it from the package set entirely. Strelka 2.9.10
(2018) is its final release and is permanently Python-2-bound — there is no
version we can bump to.

This is the general shape of the problem you hit with a lot of scientific
software: **the tool is fine, but the world it was built in has moved on.** The
compiler is newer, the build system is newer, the interpreter is gone, the
CMake policies it assumed have been deleted. Nix is what makes it tractable,
because it lets us reassemble the *old* world (a specific compiler, a specific
Python) deterministically alongside the new one, without a container and without
touching the host. The rest of this document is a tour of every site where the
old world and the new one collided, and how we bridged each.

A key consequence of publishing: **the insecure/removed-Python problem only
exists at *build* time on our machine.** Once published, consumers install a
pre-built binary closure: they never re-evaluate Python 2, so the block never
fires for them. If you take one idea from this repo, take that one: *build the
awkward thing once, in a controlled place, and ship the result.*

---

## The obstacles, in order, and what each teaches

### 1. There is no Python 2 in nixpkgs anymore → use PyPy 2.7

CPython 2.7 is gone. But **PyPy still ships a 2.7-compatible interpreter**
(`pypy27`, PyPy 7.3.x), it is actively maintained, and it is in the Flox catalog
with no insecure marker. It reports `Python 2.7.18` and runs pure-Python 2 code
faithfully.

> **Reusable lesson.** For a Python-2-bound tool, reach for `pypy27` before you
> consider vendoring EOL CPython. It's maintained (so it's the *more* secure
> choice), it's a normal catalog package, and its main compatibility gap is code
> that depends on CPython implementation details (see #7).

Strelka's own logic is a mix of compiled C++ callers and a Python 2 workflow
layer (pyFlow). PyPy only has to drive the workflow scripts; the heavy lifting
is native.

### 2. Strelka needs an older compiler → rebuild the stdenv with `overrideCC`

Strelka bundles **boost 1.58** (2015) alongside its own 2018-era C++. Old,
header-heavy C++ like this is a frequent casualty of newer GCC's stricter
parsing, so we build with an older compiler rather than the default gcc-15 — a
deliberate, conservative choice for code this age. (The risk is not hypothetical:
this repo's sibling verifybamid2 has a bundled Eigen that fails outright on
gcc-15; and Section 3 below shows strelka's own sources needed adjustment even on
gcc-13.) The natural fix is "use an older gcc," and older gccs *are* in the Flox
catalog — but here is a subtlety that cost us a few build cycles:

> **The nixpkgs base that `flox build` evaluates against is NOT the Flox
> catalog.** `flox install gcc9` works (the catalog keeps historical versions),
> but inside a `.flox/pkgs/*.nix` expression, `gcc9`, `gcc10`, `gcc11`, `gcc12`
> and every `gccNStdenv` adapter are *removed*. Only `gcc13` and `gcc14` survive
> in the base. They are different package sources; do not assume a name in one
> exists in the other.

So we take the oldest compiler the base still has, `gcc13`, and swap it into the
default stdenv by hand (the `gccNStdenv` convenience wrappers were also removed):

```nix
let gcc13Stdenv = overrideCC stdenv gcc13; in gcc13Stdenv.mkDerivation { ... }
```

> **Reusable lesson.** To build old C++ with an older compiler in a Nix
> expression: `overrideCC stdenv gccN`. Probe which `gccN` actually exist first
> (and force the value — a lazy unused arg won't trip the "removed" error), then
> pick the oldest available.

### 3. gcc-13 is stricter too → force-include the headers old code assumed

gcc-13 builds the bundled boost cleanly, but it then rejected strelka's *own*
2018 C++ with `'numeric_limits' is not a member of 'std'`. Older gccs pulled `<limits>`,
`<cstdint>` and `<memory>` in transitively through other headers; gcc-13's cleaner
headers don't, so code that used `std::numeric_limits` without including `<limits>`
no longer compiles. Rather than patch every offending file we force-include the
common headers — but only for C++, so the flag never reaches the bundled *C*
sources of htslib/samtools (where a C++ header is a hard error):

```nix
CXXFLAGS = "-include limits -include cstdint -include memory";
```

> **Reusable lesson.** "`std::X` is not a member of `std`" on a newer compiler is
> almost always a *missing transitive include*, not a real defect — older toolchains
> were lax about pulling headers in. For a handful of files, add the `#include`; for
> many, `CXXFLAGS="-include <header> …"` fixes them all at once. Keep it in
> `CXXFLAGS`, not `NIX_CFLAGS_COMPILE`, so a C++ header never leaks into a C compile.

### 4. CMake 4.x refuses old projects → `CMAKE_POLICY_VERSION_MINIMUM`

Strelka's `cmake_minimum_required(VERSION 2.8.12)` is fatal under CMake 4.x
("Compatibility with CMake < 3.5 has been removed"). The escape hatch is an
environment variable that also propagates into the *nested* CMake runs strelka
kicks off for bundled boost/htslib:

```nix
CMAKE_POLICY_VERSION_MINIMUM = "3.5";
```

> **Reusable lesson.** Any pre-3.5 CMake project fails on CMake ≥4. Set
> `CMAKE_POLICY_VERSION_MINIMUM=3.5` in the build environment rather than
> patching each `CMakeLists.txt`.

### 5. CMake grabs the wrong Python → expose PyPy under the names it looks for

Strelka's `find_package(PythonInterp)` searches for `python2.7`, `python2`,
`python`. Left to itself it picks up whatever Python is on `PATH`; when we first
hit this it resolved to a python3, which then choked byte-compiling strelka's
Python 2 sources (`0755` octal literals are a syntax error in Python 3). PyPy
only installs a `pypy` binary, so we point those names at PyPy, on `PATH`, before
configuring, so the probe resolves to the right interpreter:

```sh
ln -s ${pypy27.interpreter} $TMPDIR/pybin/python2.7   # + python2, python
export PATH=$TMPDIR/pybin:$PATH
```

> **Reusable lesson.** Old `FindPythonInterp`/autoconf probes look for
> *versioned* interpreter names. If your interpreter has a non-standard binary
> name, alias it to what the probe searches for rather than patching the probe.

### 6. The pure sandbox has no `/usr/bin/env` → `patchShebangs`

Every `#!/usr/bin/env bash|python2` script fails to launch in the hermetic
build. `patchShebangs .` (run after PyPy is on `PATH`, so the `python2` shebangs
resolve too) rewrites them to concrete store paths.

> **Reusable lesson.** In a pure build, `#!/usr/bin/env X` is broken by design.
> `patchShebangs` is the standard fix; run it *after* the interpreters it needs
> to resolve are on `PATH`.

### 7. PyPy's garbage collector breaks a CPython idiom in pyFlow

This is the subtle one, and the most transferable. pyFlow (strelka's workflow
engine) writes a task's parameters like this:

```python
pickle.dump(taskInfo, open(argFile, "w"))
```

The file handle is never closed. On **CPython** that's harmless: reference
counting frees the handle at the end of the statement, which flushes and closes
it. On **PyPy** the GC is *not* refcounting, so the handle isn't closed promptly
— the child task reads an empty pickle and dies with `EOFError`. We patch it to
close explicitly.

> **Reusable lesson.** The #1 way pure-Python code breaks under PyPy is relying
> on CPython's prompt, refcounting-driven finalization — unclosed files/sockets,
> `__del__` timing. When a PyPy port fails mysteriously mid-run, grep for
> `open(...)` without a `with`/`.close()` and for `__del__`.

### 8. Interpreters get *baked into generated files*, not just shebangs

We pinned every `#!/usr/bin/env python2` across `bin/`, `libexec/` and `lib/` to
PyPy's store path — and it *still* failed at runtime with `env: python2: not
found`. The culprit was `lib/python/makeRunScript.py`, which holds the
interpreter as a **template string** (`pythonBin="/usr/bin/env python2"`) that
it writes into the `runWorkflow.py` the user generates later. It has no `#!`, so
our shebang sweep never matched it. We pin that assignment too.

> **Reusable lesson.** Self-configuring tools often emit *new* scripts at
> runtime with a hard-coded interpreter. Grep the whole tree for the interpreter
> string, not just for `#!` lines, and pin the templates as well as the scripts.

### Two more mechanical notes

- **Store timestamps are epoch 0**, so a stale `.pyc` would shadow a patched
  `.py` (PyPy compares mtimes). We delete all `.pyc` after patching.
- Sources are **hash-pinned** (`fetchurl` with `sha256`), and the strelka source
  bundles boost/htslib/samtools/pyFlow, so there is **no build-time network** —
  the build is fully reproducible.

---

## Verifying the result

Strelka's own `make` target compiles and runs its bundled unit tests. Beyond
that, the built artifact was validated end-to-end on the bundled demo:
configuring and running the germline workflow under PyPy produced 18 variant
calls — identical to a standalone from-source prototype run — with the generated
`runWorkflow.py` correctly shebanged to the PyPy store path.

## Publishing

```bash
# commit .flox/ to a git remote first (publish needs a clean, pushed tree)
flox auth login
flox publish -o flox-labs strelka
```

Consumers then `flox install flox-labs/strelka` and get the pre-built closure —
no compiler and no Python-2 evaluation on their side, and the PyPy porting issues
above already solved (the tool runs on the PyPy bundled into the closure).
