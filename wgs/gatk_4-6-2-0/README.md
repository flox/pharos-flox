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

## Per-platform locks

Conda packages are architecture-specific, so the lock is per platform, named
`gatkcondaenv.<system>.lock`. `x86_64-linux` is committed and validated here. The
hook maps the running system to the matching lock; if no lock exists for the current
platform it says so and skips the Python env, leaving the Java tools fully working.
To add a platform, generate its lock on that hardware:

```bash
# on the target machine, from a solved gatkcondaenv:
micromamba env export --explicit -p <path-to-gatkcondaenv> > gatkcondaenv.<system>.lock
```

Target systems for this repo are `x86_64-linux`, `aarch64-linux`, and
`aarch64-darwin`.

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

The exec-stack fix and the `which python` check are the two that would silently pass
a naive smoke test and then fail a real gCNV run, so both are verified explicitly.

---

## What is committed here, and what is not

Committed: the manifest, the `x86_64-linux` lock, the 119 KB gcnvkernel archive,
`clear-execstack.py`, and this README. Not committed: the materialized conda env,
which lives under `$FLOX_ENV_CACHE` (built once per machine, reused after, and
removed by `flox delete`). On disk that cache is about 5 GB: the env proper is
~3.8 GB and micromamba's package cache (scoped here via `CONDA_PKGS_DIRS`) holds
the extracted packages, which are hardlinked into the env rather than a second
copy. That split is the point: ship the small recipe, build the large artifact
locally on first use.
