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

When the environment is a checkout of this repo, `$FLOX_ENV_PROJECT` is the repo
and everything works. When it is pulled from FloxHub with `flox activate -r
flox-labs/gatk`, `$FLOX_ENV_PROJECT` is **the current working directory** --
whatever directory the command was run from:

```
$ cd /tmp && flox activate -r flox-labs/gatk-4-6-2-0 -- sh -c 'echo $FLOX_ENV_PROJECT'
/private/tmp
```

(The pulled environment itself is cached under
`~/.cache/flox/remote/<owner>/<name>/`, which holds only `.flox` and none of the
repo's files -- but that path is not what `$FLOX_ENV_PROJECT` points to either.)

So none of the three files are found. The hook took its "no lock for this
platform" branch and silently degraded to Java-only tools, with a message that
blamed a missing lock when the real problem was a missing checkout. And because
the path is an arbitrary cwd rather than a fixed location, the failure is not even
consistent: run from the wrong directory and it could in principle pick up a
same-named lock.

Shipping the files as a catalog package fixes that: the gatk environment
installs this package and reads `$FLOX_ENV/share/gatkcondaenv`, a path that
exists however the environment was obtained. This is the pattern in FLOX.md
§9.9 (packaging assets), the same one used for config and schema bundles.

## What it does and does not contain

Contains the ~200 KB of *metadata*:

| File | Purpose |
|---|---|
| `gatkcondaenv.x86_64-linux.lock` | explicit conda lock, Intel Linux |
| `gatkcondaenv.aarch64-linux.lock` | explicit conda lock, ARM Linux |
| `gatkcondaenv.aarch64-darwin.lock` | explicit conda lock, Apple Silicon |
| `gatkcondaenv.macos.yml` | the spec the darwin lock was solved from, for regeneration/audit |
| `gatkcondaenv.aarch64-linux.yml` | the spec the ARM Linux lock was solved from, likewise |
| `gatkPythonPackageArchive.zip` | gcnvkernel + scorevariants, pip-installed by the hook |
| `clear-execstack.py` | clears the spurious exec-stack flag on `libtorch_cpu.so` (a no-op on platforms whose torch build does not set it, see below) |

Both aarch64 specs exist because GATK's own `gatkcondaenv.yml.template` pins
Intel-only MKL and cannot be solved unchanged off x86. There is no spec for
`x86_64-linux`: that lock solves from GATK's template as published.

It does **not** contain the ~1.8 GB conda environment itself. First activation
still downloads the pinned packages from anaconda.org. Vendoring the built
environment is not a drop-in extension of this package: conda bakes absolute
prefix paths into scripts and shebangs, so a materialized env is not cleanly
relocatable to a Nix store path. `flox containerize` is the route to a fully
sealed artifact.

## Versioning

`version` is `<GATK release>-<short commit>`, e.g. `4.6.2.0-0000e63`.

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

All three target systems now have a lock. The hook's "no lock for this platform"
branch therefore no longer fires for any of them; it remains for a fourth system
nobody has generated one on.

### The exec-stack fix is platform-conditional in effect

`clear-execstack.py` reports **0 libraries on `aarch64-linux`, and that is
correct**, not a failure. The flag it clears is set by conda-forge's
`pytorch-2.1.0-cpu_mkl_*` build that the `x86_64-linux` lock pins; the only
pytorch 2.1.0 published for `linux-aarch64` is `cpu_generic_*`, whose
`libtorch_cpu.so` carries `PT_GNU_STACK` as `RW-`. Every one of the 2,264 64-bit
ELFs in the materialized ARM Linux env was checked: none has the `PF_X` bit. The
script's detection path was confirmed working on that same env by setting the bit
on a copy, which it then found and cleared.
