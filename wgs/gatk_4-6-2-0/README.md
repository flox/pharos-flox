# GATK 4.6.2.0 runtime environment (with gatkcondaenv)

The Flox replacement for `wgs/gatk_4-6-2-0/Dockerfile`, which was
`FROM broadinstitute/gatk:4.6.2.0`. That base image ships two things: the GATK jar
and a conda Python environment ("gatkcondaenv") that some GATK tools shell out to.
This environment reproduces both, so it has full parity with the image it replaces
rather than being jar-only.

```bash
flox activate -d wgs/gatk_4-6-2-0
# first activation materializes gatkcondaenv (~2 GB download, once), then caches it
gatk HaplotypeCaller --help              # pure-Java tool, always available
gatk DetermineGermlineContigPloidy --help   # Python tool, works via gatkcondaenv
```

The jar comes from the Flox catalog at the pinned version. The Python env is built
once on first activation into `$FLOX_ENV_CACHE` and reused thereafter; every
activation after the first is instant.

---

## Why jar-only would not be enough

Most of GATK is pure Java and needs nothing but the jar. But a handful of tools
invoke a Python interpreter and `import gcnvkernel` (which pulls in
pymc / pytensor / pytorch):

- `DetermineGermlineContigPloidy`, `GermlineCNVCaller`,
  `PostprocessGermlineCNVCalls` (the germline CNV pipeline), and
- `NVScoreVariants` (neural-net variant filtering).

A catalog-only `flox install gatk` gives you the jar but none of that, so those
tools fail at runtime with `gcnvkernel could not be imported`. The Docker image
never had that problem because gatkcondaenv is baked in; this environment restores
that by materializing the same conda env. The germline CNV and NVScoreVariants
tools were the one parity gap between a jar-only Flox env and the upstream image,
and this closes it.

---

## How it works

The `[hook]` materializes gatkcondaenv once, into `$FLOX_ENV_CACHE` (the persistent,
machine-local, per-environment store that survives reactivation and is never
committed). The work is guarded by a `.ready` sentinel, so it runs on the first
activation only. Two small committed artifacts drive it:

- `gatkcondaenv.<system>.lock`: an explicit conda lock (the exact list of package
  URLs) that `micromamba create --file` installs without solving.
- `gatkPythonPackageArchive.zip`: gcnvkernel's source, pip-installed into the
  freshly created env.

After the env is built, `[hook]` prepends `gatkcondaenv/bin` to `PATH` on every
activation, and `[profile]` re-asserts the same for interactive shells (see
obstacle 4).

---

## The obstacles, in order

### 1. gcnvkernel is not on PyPI or conda, so we ship it

`gcnvkernel` is GATK's own package and is versioned in lockstep with the jar. It is
not published to any index; it lives inside the GATK release as
`gatkPythonPackageArchive.zip`. Rather than make every user download GATK's ~700 MB
release just to extract one 119 KB archive, that archive is committed here and
pip-installed into the env, exactly as the official `gatkcondaenv.yml` does with its
`pip:` subsection. pip builds it into `gatkpythonpackages-0.2` (which provides the
`gcnvkernel` module).

> Reusable lesson: when a tool bundles its own Python package rather than
> publishing it, vendor the small archive next to the recipe instead of pulling the
> whole upstream release at build time.

### 2. The conda solve is slow, so we ship an explicit lock

Solving gatkcondaenv from the `.yml` takes several minutes: conda's solver is
single-threaded, and this env's heavy pinning (pinned pymc, pytensor, pytorch,
numpy, and so on) makes for a large search space. That cost is the same on every
machine and buys nothing reproducible. So we solve it once and commit the result as
an `@EXPLICIT` lock, a flat list of exact package URLs. `micromamba create --file
<lock>` then skips solving entirely and just downloads and links the pinned set. The
build is both faster and bit-for-bit the same for everyone.

> Reusable lesson: a per-platform explicit lock turns a slow, RAM-hungry solve into
> a plain download, and pins the exact versions so two users never get different
> resolutions.

### 3. conda-forge's libtorch wants an executable stack

conda-forge's `libtorch_cpu.so` (pytorch 2.1.0, pulled in for `NVScoreVariants`) is
built with its `PT_GNU_STACK` program header marked Read+Write+Execute. At load time
the loader asks the kernel to make the thread stack executable. Stock Linux kernels
allow it; hardened kernels and many container or CI kernels refuse, and the import
dies with:

