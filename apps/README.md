# apps

The native shells (module 9a), each an xcodegen spec with its generated
Xcode project, over the root package (`../..`) as a local Swift package:

- `KajoShell-macOS/`: the **Kajo app** since module 11b (target and scheme
  `Kajo`, bundle `dev.katajamaki.kajo`). Launched with no arguments it is
  the product (the tools on the development image, File > New App...,
  File > Install Command Line Tool...; `docs/modules/distribution.md`);
  with `mode=` it is the measurement shell (`scripts/mac-shell.sh`).
  `scripts/dist.sh` builds it into `Kajo-<version>.dmg`.
- `KajoShell-iOS/`: the iOS measurement shell (scheme `KajoShell`).
- `Shared/`: the image build phase both run and the Smalltalk the
  scenarios and the scripted session load.
