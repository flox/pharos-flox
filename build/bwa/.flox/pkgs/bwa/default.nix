# bwa 0.7.17 built from source, with cross-platform support.
#
# The Flox catalog ships bwa@0.7.17 for x86_64 only: this 2017 release hard-codes
# x86 SSE2 intrinsics (`#include <emmintrin.h>` in ksw.c) and predates upstream ARM
# support (added in later releases). This recipe restores the two things needed to
# build it everywhere:
#   * aarch64: drop in the sse2neon header (maps SSE2 intrinsics -> ARM NEON) under
#     the name bwa reaches for, so the SIMD code compiles unchanged.
#   * modern gcc (>=10 defaults to -fno-common): restore -fcommon, which bwa 0.7.17
#     relies on for its tentative global definitions (bwa_verbose, bwa_rg_id, ...).
#
# Build with:  flox build bwa   (native per system; run it on each target platform)
{
  lib,
  stdenv,
  fetchFromGitHub,
  zlib,
}:
let
  # SSE2 -> NEON translation header, used only on aarch64.
  sse2neon = fetchFromGitHub {
    owner = "DLTcollab";
    repo = "sse2neon";
    rev = "v1.9.1";
    sha256 = "0vkbghdgqqkr9zwr7gh4fmf8alv1lbf10avh8jablvdjj3hrjgbq";
  };
  isAarch64 = stdenv.hostPlatform.isAarch64;
in
stdenv.mkDerivation rec {
  pname = "bwa";
  version = "0.7.17";

  src = fetchFromGitHub {
    owner = "lh3";
    repo = "bwa";
    rev = "v${version}";
    sha256 = "0mzda4awpcvl0q1bskhqrrbiw4k3q7cn407wb10ihdwd0k3whfga";
  };

  buildInputs = [ zlib ];

  # On aarch64, bwa's `#include <emmintrin.h>` has no system header to resolve to.
  # Provide sse2neon under that name; -I. (below) puts it on the include path first.
  postPatch = lib.optionalString isAarch64 ''
    cp ${sse2neon}/sse2neon.h .
    printf '#define SSE2NEON_SUPPRESS_WARNINGS 1\n#include "sse2neon.h"\n' > emmintrin.h
  '';

  # bwa's Makefile hard-codes CC=gcc; route it through the stdenv compiler wrapper.
  makeFlags = [ "CC=${stdenv.cc.targetPrefix}cc" ];

  # -fcommon: bwa 0.7.17 needs it under gcc>=10 (tentative-definition globals).
  # aarch64: -I. so our emmintrin.h shim wins; sse2neon provides the SSE2 API.
  env.NIX_CFLAGS_COMPILE = "-fcommon" + lib.optionalString isAarch64 " -I. -D__SSE2__";

  enableParallelBuilding = true;

  # bwa has no `make install`; place the artifacts by hand.
  installPhase = ''
    runHook preInstall
    install -Dm755 bwa "$out/bin/bwa"
    install -Dm644 bwa.1 "$out/share/man/man1/bwa.1"
    install -Dm644 README.md "$out/share/doc/bwa/README.md"
    runHook postInstall
  '';

  meta = {
    description = "Burrows-Wheeler Aligner for short-read mapping (0.7.17; cross-platform, incl. aarch64 via sse2neon)";
    homepage = "https://github.com/lh3/bwa";
    mainProgram = "bwa";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