```
ImportError: libtorch_cpu.so: cannot enable executable stack as shared object
requires: Invalid argument
```

The marker is spurious (pytorch does not need an executable stack), so
`clear-execstack.py` clears the `PF_X` bit on that one header after the env is built.
It edits the ELF bytes directly (so it does not depend on a `patchelf` new enough to
have `--clear-execstack`), and it runs with the env's own python, reading and writing
only ELF headers so it never triggers the broken `import torch`.

> Reusable lesson: an `Invalid argument` at load of a `.so` is often a spurious
> executable-stack request. Clearing `PF_X` on `PT_GNU_STACK` makes the library load
> on every kernel and changes nothing about how it runs.

### 4. GATK finds `python` on PATH, so PATH must be set for every activation mode

GATK embeds no interpreter. Its `PythonScriptExecutor` invokes whatever `python` is
on `PATH` and imports `gcnvkernel` from it, exactly as the official image does after
`conda activate gatk`. So the materialized `gatkcondaenv/bin` has to be first on
`PATH` whenever the env is active.

The catch: `[profile]` is sourced only by interactive shells, and GATK is very often
run non-interactively as `flox activate -- gatk ...`, which does not source
`[profile]`. So the PATH export lives in `[hook] on-activate`, which runs for every
activation mode and covers both the interactive shell and `-- <cmd>`. A second,
redundant export stays in `[profile]` so the behavior is obvious to anyone reading
the manifest and working in the shell by hand; confirm it there with `which python`.

> Reusable lesson: environment state that a non-interactive `flox activate -- cmd`
> must see belongs in `[hook]`, not `[profile]`. `[profile]` alone silently misses
> the `-- cmd` path.

---

## Portability: where the lock and archive come from

The hook needs three files at activation: the per-platform conda lock,
`gatkPythonPackageArchive.zip`, and `clear-execstack.py`. It resolves them in this
order:

1. `$FLOX_ENV/share/gatkcondaenv`, installed by the **`flox-labs/gatkcondaenv`**
   catalog package (built from `build/gatkcondaenv/`). This is what makes the
   environment portable.
2. `$FLOX_ENV_PROJECT`, this repo's own copies, for in-tree development.

The fallback is not the general case, and relying on it alone was a bug. For a
checkout, `$FLOX_ENV_PROJECT` is the repo and the files are found. For an
environment pulled from FloxHub with `flox activate -r flox-labs/gatk`, it is
**the current working directory** -- whatever directory you happened to run the
command from, which has nothing to do with this repo:

```
$ cd /tmp && flox activate -r flox-labs/gatk-4-6-2-0 -- sh -c 'echo $FLOX_ENV_PROJECT'
/private/tmp
```

So the three files were simply absent, and the Python tools were silently
unavailable anywhere outside a checkout, with a message that blamed a missing lock
rather than a missing repo. Worse than merely absent: because the path is an
arbitrary cwd, running from the wrong directory could in principle *find* a
same-named lock. See `build/gatkcondaenv/README.md`.

Note this makes the environment independent of *GitHub*, not of the network: first
activation still downloads ~1.8 GB of conda packages from anaconda.org.

---

## Per-platform locks

Conda packages are architecture-specific, so the lock is per platform, named
`gatkcondaenv.<system>.lock`. All three target systems are committed and validated:
`x86_64-linux`, `aarch64-linux` and `aarch64-darwin`. The hook maps the running system to the matching lock; if no lock
exists for the current platform it says so and skips the Python env, leaving the Java
tools fully working. To add a platform, generate its lock on that hardware:

```bash
# on the target machine, from a solved gatkcondaenv:
micromamba env export --explicit -p <path-to-gatkcondaenv> > gatkcondaenv.<system>.lock
```

Target systems for this repo are `x86_64-linux`, `aarch64-linux`, and
`aarch64-darwin`, and each has a lock.

### aarch64-darwin is a port of the spec, not a re-export

GATK's official `gatkcondaenv.yml` cannot be solved unchanged on Apple Silicon: it
pins Intel-only MKL. The adapted spec is committed as `gatkcondaenv.macos.yml`, and
`gatkcondaenv.aarch64-darwin.lock` is what it solves to. Four changes, all forced by
what conda-forge/bioconda actually publish for `osx-arm64`:

