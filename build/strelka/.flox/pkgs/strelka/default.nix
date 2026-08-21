# strelka 2.9.10 built from source and wired to PyPy 2.7 (pypy27).
#
# strelka was dropped from nixpkgs because it needs Python 2. Rather than vendor
# insecure EOL CPython 2.7, this builds the stock upstream source (which bundles
# boost/htslib/samtools/pyFlow — no network at build time) and points every
# Python entrypoint at the catalog's maintained pypy27 interpreter.
#
# Build with:  flox build strelka
{
  stdenv,
  overrideCC,
  gcc13,
  fetchurl,
  cmake,
  zlib,
  bzip2,
  pypy27,
}:
# gcc13 is the oldest compiler still shipped in the nixpkgs base (gcc<=12 pruned).
# It builds bundled boost 1.58 fine; nixpkgs removed the `gccNStdenv` adapters, so
# swap the compiler into the default stdenv explicitly.
let
  gcc13Stdenv = overrideCC stdenv gcc13;
in
gcc13Stdenv.mkDerivation rec {
  pname = "strelka";
  version = "2.9.10";

  src = fetchurl {
    url = "https://github.com/Illumina/strelka/releases/download/v${version}/strelka-${version}.release_src.tar.bz2";
    sha256 = "45e78efec6e5272697f1d0a95851c7ae0d623dc8f93846e11fe37f15da9f1e30";
  };

  nativeBuildInputs = [ cmake ];
  buildInputs = [
    zlib
    bzip2
    pypy27
  ];

  # strelka ships its own configure + bundled cmake bootstrap; do not let the
  # nixpkgs cmake setup-hook drive configuration.
  dontUseCmakeConfigure = true;

  # cmake 4.x removed compatibility with strelka's cmake_minimum_required(2.8.12).
  # Exported for the whole build so the nested boost/htslib cmake calls honor it too.
  CMAKE_POLICY_VERSION_MINIMUM = "3.5";

  # strelka's C++ (circa 2018) relied on transitive standard-library includes that
  # gcc13's cleaner headers no longer pull in (e.g. std::numeric_limits). Force the
  # common ones in. C++-only (CXXFLAGS) so it never reaches the bundled C sources
  # of htslib/samtools, where a C++ header would be a hard error.
  CXXFLAGS = "-include limits -include cstdint -include memory";

  preConfigure = ''
    # strelka's find_package(PythonInterp) searches for python2.7/python2/python;
    # without these it silently grabs the sandbox python3 and fails to byte-compile
    # the bundled Python 2 sources. Point those names at pypy.
    mkdir -p "$TMPDIR/pybin"
    ln -s ${pypy27.interpreter} "$TMPDIR/pybin/python2.7"
    ln -s ${pypy27.interpreter} "$TMPDIR/pybin/python2"
    ln -s ${pypy27.interpreter} "$TMPDIR/pybin/python"
    export PATH="$TMPDIR/pybin:$PATH"

    # The pure build sandbox has no /usr/bin/env, so strelka's configure and its
    # bundled build scripts (shebanged #!/usr/bin/env bash|python2) fail to launch.
    # Rewrite them to concrete store paths. Runs with pypy already on PATH so the
    # python2 shebangs resolve too.
    patchShebangs .
  '';

  configurePhase = ''
    runHook preConfigure
    mkdir -p build
    cd build
    ../configure --prefix="$out" --jobs=''${NIX_BUILD_CORES:-4}
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-4}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install
    runHook postInstall
  '';

  postInstall = ''
    # pyFlow 1.1.20 leaks the file handle when writing the task-params pickle:
    #   pickle.dump(taskInfo, open(argFile, "w"))
    # CPython's refcounting closes it immediately (flushing); PyPy's GC does not,
    # so child tasks read an empty pickle and die with EOFError. Force a close.
    substituteInPlace "$out/lib/python/pyflow/pyflow.py" \
      --replace-fail 'pickle.dump(taskInfo, open(argFile, "w"))' \
                     'pyflowArgFp = open(argFile, "w"); pickle.dump(taskInfo, pyflowArgFp); pyflowArgFp.close()'

    # Make the package self-contained: pin every python entrypoint (bin, libexec,
    # lib) to pypy instead of relying on a `python2` on the consumer's PATH.
    # pyFlow launches the libexec helper scripts by their shebang at runtime, so
    # bin alone is not enough. Replace the python2 form before the bare python form
    # (the latter is a substring of the former).
    for f in $(grep -rlI '#!/usr/bin/env python' "$out"); do
      substituteInPlace "$f" \
        --replace-quiet '#!/usr/bin/env python2' '#!${pypy27.interpreter}' \
        --replace-quiet '#!/usr/bin/env python' '#!${pypy27.interpreter}'
    done

    # makeRunScript.py templates this interpreter string into the runWorkflow.py
    # that `configure...WorkflowDemo.py` generates for the user at runtime. Pin it
    # to pypy too, else every generated workflow gets a broken `env python2` shebang.
    substituteInPlace "$out/lib/python/makeRunScript.py" \
      --replace-fail '"/usr/bin/env python2"' '"${pypy27.interpreter}"'

    # Store mtimes are all epoch 0, so a stale .pyc would shadow the patched .py.
    # Drop byte-compiled caches; pypy recompiles from source on first run.
    find "$out" -name '*.pyc' -delete
  '';

  meta = {
    description = "Strelka2 germline and somatic small-variant caller (wired to PyPy 2.7)";
    homepage = "https://github.com/Illumina/strelka";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
