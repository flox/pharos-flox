# VerifyBamID2 (verifybamid2) 1.0.5 built from source.
#
# Upstream's CMake git-clones htslib at build time; that can't happen in the pure
# build sandbox, so htslib 1.9 (contemporary with this release) is pinned as a Nix
# source, pre-placed, and built explicitly before cmake runs. The 104 MB SVD
# resource panels ship inside the source tree and are installed to $out/resource.
#
# Build with:  flox build verifybamid2
{
  stdenv,
  overrideCC,
  gcc13,
  fetchFromGitHub,
  cmake,
  autoconf,
  gnu-config,
  perl,
  zlib,
  bzip2,
  curl,
  openssl,
}:
let
  htslibSrc = fetchFromGitHub {
    owner = "samtools";
    repo = "htslib";
    rev = "1.9";
    sha256 = "19awbnpfhfrz9dp3svcbl46g7rvaqdw27v72hs365hkaiz80pyar";
  };
  # The bundled Eigen (2018) does not parse under gcc-15's stricter template
  # checking; gcc 13 (oldest in the nixpkgs base) compiles it. See the strelka
  # build for the same pattern.
  gcc13Stdenv = overrideCC stdenv gcc13;
in
gcc13Stdenv.mkDerivation rec {
  pname = "verifybamid2";
  version = "1.0.5";

  src = fetchFromGitHub {
    owner = "Griffan";
    repo = "VerifyBamID";
    rev = "1.0.5";
    sha256 = "1d9il6zjii434ygm93zparxq98b34f218g50g1yyvpwnn9fpagsr";
  };

  nativeBuildInputs = [
    cmake
    autoconf
    perl
  ];
  buildInputs = [
    zlib
    bzip2
    curl
    openssl
  ];

  # We drive cmake by hand (in-source layout with a build/ subdir, matching upstream).
  dontUseCmakeConfigure = true;

  # cmake 4.x rejects the project's cmake_minimum_required(2.8.4).
  CMAKE_POLICY_VERSION_MINIMUM = "3.5";

  postPatch = ''
    # Pre-place the pinned htslib source where the ExternalProject expects it, and
    # neutralize the git-clone/configure/build steps (we build htslib ourselves,
    # deterministically, below) so nothing reaches for the network.
    cp -r ${htslibSrc}/. samtools/htslib/
    chmod -R u+w samtools/htslib
    sed -i \
      -e 's|GIT_REPOSITORY.*||' \
      -e 's|GIT_TAG.*||' \
      -e 's|CONFIGURE_COMMAND .*|CONFIGURE_COMMAND "true"|' \
      -e 's|BUILD_COMMAND make.*|BUILD_COMMAND "true"|' \
      -e 's|ExternalProject_Add(HTSLIB|ExternalProject_Add(HTSLIB DOWNLOAD_COMMAND "" INSTALL_COMMAND "true" TEST_COMMAND ""|' \
      CMakeLists.txt
  '';

  preConfigure = ''
    # Build htslib 1.9 statically before cmake links against it (upstream leaves the
    # add_dependencies(VerifyBamID HTSLIB) line commented out, so build order is not
    # otherwise guaranteed). `make install prefix=.` populates ./include for the
    # compile and leaves ./libhts.a in the tree for the link.
    pushd samtools/htslib
    # htslib's git source omits the generated config.guess/config.sub that its
    # autoconf configure needs (AC_CANONICAL_*); supply them from gnu-config.
    cp -f ${gnu-config}/config.guess ${gnu-config}/config.sub .
    autoheader
    autoconf
    # htslib 1.9's own host detection emits a malformed "unknown-Linux" triplet that
    # config.sub rejects; pass explicit build/host to bypass auto-detection.
    ./configure --disable-lzma \
      --build=${stdenv.buildPlatform.config} \
      --host=${stdenv.hostPlatform.config}
    make -j''${NIX_BUILD_CORES:-4}
    make install prefix="$PWD"
    popd
  '';

  configurePhase = ''
    runHook preConfigure
    mkdir -p build
    cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j''${NIX_BUILD_CORES:-4}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/resource"
    # Binary is emitted to <source>/bin (CMAKE_RUNTIME_OUTPUT_DIRECTORY), i.e. ../bin
    # relative to the build/ dir we are in.
    install -Dm755 ../bin/VerifyBamID "$out/bin/VerifyBamID"
    # Bundle the pre-computed SVD reference panels; users pass --SVDPrefix/--UDPath
    # etc. pointing at these.
    cp -r ../resource/. "$out/resource/"
    runHook postInstall
  '';

  meta = {
    description = "VerifyBamID2: ancestry-aware DNA contamination estimation from sequence reads";
    homepage = "https://github.com/Griffan/VerifyBamID";
    mainProgram = "VerifyBamID";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
