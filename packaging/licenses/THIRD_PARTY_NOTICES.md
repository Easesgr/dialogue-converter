# Bundled runtime notices

The application source is MIT licensed. Its frozen bridge includes unmodified Python runtime components under their original licenses.

- CPython 3.14.3: Python Software Foundation and historical licenses, included as `PYTHON-LICENSE.txt`. Additional notices are in `PYTHON-THIRD-PARTY.rst`.
- PyInstaller 6.22.3 bootloader and runtime support: GPL with the bootloader distribution exception; runtime hooks use Apache 2.0. See `PYINSTALLER-COPYING.txt` and `APACHE-2.0.txt`.
- OpenSSL runtime libraries included by the official Python distribution: Apache 2.0, with accompanying OpenSSL notices.
- Zstandard 1.5.7: BSD license, included as `ZSTD-LICENSE.txt`. The Python bindings' notices are in `PYTHON-THIRD-PARTY.rst`.

Build-only packages in `requirements-build.txt` are not installed on the user's machine. Optional Tcl/Tk frameworks from the downloaded maintainer runtime are not bundled in the converter.

Sources: https://www.python.org/ ; https://github.com/python/cpython/tree/v3.14.3 ; https://github.com/pyinstaller/pyinstaller/tree/v6.22.3 ; https://github.com/openssl/openssl
