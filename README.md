# Floxified WGS tools

Flox environment equivalents of the `wgs/` container images. Each Dockerfile
packaged a **stock upstream tool** (no custom patches), so instead of rebuilding
the Docker recipe we install the same tool (a) from the Flox catalog where it
exists (b) or from a small, reproducible Flox build when it doesn't.

## Layout

```
floxified/
  wgs/<tool>_<ver>/.flox/     runtime environments (what you activate/use)
  build/<tool>/.flox/         build-only environments for tools missing from the catalog
```

## The tools

| Tool | Version | How it's provided |
|------|---------|-------------------|
| samtools | 1.19.2 | catalog-native (exact) |
| seqtk | 1.4 | catalog-native (exact) |
| fastqc | 0.12.1 | catalog-native (exact) |
| bwa | 0.7.17 | catalog-native (exact; x86_64 — catalog has no aarch64 0.7.17) |
| gatk | 4.6.2.0 | catalog-native (exact) |
| strelka | 2.9.10 | **built** → `flox-labs/strelka` (see below) |
| cutadapt | 5.2 | **built** → `flox-labs/cutadapt` |
| verifybamid2 | 1.0.5 | **built** → `flox-labs/verifybamid2` |

The catalog-native environments work as-is:

```bash
flox activate -d floxified/wgs/samtools_1-19-2 -- samtools --version
```

## Why three tools are built instead of installed

They aren't in the Flox catalog:

- **strelka 2.9.10**. In the catalog but blocked: it needs Python 2, which
  nixpkgs now marks insecure / has removed. The build compiles strelka from
  source against the catalog's maintained **pypy27** (PyPy 2.7) — no insecure
  CPython anywhere.
- **cutadapt 5.2**. `cutadapt` and its `dnaio`/`xopen` deps were dropped from
  nixpkgs; built from their PyPI sdists (reusing `isal` from nixpkgs).
- **verifybamid2 1.0.5**. Never in the catalog; built from source with a pinned
  `htslib` 1.9 and its bundled SVD reference panels.

Each `build/<tool>/` is a **standalone, build-only** Flox repo. Its recipe lives
in `.flox/pkgs/<tool>/default.nix` and produces a reproducible artifact with
`flox build`. The build hosts fetch only hash-pinned sources. There's no pre-build
network access beyond those. The actual build is performed in the Nix sandbox.

## Maintainer workflow: publish the three built tools

The runtime envs under `wgs/{strelka,cutadapt,verifybamid2}_*` reference
`flox-labs/<tool>` and only resolve once the package is published. For each build
subdirectory:

```bash
cd build/<tool>
flox build <tool>                 # verify it builds → ./result-<tool>
# the repo must be committed and pushed to a remote (publish needs a clean tree)
flox auth login
flox publish -o flox-labs <tool>
```

Then finalize each runtime env. e.g. for `cutadapt`:

```bash
flox install -d floxified/wgs/cutadapt_5-2 flox-labs/cutadapt
flox activate -d floxified/wgs/cutadapt_5-2 -- cutadapt --version
```

The provided binary isn't always named after the package: strelka's entrypoints
are `configureStrelkaGermlineWorkflow.py` / `configureStrelkaSomaticWorkflow.py`,
and verifybamid2's binary is `VerifyBamID` (run it with no args for usage).

All three built artifacts have been verified locally: strelka calls the demo
variants under pypy27, cutadapt trims adapters, and VerifyBamID runs with its
bundled panels. Only the `flox publish` step remains, and it is intentionally
left to a maintainer with `flox-labs` access.

To build and publish these packages under your own Flox org namespace, clone this
repo and run `flox publish -o <your_org_namespace> <package_name>` from each build
subdirectory:

```bash
git clone <your-repo-host>/<this-repo>.git && cd <this-repo>
flox auth login                     # authenticate once

cd build/strelka       && flox publish -o <your_org_namespace> strelka       && cd ../..
cd build/cutadapt      && flox publish -o <your_org_namespace> cutadapt      && cd ../..
cd build/verifybamid2  && flox publish -o <your_org_namespace> verifybamid2  && cd ../..
```

Replace `<your-repo-host>/<this-repo>` with wherever you host this repo (e.g.
`https://github.com/<your-org>/pharos-flox`) and `<your_org_namespace>` with your
FloxHub org or personal handle. `flox publish` runs from inside each build
subdirectory — it needs a clean, pushed git tree, and the trailing name is the
build target, matching the directory under `.flox/pkgs/`. The recipes are
self-contained (only hash-pinned remote fetches), so each builds correctly from
its subdirectory of the monorepo. Consumers then install with
`flox install <your_org_namespace>/<package_name>`.
