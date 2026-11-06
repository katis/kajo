# Sample

A Kajo app made by `kajo new`. The app is Smalltalk in `src/` (Tonel,
package `Sample`); the Swift in `Sources/App.swift` only hands the
bundled image to Kajo.

- `project.yml` is the xcodegen spec: `Sample-macOS` and `Sample-iOS`
  over the same `src/`. Make the Xcode project with `xcodegen generate`.
- Debug bundles a development image of the kernel and `src/` and serves
  the Kajo development protocol from launch (Bonjour `_kajo-dev._tcp`,
  named "Sample on <device>"). Its pairing screen is a shake away on
  iOS and in the app menu (Pairing…, shift-command-P) on the Mac.
- Release bundles a sealed release image of the same sources and links
  no development code; it does not serve.
- The images are built by `scripts/build-images.sh` in a build phase,
  with the `kajo` of the Kajo that `KajoPin/Package.swift` pins.

Develop live from the Mac: run the Debug build, read the token off its
pairing screen, and connect the tools or the CLI to `bonjour:<name>`;
an accepted change is written to `src/` when the client is given
`--project src`. A relaunch starts from the bundled image again, so
build again to keep what you changed.