| Upstream pin | On `osx-arm64` | Why |
|---|---|---|
| `conda-forge::blas=1.0=mkl` | dropped | MKL is x86-only; pytorch links Accelerate/OpenBLAS here instead |
| `conda-forge::pytorch=2.1.0=*mkl*100` | `pytorch=2.1.0` | the MKL build string is x86-only; version pin is unchanged |
| `bioconda::pysam=0.22.0` | `pysam=0.22.1` | 0.22.0 has no `osx-arm64` build; 0.22.1 is the oldest that does |
| `conda-forge::pyvcf=0.6.8` | `bioconda::pyvcf3=1.0.4` | PyVCF is dead upstream and never built for `osx-arm64`; pyvcf3 is its maintained fork and keeps the same top-level `vcf` module |

The last two are not cosmetic: `pysam` is imported by `scorevariants/readers.py` and
`encoders.py`, and `vcf` by `gcnvkernel/postprocess/viterbi_segmentation.py`, so
neither could simply be dropped. Every other package holds the exact version the
`x86_64-linux` lock resolved to.

### aarch64-linux is a smaller port of the same spec

`linux-aarch64` has the same MKL problem as Apple Silicon and none of the rest of
it. The adapted spec is committed as `gatkcondaenv.aarch64-linux.yml`. Every pin
was checked against what conda-forge and bioconda publish for `linux-aarch64`
before solving, and only three lines needed to change:

| Upstream pin | On `linux-aarch64` | Why |
|---|---|---|
| `conda-forge::blas=1.0=mkl` | dropped | MKL is Intel-only; conda-forge has **0** `linux-aarch64` builds of it |
| `conda-forge::pytorch=2.1.0=*mkl*100` | `pytorch=2.1.0` | the only 2.1.0 published here is `cpu_generic_py310*`, which links OpenBLAS |
| `conda-forge::scipy=1.11.4` | `scipy=1.11.3` | 1.11.4 was never built for `linux-aarch64`; 1.11.3 is the newest 1.11.x that was |

Note what did *not* change. The two bioconda substitutions the macOS port needs,
`pysam 0.22.1` and the `pyvcf3` fork, are **not** carried over: `linux-aarch64`
has builds of `pysam 0.22.0` and `pyvcf 0.6.8` at the exact versions the
`x86_64-linux` lock resolved to, so this platform keeps them. A port to one
non-x86 platform is not a template for the next; each pin has to be re-checked
against that platform's own channel contents.

Unlike macOS, this env is self-contained: the lock pulls conda-forge's
`gcc`/`gxx` 12.4.0 and `sysroot_linux-aarch64`, so PyTensor's runtime C
compilation works with no system toolchain, exactly as on `x86_64-linux`.

### macOS prerequisite: Xcode Command Line Tools

**On macOS the gCNV tools additionally require `xcode-select --install`.** PyTensor
compiles C++ at *run* time, and the conda env's own `clangxx_osx-arm64` defers to the
system SDK and linker, which ship only with the Command Line Tools. Without them
`import gcnvkernel` fails outright once PyTensor finds a compiler it cannot use:

```
fatal error: 'stdio.h' file not found            # no SDK
clang-16: error: linker command failed ...       # no system linker
```

The hook warns about this on every activation once `gatkcondaenv` is built, because
the failure is otherwise invisible: on a Mac without the CLT every materialization
step succeeds and `.ready` is written, so the env looks healthy right up until a gCNV
run dies.

This is not something the lock can fix; Apple does not permit redistributing the SDK,
so unlike `x86_64-linux` (whose lock ships `gcc`/`gxx` *and* `sysroot_linux-64`, making
it self-contained) the macOS env cannot be. There is a working fallback if you cannot
install the CLT, at a large performance cost, since every PyTensor op then runs its
Python implementation instead of compiled C:

```bash
PYTENSOR_FLAGS=cxx= gatk GermlineCNVCaller ...   # verified to import and run
```

---

## Verifying the result

A clean run (wipe `$FLOX_ENV_CACHE/gatkcondaenv`, then activate) rebuilds from the
committed lock and archive and was checked end to end on `x86_64-linux`:

