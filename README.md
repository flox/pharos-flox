# pharos-flox: WGS tools as Flox environments

Flox environment equivalents of the `wgs/` container images. Each Dockerfile
packaged a **stock upstream tool** (no custom patches), so instead of rebuilding
the Docker recipe we install the same tool (a) from the Flox catalog where it
exists (b) or from a small, reproducible Flox build when it doesn't.

## Layout

```
pharos-flox/
  wgs/<tool>_<ver>/.flox/     runtime environments (what you activate/use)
  build/<tool>/.flox/         build-only environments for tools missing from the catalog
  build/gatkcondaenv/.flox/   build-only environment for a data package, not a tool
```

## The tools

| Tool | Version | How it's provided |
|------|---------|-------------------|
| samtools | 1.19.2 | catalog-native (exact) |
| seqtk | 1.4 | catalog-native (exact) |
| fastqc | 0.12.1 | catalog-native (exact) |
| gatk | 4.6.2.0 | catalog-native (exact) jar, **plus** `flox-labs/gatkcondaenv` for the gCNV/NN Python tools (see below) |
| bwa | 0.7.17 | **built** → `flox-labs/bwa` (catalog is x86_64-only; built for the 3 target systems) |
| strelka | 2.9.10 | **built** → `flox-labs/strelka` (see below) |
| cutadapt | 5.2 | **built** → `flox-labs/cutadapt` |
| verifybamid2 | 1.0.5 | **built** → `flox-labs/verifybamid2` |

The catalog-native environments work as-is:

```bash
flox activate -d pharos-flox/wgs/samtools_1-19-2 -- samtools --version
```

## Why four tools are built instead of installed

They aren't available (at the exact version, on every system) in the Flox catalog:

- **bwa 0.7.17**. In the catalog but **x86_64 only** — this 2017 release predates
  ARM support (hard-coded x86 SSE2 intrinsics). Built for the three target systems (x86_64-linux, aarch64-linux, aarch64-darwin), using
  the `sse2neon` shim on aarch64. Build + publish on each target platform.
- **strelka 2.9.10**. In the catalog but blocked: it needs Python 2, which
  nixpkgs now marks insecure / has removed. The build compiles strelka from
  source against the catalog's maintained **pypy27** (PyPy 2.7) — no insecure
  CPython anywhere.
- **cutadapt 5.2**. `cutadapt` and its `dnaio`/`xopen` deps were dropped from
  nixpkgs; built from their PyPI sdists (reusing `isal` from nixpkgs).
- **verifybamid2 1.0.5**. Never in the catalog; built from source with a pinned
  `htslib` 1.9 and its bundled SVD reference panels.

Each `build/<tool>/` is a **self-contained, build-only** Flox environment. For
these four the recipe is a Nix expression in `.flox/pkgs/<tool>/default.nix`
(`build/gatkcondaenv/` is the exception: a manifest build, see below) and produces
a reproducible artifact with `flox build`. The build hosts fetch only hash-pinned sources. There's no pre-build
network access beyond those. The actual build is performed in the Nix sandbox.

## A fifth build that isn't a tool: `gatkcondaenv`

`gatk` itself is catalog-native, but four of its tools (`DetermineGermlineContigPloidy`,
`GermlineCNVCaller`, `PostprocessGermlineCNVCalls`, `NVScoreVariants`) shell out to
Python and `import gcnvkernel`. That Python side is a conda environment, which
`wgs/gatk_4-6-2-0` materializes on first activation from an **explicit conda lock**.

`build/gatkcondaenv/` packages the data that makes this possible:

| File | Purpose |
|---|---|
| `gatkcondaenv.<system>.lock` | explicit conda lock per platform (exact package URLs, no solving) |
| `gatkcondaenv.macos.yml`, `gatkcondaenv.aarch64-linux.yml` | the ported specs the two non-x86 locks were solved from |
| `gatkPythonPackageArchive.zip` | gcnvkernel + scorevariants, which GATK ships inside its release rather than on any package index |
| `clear-execstack.py` | clears a spurious executable-stack flag on conda-forge's `libtorch_cpu.so` |

Two things make it different from the other four builds:

- **It is data, not code.** The recipe is a manifest build (`[build.gatkcondaenv]`
  in `.flox/env/manifest.toml`, `sandbox = "pure"`) that copies files into
  `$out/share/gatkcondaenv/`. There is no `.flox/pkgs/*.nix`.
