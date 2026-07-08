Vendored from the official qpdf Windows release
(https://github.com/qpdf/qpdf/releases/tag/v12.3.2), `qpdf-12.3.2-msvc64.zip`,
`bin/` directory. No fully static single-file build is published upstream —
`qpdf.exe` depends on `qpdf30.dll` plus the MSVC redistributable DLLs, all
included here so users don't need to install qpdf or the VC++ redistributable
separately. `LICENSE.txt` is qpdf's Apache-2.0 license, kept alongside the
binaries per its redistribution terms.