| Check | Result |
|---|---|
| conda env materializes from the lock | 349 packages installed |
| gcnvkernel installs from the archive | `gatkpythonpackages-0.2` wheel built and installed |
| exec-stack fix | cleared on 1 library (`libtorch_cpu.so`) |
| `which python` (interactive and `-- cmd`) | resolves to `.flox/cache/gatkcondaenv/bin/python` |
| Python stack imports | `gcnvkernel`, pymc 5.10.1, pytensor 2.18.3, torch 2.1.0.post100, numpy, scipy, h5py, sklearn |
| Java tool | `gatk` runs the 4.6.2.0 jar |

The same clean-run check on `aarch64-darwin`:

| Check | Result |
|---|---|
| conda env materializes from the lock | 310 packages installed |
| gcnvkernel installs from the archive | `gatkpythonpackages-0.2` wheel built and installed |
| exec-stack fix | no-op, 0 libraries (Mach-O, not ELF; the script skips non-ELF files) |
| Python stack imports | `gcnvkernel`, `scorevariants`, pymc 5.10.1, pytensor 2.18.3, torch 2.1.0, pysam 0.22.1, `vcf` (pyvcf3) |
| assets resolve from the package | verified the hard way, by `flox activate -r flox-labs/gatk-4-6-2-0` with no checkout present at all: `$FLOX_ENV/share/gatkcondaenv` supplied the lock, the archive and the exec-stack script, and the env materialized end to end |
| PyTensor C backend | needs Xcode CLT **and** the env's triple-prefixed compiler; the hook now selects the latter automatically, see below |
| **gCNV end to end** | `DetermineGermlineContigPloidy` on GATK's 20-sample `gcnv-sim-data`, 1.92 min. All 100 discrete calls identical to both `x86_64-linux` and `aarch64-linux`, including the seven disputed female X=3 rows. X `PLOIDY_GQ` agrees to every digit printed: SAMPLE_000 `46.36143757554091` vs `46.361438`, SAMPLE_013 `106.4155162160399` vs `106.415516` |

### macOS: the CLT is necessary but not sufficient

Installing the Command Line Tools fixes the missing SDK, but the C backend still
fails to **link**, for an unrelated reason. conda's clang 16 passes its LTO plugin
by versioned filename, and Apple's current linker refuses it:

```
ld: -lto_library library filename must be 'libLTO.dylib'
```

The env passes `.../lib/libLTO.16.dylib`; `/usr/bin/ld` (ld-1267) requires that
basename to be exactly `libLTO.dylib`. Symlinking does not help, because clang
passes the versioned path explicitly rather than searching.

The env ships its own linker but installs no plain `ld`, only
`arm64-apple-darwin20.0.0-ld`, so bare `clang++` finds Apple's. Driving the build
through the matching triple-prefixed compiler picks up conda's linker and links
cleanly:

```bash
PYTENSOR_FLAGS="cxx=$(dirname $(command -v python))/arm64-apple-darwin20.0.0-clang++"
```

This is the trap the rest of this section warns about, in its worst form: with a
compiler configured but unusable, `import gcnvkernel` fails outright rather than
degrading, whereas with **no** compiler PyTensor silently drops to its Python
backend and imports appear to succeed. Both look like "it works" from a distance,
and only one of them is running compiled code.

The `[hook]` now sets this on Darwin, so no caller action is needed. It globs the
triple rather than hardcoding `arm64-apple-darwin20.0.0`, skips silently if the
compiler is absent, and leaves an existing `cxx=` alone -- including the documented
`PYTENSOR_FLAGS=cxx=` escape hatch that forces the Python backend.

Verified by re-running the gCNV job through a plain `flox activate` with nothing
exported: the hook supplied

```
PYTENSOR_FLAGS=cxx=.../gatkcondaenv/bin/arm64-apple-darwin20.0.0-clang++
```

and the run completed in 2.31 minutes with `ploidy-calls/` **byte-identical** to
the hand-flagged run.

And on `aarch64-linux`:

| Check | Result |
|---|---|
| conda env materializes from the lock | 267 packages installed, matching the 267 URLs in the lock |
| gcnvkernel installs from the archive | `gatkpythonpackages-0.2` wheel built and installed |
| exec-stack fix | no-op, 0 libraries, and correctly so; see `build/gatkcondaenv/README.md` |
| `which python` (via `flox activate -- cmd`) | resolves to `.flox/cache/gatkcondaenv/bin/python` |
| Python stack imports | `gcnvkernel` 0.9, `scorevariants`, pymc 5.10.1, pytensor 2.18.3, torch 2.1.0.post3, pysam 0.22.0, `vcf` 0.6.8, numpy 1.26.2, scipy 1.11.3, h5py 3.10.0, sklearn 1.3.2 |
| PyTensor C backend | compiles; `config.cxx` is the env's own `g++` and the function VM is `pytensor.link.c.cvm.CVM` |
| assets resolve from the package | hook read `$FLOX_ENV/share/gatkcondaenv`, proven by materializing when no in-tree lock existed |
| **gCNV end to end** | `DetermineGermlineContigPloidy` runs to completion on GATK's own 20-sample `gcnv-sim-data`; output matches a native `x86_64-linux` run call-for-call and GQ-for-GQ. Female X is over-called by one copy on both, for a model reason that is not platform-specific (see below) |

The exec-stack fix and the `which python` check are the two that would silently pass
a naive smoke test and then fail a real gCNV run, so both are verified explicitly.

### About that gCNV run

It is the first real gCNV run recorded for this repo on any platform. It
establishes that the machinery works, and it turned up one unresolved question.

The inputs are GATK's own simulated cohort from tag 4.6.2.0
(`src/test/resources/.../copynumber/gcnv-sim-data/`): 20 samples over contigs
1, 2, 3, X and Y. `DetermineGermlineContigPloidy` completes and writes a model
plus per-sample calls for all 20, which exercises the whole chain, the Java tool
handing off through `PythonScriptExecutor` to gcnvkernel, pymc and pytensor with
compiled C, and back.

**One caveat on the calls, which turns out not to be a platform problem.**

Sex chromosomes are called correctly for every male sample (X=1, Y=1), every Y
call is correct, and so are all 60 autosomal calls. Female samples (Y coverage 0)
get X=3 where the data says 2. That is checkable straight from the counts, with no
reference output needed: in those samples mean X coverage equals mean autosome
coverage (ratios of 0.94 to 1.05), which is ploidy 2, while male samples sit near
0.5 and are called 1.

Three runs locate the cause, and none of them involves the platform:

| Run | Result |
|---|---|
| full cohort, stock parameters | 7 of 7 female X called 3 |
| full cohort, `--mapping-error-rate 0.01` | female X all correct; 4 **male** X called 2 instead of 1 |
| the 8 female samples alone, stock parameters | female X all correct (8/8) |

Every failure is the same shape, X over-called by exactly one copy, in whichever
population the fit currently disfavours. Lowering one likelihood constant moves
the error from females to males; removing the males removes it entirely. Nothing
about the binaries, the BLAS or the CPU changes between those runs, so this is a
property of the model and this dataset, not of aarch64.

**Confirmed on `x86_64-linux`.** The stock-parameter run was repeated on a native
Intel host and reproduced the aarch64 result exactly: all 100 discrete calls
identical, including all seven disputed female X=3 rows, and every X `PLOIDY_GQ`
agreeing to all six decimal places compared, nine significant figures. So the
over-call is not platform-specific, and the aarch64 stack is not computing
different numbers.

The mechanism is visible in `gcnvkernel/models/model_ploidy.py`. `mean_bias_j` is
a single per-contig parameter shared across the whole cohort, and it enters the
likelihood multiplied by the ploidy being inferred:

```python
mu_num_sjk  = t_j * mean_bias_j * ploidy_k
mu_ratio_sjk = mu_num_sjk / (gamma_rest_sj + mu_num_sjk)      # share of the sample's reads
mu_sjk = ((1 - eps_mapping) * mu_ratio_sjk + eps_mapping_j) * n_s
```

`k` and `mean_bias_j` are confounded: predicted share depends on their product, so
if the fitted X bias is low by a factor f, every sample needs k/f copies. At
f around 0.67 a female's 2 becomes 3 while a male's 1 lands at 1.5 and rounds
down, which is exactly the split observed. A cohort containing two different X
ploidy populations has to fit one shared bias to both.