- **It exists for portability, not availability.** The other builds package
  software the catalog lacks. This one packages files that used to be read from
  the repo — which silently failed for anyone without a checkout, since
  `$FLOX_ENV_PROJECT` is the repo only when the environment *is* a checkout of it.
  Shipping them as a catalog package is what lets `flox activate -r
  flox-labs/gatk-4-6-2-0` work on a machine that has never cloned anything.

GATK's official `gatkcondaenv.yml` pins Intel-only MKL, so the two non-x86 locks
are ports of the spec rather than re-exports. Locks are architecture-specific and
must be solved on the target hardware; see `build/gatkcondaenv/README.md` for how
to add one, and `wgs/gatk_4-6-2-0/README.md` for the full story.

## Maintainer workflow: publish the built packages

Five things get published: the four built tools, plus the `gatkcondaenv` data
package. The runtime envs under `wgs/{bwa,strelka,cutadapt,verifybamid2}_*`
reference `flox-labs/<tool>`, and `wgs/gatk_4-6-2-0` references
`flox-labs/gatkcondaenv`; each only resolves once its package is published. For
each build subdirectory:

```bash
cd build/<tool>
flox build <tool>                 # verify it builds → ./result-<tool>
# the repo must be committed and pushed to a remote (publish needs a clean tree)
flox auth login
flox publish -o flox-labs <tool>
```

Then finalize each runtime env. e.g. for `cutadapt`:

```bash
flox install -d pharos-flox/wgs/cutadapt_5-2 flox-labs/cutadapt
flox activate -d pharos-flox/wgs/cutadapt_5-2 -- cutadapt --version
```

The provided binary isn't always named after the package: strelka's entrypoints
are `configureStrelkaGermlineWorkflow.py` / `configureStrelkaSomaticWorkflow.py`,
and verifybamid2's binary is `VerifyBamID` (run it with no args for usage).

All four built *tools* have been verified on **x86_64-linux**: strelka calls
the demo variants under pypy27, cutadapt trims adapters, VerifyBamID runs its
bundled test, and bwa indexes + aligns.

`strelka` has since been carried to both aarch64 targets: `aarch64-darwin` is
verified end to end (builds, 9/9 unit-test suites, and both the somatic and
germline demos matching expected results), and `aarch64-linux` needed two further
build fixes (see `build/strelka/README.md`). The other three builds remain
structured but unproven on aarch64 — build them on that hardware to confirm.

To build and publish these packages under your own Flox org namespace, clone this
repo and run `flox publish -o <your_org_namespace> <package_name>` from each build
subdirectory:

```bash
git clone <your-repo-host>/<this-repo>.git && cd <this-repo>
flox auth login                     # authenticate once

cd build/bwa           && flox publish -o <your_org_namespace> bwa           && cd ../..
cd build/strelka       && flox publish -o <your_org_namespace> strelka       && cd ../..
cd build/cutadapt      && flox publish -o <your_org_namespace> cutadapt      && cd ../..
cd build/verifybamid2  && flox publish -o <your_org_namespace> verifybamid2  && cd ../..
cd build/gatkcondaenv  && flox publish -o <your_org_namespace> gatkcondaenv  && cd ../..
```

Note on **multi-platform packages**: `flox publish` builds natively for the
current system, so a package that spans systems is published by running the
command on each. **All five builds target three systems** — `x86_64-linux`,
`aarch64-linux`, `aarch64-darwin` — so publish each once per system. Only
x86_64-linux is verified for all of them. `strelka` and `gatkcondaenv` are
additionally verified on both aarch64 targets — `gatkcondaenv` end to end, by
pulling `flox-labs/gatk-4-6-2-0` from FloxHub onto a machine with no checkout and
running gCNV from it. The remaining aarch64 builds are structured but unproven
(verifybamid2 in particular may need recipe adjustments — validate on the target
hardware).

Replace `<your-repo-host>/<this-repo>` with wherever you host this repo (e.g.
`https://github.com/<your-org>/pharos-flox`) and `<your_org_namespace>` with your
FloxHub org or personal handle. `flox publish` runs from inside each build
subdirectory — it needs a clean, pushed git tree, and the trailing name is the
build target, matching the directory under `.flox/pkgs/`. The recipes are
self-contained (only hash-pinned remote fetches), so each builds correctly from
its subdirectory of the monorepo. Consumers then install with
`flox install <your_org_namespace>/<package_name>`.
