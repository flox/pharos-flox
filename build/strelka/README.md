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
(2018) is its final release and is permanently Python-2-bound; there is no
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
fires for them. If you take one idea from all this, take that one: *build the
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
> that depends on CPython implementation details (see #7 and #13).

Strelka's own logic is a mix of compiled C++ callers and a Python 2 workflow
layer (pyFlow). PyPy only has to drive the workflow scripts; the heavy lifting
is native.

### 2. Strelka needs an older compiler → rebuild the stdenv with `overrideCC`

Strelka bundles **boost 1.58** (2015) alongside its own 2018-era C++. Old,
header-heavy C++ like this is a frequent casualty of newer GCC's stricter
parsing, so we build with an older compiler rather than the default gcc-15 — a
deliberate, conservative choice for code this age. (The risk is not hypothetical:
the sibling verifybamid2 build has a bundled Eigen that fails outright on
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
default stdenv by hand (the `gccNStdenv` convenience wrappers were also removed).
On Darwin we deliberately do *not* do this, for reasons that only showed up when
we built there; see #9:

```nix
let
  buildStdenv =
    if stdenv.hostPlatform.isDarwin then stdenv else overrideCC stdenv gcc13;
in
buildStdenv.mkDerivation { ... }
```

> **Reusable lesson.** To build old C++ with an older compiler in a Nix
> expression: `overrideCC stdenv gccN`. Probe which `gccN` actually exist first
> (and force the value: a lazy unused arg won't trip the "removed" error), then
> pick the oldest available.

### 3. gcc-13 is stricter too → force-include the headers old code assumed

gcc-13 builds the bundled boost cleanly, but it then rejected strelka's *own*
2018 C++ with `'numeric_limits' is not a member of 'std'`. Older gccs pulled `<limits>`,
`<cstdint>` and `<memory>` in transitively through other headers; gcc-13's cleaner
headers don't, so code that used `std::numeric_limits` without including `<limits>`
no longer compiles. Rather than patch every offending file we force-include the
common headers, but only for C++, so the flag never reaches the bundled *C*
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
> on CPython's prompt, refcounting-driven finalization, unclosed files/sockets,
> `__del__` timing. When a PyPy port fails mysteriously mid-run, grep for
> `open(...)` without a `with`/`.close()` and for `__del__`.

### 8. Interpreters get *baked into generated files*, not just shebangs

We pinned every `#!/usr/bin/env python2` across `bin/`, `libexec/` and `lib/` to
PyPy's store path, and it *still* failed at runtime with `env: python2: not
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

## The same recipe on three systems

Everything above was found on `x86_64-linux`. The manifest targets three systems
(`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`), and `flox build` always
builds natively for the machine it runs on, so the other two had to be built on
their own hardware. Both surfaced failures the first platform could not have
shown, and with one exception every failure was in code strelka *vendors*: boost
1.58 (2015), pyFlow, rapidjson. Expect that pattern. A 2018 release pins its
dependencies to 2018, so porting it forward is mostly porting *them*.

### 9. gcc-13 miscompiles boost's build engine on Darwin → use the platform's clang

The Darwin build failed at configure with `Failed to build boost library 1.58.0`
and an **empty** `boost.build.error.txt`. Empty, because nothing had run: boost
bootstraps its own 2014-era jam engine (`bjam`) with `cc`, and gcc-13 on
aarch64-darwin miscompiles it, so the binary segfaulted while loading
`boostcpp.jam`, before it could write a line of its log. Built by the platform's
own clang, the identical engine and boost source build cleanly. So the compiler
choice from #2 is inverted here: Linux keeps gcc-13, Darwin gets the native
clang stdenv.

> **Reusable lesson.** "Old code needs an old compiler" is a heuristic, not a
> rule; on a platform whose toolchain *is* clang, an off-platform gcc can be the
> less-tested path. And when a build tool dies with an empty log, read the
> emptiness as evidence: suspect the tool, not the thing it was about to build.

### 10. clang rejects what gcc tolerated → five separate vendored-code fixes

Moving Darwin to clang fixed the jam engine and immediately exposed four more
compile failures, none of which gcc had ever objected to:

| What broke | Why clang and not gcc | Fix |
|---|---|---|
| boost's jam engine calls `file_query()` undeclared | clang 16+ makes implicit function declarations a hard error | `NIX_CFLAGS_COMPILE = "-Wno-implicit-function-declaration"` |
| boost 1.58 uses `std::auto_ptr` | libc++ *removed* it in C++17; libstdc++ only deprecates it, and clang defaults to `gnu++17` | pin the boost bootstrap to C++11 via bjam `cxxflags` |
| `mpl::integral_c<E,0>::prior` casts `-1` into a 4-value unscoped enum | out of range, so not a constant expression for clang; gcc accepts it | give the three `boost::numeric` mixture enums a fixed underlying type |
| rapidjson's `GenericStringRef::operator=` assigns to its own `const` members | clang rejects it on instantiation; gcc never reaches it | `= delete` the operator (nothing assigns one) |

Plus one that is not about the language at all: the bundled `bgzf_extras`
Makefile hardcodes `CC = gcc`, and the clang stdenv has no `gcc` on `PATH`, only
`cc` and `clang`. Passing `CC=cc` on the `make` command line overrides the
Makefile's assignment.

> **Reusable lesson.** Budget for this. Changing the compiler is a one-line
> change that re-runs every vendored dependency through a different front end,
> and 2015-era C++ has accumulated a decade of things one compiler tolerates and
> another does not. Each of these was a separate, unrelated diagnosis.

### 11. libc++ turns a latent strelka bug into a `SIGTRAP` → guard the empty queue

With Darwin building, strelka2 then died with `SIGTRAP` the moment any stream
was exhausted. This one was not vendored code; it was a real bug in strelka
itself, sitting in `HtsMergeStreamer::next()`:

```cpp
const HtsRecordSortData last = getCurrent();
_streamQueue.pop();

if (getCurrentPos() < last.pos)   // getCurrentPos() reads _streamQueue.top()
```

Calling `top()` on a queue that the preceding `pop()` just emptied is undefined,
and it happens on the last record of *every* region. libstdc++ hands back the
slot it just popped, so the comparison trivially passes and Linux never notices.
libc++ gives clang enough information to prove the empty branch unreachable, so
it emits a trap. The guard is now explicit, unconditionally on all platforms.

> **Reusable lesson.** When a port crashes inside *your own* code rather than a
> dependency, suspect UB that the previous standard library happened to mask.
> The new platform did not break the code; it stopped hiding a bug that was
> always there, on every platform.

### 12. boost 1.58 mis-detects arm64 → teach its probe about `__aarch64__`

On `aarch64-linux`, configure failed with `Failed to build boost library 1.58.0`
again, this time with 85 identical entries in the log:

```
g++: error: unrecognized command-line option '-m64'
```

Boost.Build deduces the target architecture by *compiling probe files*
(`libs/config/checks/architecture/`). The 64-bit probe passes, so
`address-model=64`. The ARM probe accepts `__arm__`, `__thumb__`,
`__TARGET_ARCH_ARM`, `__TARGET_ARCH_THUMB`, `_ARM` and `_M_ARM`, but never
`__aarch64__`, which is the only one an aarch64 gcc defines. (`grep -r aarch64`
over the entire 1.58 build system returns nothing.) So every architecture probe
fails, `architecture` comes back empty, and `gcc.jam`'s guard, `if $(arch) !=
arm`, is true for an empty value: it appends `-m64`, an option the aarch64 gcc
backend does not have. We teach the probe about `__aarch64__` so the deduction
is simply correct. Darwin never saw this, because `clang-darwin.jam` declares
its own compile actions and never calls `gcc.setup-address-model`.

> **Reusable lesson.** A vendored build system encodes the architectures that
> existed when it shipped. When something from 2015 meets a newer target, look
> for a *detection* failure before a code failure, and prefer fixing the probe
> to overriding its answer: the deduction then stays correct for everything
> downstream that reads it.

### 13. PyPy's startup warning breaks pyFlow's task protocol → set `PYPY_GC_NURSERY`

The build was green and all 9 unit test suites passed. Both demos still failed
on `aarch64-linux`: every task failed, starting with a bare `mkdir -p`, while
the log reported that the task itself had *succeeded*:

```
[ERROR] Failed to complete command task: 'CallGenome+makeTmpDir' ...
[ERROR] [CallGenome+makeTmpDir] Anomalous task wrapper stderr output
[taskWrapper-stderr] Warning: cannot find your CPU L2 & L3 cache size in ...
[taskWrapper-stderr] ... [wrapperSignal] taskExitCode 0
```

PyPy sizes its GC nursery from the L2/L3 cache size published under
`/sys/devices/system/cpu/cpuX/cache`, and prints that warning at interpreter
startup when it cannot find one. arm64 kernels routinely publish the cache
*levels* with no `size` attribute, and container runtimes often mask the tree
entirely, so this fires on aarch64-linux and in containers on any architecture.

It is fatal because of how pyFlow signals completion: the task wrapper writes
its signal protocol **to stderr**, then pyFlow parses that same file back line
by line and fails the task if any line's 5th whitespace field is not
`[wrapperSignal]`. PyPy's warning is line 1 of every wrapper's stderr, so every
task is marked failed regardless of what it did. Setting `PYPY_GC_NURSERY` skips
the probe, and 4MB is exactly what PyPy falls back to when the probe fails, so
this pins the size it would have chosen anyway rather than retuning the GC. It
has to be set in the parent, before the spawn, because the warning is emitted
before any task-wrapper code runs; pyFlow's `Popen` passes no `env=`, so the
children inherit it.

> **Reusable lesson.** Diagnostic output is only harmless when nothing parses
> it. Any tool that multiplexes a machine-readable protocol onto stderr (pyFlow,
> and plenty of job runners) turns a one-line warning from *any* layer beneath
> it into a hard failure. Note also that this is the second PyPy-specific defect
> after #7, and again the fix is to make behavior explicit rather than to rely
> on an implementation default.

---

## Verifying the result

Strelka's own `make` target compiles and runs its 9 bundled unit test suites, so
every successful build has already passed them. Beyond that, the built artifact
was validated end to end on the bundled demos, on each system natively:

| System | Verified |
|---|---|
| `x86_64-linux` | unit tests; germline demo, 18 variant calls, identical to a standalone from-source prototype run, with the generated `runWorkflow.py` correctly shebanged to the PyPy store path |
| `aarch64-darwin` | unit tests; germline and somatic demos, no differences from the expected results |
| `aarch64-linux` | unit tests; germline and somatic demos, no differences from the expected results |

The demos are worth running rather than trusting a green build, and #13 is why:
the build and the unit tests passed on aarch64-linux while every workflow task
failed. Nothing short of running a workflow would have caught it.

## Publishing

```bash
# commit .flox/ to a git remote first (publish needs a clean, pushed tree)
flox auth login
flox publish -o flox-labs strelka
```

`flox build` and `flox publish` are native to the machine they run on, so a
full-platform `flox-labs/strelka` means running the publish once per target
system, from the same commit:

| System | Toolchain | What that system was the first to need |
|---|---|---|
| `x86_64-linux` | gcc-13 stdenv | #1 through #8 |
| `aarch64-linux` | gcc-13 stdenv | #12 (boost's arm64 probe), #13 (pyFlow under PyPy) |
| `aarch64-darwin` | native clang stdenv | #9, #10 (five strictness fixes), #11 |

Only the stdenv choice is conditional on the platform. Every other fix listed
above is applied unconditionally, so each system builds from the same recipe and
a fix found on one cannot silently rot on the others.

Consumers then `flox install flox-labs/strelka` and get the pre-built closure:
no compiler and no Python-2 evaluation on their side, and the PyPy porting issues
above already solved (the tool runs on the PyPy bundled into the closure).