`mapping_error_rate` shifts where that compromise lands. It defaults to 0.3 and
enters as `eps_mapping_j = 0.3 * t_j / sum(t_j)`, a floor that is independent of
copy number: for Y, which is 2.09 Mb of a 10.3 Mb simulated genome, that puts
about 6 percent of every sample's reads on a contig where female samples have
exactly zero. The fit absorbs the strain into that contig's unexplained variance,
`psi_Y` comes back at log -1.77 against roughly -5.5 for every other contig, and
the residual pushes the shared X bias off. Note X (2.14 Mb) and Y (2.09 Mb) are
nearly the same length in this simulation, so the misapplied floor is almost
exactly the size of X's true share; this dataset is unusually sensitive to it.

Worth knowing that GATK's own `DetermineGermlineContigPloidyIntegrationTest`
`testCohort()` runs the tool and asserts nothing about the calls, and the
`contig-ploidy-calls/` files committed beside the test data are consumed as
*input* by the downstream `GermlineCNVCaller` tests. They agree with the coverage
ratios, which is why they are cited here, but they are a fixture rather than an
oracle.

**The machine this was verified on is an emulated aarch64 VM (QEMU), roughly 40
to 70 times slower than native ARM.** Two consequences. First, no timing here says
anything about aarch64 performance, which is why none is quoted except to size the
runs above. Second, QEMU advertises a maximal CPU feature set, so libraries that
dispatch on CPU features at runtime (OpenBLAS kernel selection, torch) may take
different code paths on a real Graviton or Apple Silicon host.

That concern is now largely retired by the `x86_64-linux` cross-check above, and
the comparison is a stronger one than it may look. The two locks do not merely
select different kernels of one library, they link **different BLAS
implementations**: `x86_64-linux` pins MKL 2022.2.1 (`libblas-3.9.0-16_linux64_mkl`),
while `linux-aarch64` has no MKL at all and links OpenBLAS 0.3.25
(`libblas-3.9.0-20_linuxaarch64_openblas`). Identical output to nine significant
figures across MKL and OpenBLAS, on different architectures, is a real numerical
agreement rather than an artifact of the two runs sharing a code path.

Two limits on that claim. It compares the digits that were compared, six decimals
of `PLOIDY_GQ`, not the raw bits of every model parameter; and it exercises one
tool on one small dataset, not the whole env.

**Now also confirmed on native Apple Silicon.** The `aarch64-darwin` run in the
table above closes the "no native ARM hardware" gap: real M-series silicon, not
QEMU, so CPU-feature dispatch is genuine rather than QEMU's maximal advertised set.
It reproduced all 100 discrete calls and matched every X `PLOIDY_GQ` digit printed.

That makes three independent BLAS/toolchain combinations in agreement:

| System | BLAS | Toolchain |
|---|---|---|
| `x86_64-linux` | MKL 2022.2.1 | gcc 12 / libstdc++ |
| `aarch64-linux` | OpenBLAS 0.3.25 **pthreads** | gcc 12 / libstdc++ |
| `aarch64-darwin` | OpenBLAS 0.3.25 **openmp** | clang 16 / libc++ |

Different BLAS implementations, different threading models, different C++ standard
libraries, two architectures and two operating systems, producing identical calls
and identical printed GQs. The female X over-call is therefore firmly a property of
the model and this dataset, with no remaining platform explanation.

---

## What is committed here, and what is not

Committed: the manifest, all three locks (`x86_64-linux`, `aarch64-linux`,
`aarch64-darwin`), the `gatkcondaenv.macos.yml` and
`gatkcondaenv.aarch64-linux.yml` specs the two ported locks were solved from, the
119 KB gcnvkernel archive, `clear-execstack.py`, and this README. These are the
in-tree fallback copies; the canonical set is the one shipped by the
`flox-labs/gatkcondaenv` package (see above), and the two are kept identical. Not committed: the materialized conda env,
which lives under `$FLOX_ENV_CACHE` (built once per machine, reused after, and
removed by `flox delete`). On disk that cache is about 5 GB: the env proper is
~3.8 GB and micromamba's package cache (scoped here via `CONDA_PKGS_DIRS`) holds
the extracted packages, which are hardlinked into the env rather than a second
copy. That split is the point: ship the small recipe, build the large artifact
locally on first use.
