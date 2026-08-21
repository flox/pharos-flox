# gatkcondaenv assets

A data-only Flox package: the conda locks and helper files that
`wgs/gatk_4-6-2-0` needs to materialize **gatkcondaenv**, GATK's Python
environment, at runtime.

```bash
flox build gatkcondaenv                  # -> ./result-gatkcondaenv
flox publish -o flox-labs gatkcondaenv   # maintainer, once per target system
```

## Why this package exists

The gatk environment's `[hook]` reads three files at activation: the
per-platform conda lock, `gatkPythonPackageArchive.zip` (gcnvkernel), and
`clear-execstack.py`. It used to read them from `$FLOX_ENV_PROJECT`.

`$FLOX_ENV_PROJECT` is just *the directory containing `.flox`*. When the
environment is a checkout of this repo, that is the repo, and everything works.
When the environment is pulled from FloxHub with `flox activate -r
flox-labs/gatk`, it is `~/.cache/flox/remote/<owner>/<name>`, which contains
only `.flox`:

```
~/.cache/flox/remote/<owner>/<name>/
└── .flox
```

None of the three files are there. The hook took its "no lock for this
platform" branch and silently degraded to Java-only tools, with a message that
blamed a missing lock when the real problem was a missing checkout.

Shipping the files as a catalog package fixes that: the gatk environment
installs this package and reads `$FLOX_ENV/share/gatkcondaenv`, a path that
exists however the environment was obtained. This is the pattern in FLOX.md
§9.9 (packaging assets), the same one used for config and schema bundles.

## What it does and does not contain

Contains the ~200 KB of *metadata*:

| File | Purpose |
|---|---|
| `gatkcondaenv.x86_64-linux.lock` | explicit conda lock, Linux |
| `gatkcondaenv.aarch64-darwin.lock` | explicit conda lock, Apple Silicon |
| `gatkcondaenv.macos.yml` | the spec the darwin lock was solved from, for regeneration/audit |
| `gatkPythonPackageArchive.zip` | gcnvkernel + scorevariants, pip-installed by the hook |
| `clear-execstack.py` | clears the spurious exec-stack flag on `libtorch_cpu.so` |

It does **not** contain the ~1.8 GB conda environment itself. First activation
still downloads the pinned packages from anaconda.org. Vendoring the built
environment is not a drop-in extension of this package: conda bakes absolute
prefix paths into scripts and shebangs, so a materialized env is not cleanly
relocatable to a Nix store path. `flox containerize` is the route to a fully
sealed artifact.

## Versioning

`version` is `<GATK release>-<short commit>`, e.g. `4.6.2.0-ffe4631`.

The GATK part identifies which release the locks belong to. The suffix exists
because adding a lock for a new platform does not change the GATK version, and
republishing the same version would collide with what is already in the catalog.

The hash is **written by hand and is the parent commit**, not the commit that
ships the change. That is not an oversight: a commit cannot contain its own hash,
so any derived value names a different tree than the one actually published.
Pinning the parent is off by one on purpose. `version.command = "git rev-parse
--short HEAD"` would also fail here regardless, since `sandbox = "pure"` copies
only git-tracked files and leaves `.git` out of the build.

So: bump it by hand whenever the packaged files change, to the short hash of
`HEAD` immediately before that commit.

## Keeping it in sync

The locks are generated per platform, on that platform, as described in
`wgs/gatk_4-6-2-0/README.md`. This directory is the source of truth; when a new
lock is generated, add it here and bump `version` in the build.

`aarch64-linux` has no lock yet. It is listed in `[options].systems` so the
package builds and installs there, and the hook reports the missing lock and
leaves the Java tools working.
