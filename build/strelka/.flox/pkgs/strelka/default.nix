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
# Compiler selection is per-platform:
#
#   Linux  - gcc13, the oldest compiler still shipped in the nixpkgs base
#            (gcc<=12 pruned). nixpkgs removed the `gccNStdenv` adapters, so swap
#            the compiler into the default stdenv explicitly.
#   Darwin - the native clang stdenv. gcc13 must NOT be used here: strelka's
#            bundled boost 1.58 bootstraps its own 2014-era jam engine with `cc`,
#            and gcc13 on aarch64-darwin miscompiles it. The resulting bjam
#            segfaults while loading boostcpp.jam, so boost never builds and cmake
#            reports only "Failed to build boost library 1.58.0" with an empty
#            boost.build.error.txt (bjam died before writing to it). Built by
#            clang, the same jam engine and boost build cleanly.
let
  buildStdenv = if stdenv.hostPlatform.isDarwin then stdenv else overrideCC stdenv gcc13;
in
buildStdenv.mkDerivation rec {
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

  # boost 1.58's jam engine (modules/path.c) calls file_query() without declaring
  # it. clang 16+ makes implicit function declarations a hard error (C99/C23), which
  # aborts boost's bootstrap.sh before bjam is ever produced. Demote it to a warning
  # for the whole build; strelka's own sources are unaffected.
  NIX_CFLAGS_COMPILE = "-Wno-implicit-function-declaration";

  preConfigure = ''
    # Bundled boost 1.58 predates C++17 and still uses std::auto_ptr, which libc++
    # removed in C++17 (libstdc++ only deprecates it, so the Linux/gcc path is
    # unaffected). clang defaults to gnu++17, so pin the boost bootstrap to C++11 --
    # the same standard strelka compiles its own sources with. Boost.Build does not
    # read CXXFLAGS from the environment, so the flag has to go on the bjam command
    # line that strelka's boost.cmake assembles.
    substituteInPlace src/cmake/boost.cmake \
      --replace-fail 'set (BJAM_OPTIONS ''${BJAM_OPTIONS} "toolset=clang")' \
                     'set (BJAM_OPTIONS ''${BJAM_OPTIONS} "toolset=clang" "cxxflags=-std=c++11")'

    # The bundled bgzf_extras Makefile hardcodes `CC = gcc`. The clang stdenv has no
    # `gcc` on PATH (only cc/clang), so pass CC on the make command line, where it
    # overrides the Makefile assignment.
    substituteInPlace redist/CMakeLists.txt \
      --replace-fail 'COMMAND $(MAKE) -C "''${BGZFX_DIR}" all 2>| bgzf_extras.build.log' \
                     'COMMAND $(MAKE) -C "''${BGZFX_DIR}" CC=cc all 2>| bgzf_extras.build.log'

    # boost 1.58's mpl::integral_c<E, 0> eagerly instantiates its `prior` member as
    # integral_c<E, static_cast<E>(-1)>. For an unscoped enum with no fixed underlying
    # type, -1 is outside the enum's value range, so the cast is not a constant
    # expression and clang rejects it; gcc accepts it. This reaches strelka through
    # Boost.Test's use of boost::numeric conversion traits, and breaks every unit-test
    # translation unit. Giving the three boost::numeric mixture enums a fixed
    # underlying type makes the cast well-defined and the whole chain valid.
    bstmp=$(mktemp -d)
    tar xjf redist/boost_1_58_0_subset.tar.bz2 -C "$bstmp"
    for e in sign_mixture udt_builtin_mixture int_float_mixture; do
      substituteInPlace "$bstmp/boost_1_58_0_subset/boost/numeric/conversion/$e"_enum.hpp \
        --replace-fail "enum $e"_enum "enum $e"_enum" : int"
    done

    # Boost.Build 1.58 predates aarch64. It deduces the target architecture by
    # compiling probe files, and the ARM probe only accepts __arm__/__thumb__/
    # __TARGET_ARCH_ARM/__TARGET_ARCH_THUMB/_ARM/_M_ARM -- never __aarch64__, the
    # only one aarch64 gcc defines. So every probe fails, `architecture` comes back
    # empty while `address-model` correctly deduces 64, and gcc.jam's guard
    # (`if $(arch) != arm`, its sole mention of arm) falls through and passes -m64,
    # an option the aarch64 gcc backend does not have. All 85 boost targets then
    # fail and cmake reports "Failed to build boost library 1.58.0".
    #
    # Teach the probe about __aarch64__ so the deduction is simply correct. No-op on
    # x86_64, and on Darwin regardless: clang-darwin.jam declares its own compile
    # actions and never calls gcc.setup-address-model, which is why the aarch64
    # -m64 bug is invisible there. clang-linux.jam does call it, so this also covers
    # a future clang build on aarch64-linux.
    substituteInPlace "$bstmp/boost_1_58_0_subset/libs/config/checks/architecture/arm.cpp" \
      --replace-fail '!defined(_ARM) && !defined(_M_ARM)' \
                     '!defined(_ARM) && !defined(_M_ARM) && !defined(__aarch64__)'

    tar cjf redist/boost_1_58_0_subset.tar.bz2 -C "$bstmp" boost_1_58_0_subset
    rm -rf "$bstmp"

    # Bundled rapidjson 1.1.0 defines GenericStringRef::operator= with a body that
    # assigns to its const members. clang rejects it when the class is instantiated;
    # gcc never reaches it. Nothing in strelka assigns a GenericStringRef, so delete
    # the operator outright. rapidjson is only unpacked during the build, so the
    # redist tarball itself has to be patched and repacked here.
    rjtmp=$(mktemp -d)
    tar xjf redist/rapidjson-1.1.0.tar.bz2 -C "$rjtmp"
    substituteInPlace "$rjtmp/rapidjson-1.1.0/include/rapidjson/document.h" \
      --replace-fail 'GenericStringRef& operator=(const GenericStringRef& rhs) { s = rhs.s; length = rhs.length; }' \
                     'GenericStringRef& operator=(const GenericStringRef& rhs) = delete;'
    tar cjf redist/rapidjson-1.1.0.tar.bz2 -C "$rjtmp" rapidjson-1.1.0
    rm -rf "$rjtmp"

    # HtsMergeStreamer::next() pops the stream queue and then calls getCurrentPos(),
    # which is _streamQueue.top() -- undefined when that pop emptied the queue, i.e.
    # on the last record of every region. libstdc++ happens to hand back the slot
    # just popped, so the comparison trivially passes and Linux never notices; with
    # libc++, clang proves the empty branch unreachable and emits a trap, so strelka2
    # dies with SIGTRAP the moment a stream is exhausted. Only run the ordering check
    # while a current record actually exists.
    substituteInPlace src/c++/lib/starling_common/HtsMergeStreamer.cpp \
      --replace-fail 'if (getCurrentPos() < last.pos)' \
                     'if ((! _streamQueue.empty()) && (getCurrentPos() < last.pos))'

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

    # PyPy's GC sizes its nursery from the L2/L3 cache size read out of
    # /sys/devices/system/cpu/cpuX/cache, and prints
    #   Warning: cannot find your CPU L2 & L3 cache size in ...
    # to stderr at interpreter startup when it cannot. arm64 kernels routinely
    # publish the cache levels with no `size` attribute, and containers often mask
    # the tree entirely, so this fires on aarch64-linux and inside containers on
    # any arch.
    #
    # That warning is fatal here, not cosmetic: pyFlow's task wrapper writes its
    # signal protocol to stderr and parses that same file back line by line
    # (checkWrapFileExit), failing the task if any line's 5th field is not
    # [wrapperSignal]. The warning is the first line of every wrapper's stderr, so
    # every task "fails" while reporting taskExitCode 0, and both demos die on
    # their first mkdir. Setting PYPY_GC_NURSERY skips the probe -- and 4MB is
    # exactly what PyPy falls back to when the probe fails, so this pins the size
    # it would have used anyway rather than retuning the GC. pyFlow spawns task
    # wrappers with an inherited environment, so setting it once in the parent
    # covers every task. No-op under CPython.
    substituteInPlace "$out/lib/python/pyflow/pyflow.py" \
      --replace-fail 'moduleDir = os.path.abspath(os.path.dirname(__file__))' \
                     'os.environ.setdefault("PYPY_GC_NURSERY", "4M"); moduleDir = os.path.abspath(os.path.dirname(__file__))'

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
      "aarch64-darwin"
    ];
  };
}
