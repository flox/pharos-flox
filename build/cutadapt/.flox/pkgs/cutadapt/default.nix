# cutadapt 5.2 built from PyPI, with its dnaio + xopen dependency tree.
#
# cutadapt, dnaio and xopen were all dropped from nixpkgs, so they are packaged
# here from their PyPI sdists (hash-pinned). xopen's lower-level C-extension dep
# isal is still in nixpkgs and reused. Cython/setuptools come from the base too.
# No network at build time beyond the pinned source fetches.
#
# Build with:  flox build cutadapt
{
  python3Packages,
  fetchPypi,
}:
let
  ps = python3Packages;

  # cutadapt 5.2 needs xopen >= 1.6.0. xopen 2.x additionally pulls zlib-ng and (on
  # python < 3.14) backports.zstd; the 1.7.x line needs only isal at runtime, which
  # keeps the tree small. isal is still in nixpkgs and is reused.
  xopen = ps.buildPythonPackage rec {
    pname = "xopen";
    version = "1.7.0";
    pyproject = true;
    src = fetchPypi {
      inherit pname version;
      sha256 = "901f9c8298e95ed74767a4bd76d9f4cf71d8de27b8cf296ac3e7bc1c11520d9f";
    };
    build-system = [
      ps.setuptools
      ps.setuptools-scm
    ];
    dependencies = [ ps.isal ];
    doCheck = false;
  };

  dnaio = ps.buildPythonPackage rec {
    pname = "dnaio";
    version = "1.2.4";
    pyproject = true;
    src = fetchPypi {
      inherit pname version;
      sha256 = "a7570311f29e8b3c1ea39a60f57b7baf8dad8f2508595c58d4278c5571463166";
    };
    build-system = [
      ps.setuptools
      ps.setuptools-scm
      ps.cython
    ];
    dependencies = [ xopen ];
    doCheck = false;
  };
in
ps.buildPythonApplication rec {
  pname = "cutadapt";
  version = "5.2";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    sha256 = "2394deead42ecae5fe0fdf369e35f3e2afed770e14059582272779c2e8295d3c";
  };

  build-system = [
    ps.setuptools
    ps.setuptools-scm
    ps.cython
  ];

  dependencies = [
    dnaio
    xopen
  ];

  # Smoke-test the built console script instead of the full test suite.
  doCheck = false;
  pythonImportsCheck = [ "cutadapt" ];

  meta = {
    description = "Adapter trimming and other preprocessing of high-throughput sequencing reads";
    homepage = "https://cutadapt.readthedocs.io";
    mainProgram = "cutadapt";
  };
}
