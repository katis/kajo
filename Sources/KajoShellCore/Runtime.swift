import Foundation
import KajoApp
import KajoAppDevelopment
import KajoDev
import KajoVM

/// A shell's runtime (module 11a: KajoApp's, with what the shells add): the
/// client transport of primitive 164 attached (its token prompt in the
/// pairing presenter's secure field), the image's kind noted for the
/// telemetry.
@MainActor func makeShellRuntime(imagePath: String, options: Headless.Options, platform: ShellPlatform,
                                 events: @escaping @Sendable ([UInt8]) -> Void, pairing: PairingPresenter?) throws -> ShellRuntime {
    let host = ClientHost()
    var options = options
    if options.native == nil { options.native = shellNativeModule(for: imagePath) }
    let rt = try ShellRuntime(imagePath: imagePath, options: options, platform: platform, events: events, client: host.callback)
    rt.attachClient(host, secrets: pairing)
    Telemetry.noteImage(release: rt.vm.isReleaseImage)
    return rt
}

/// AOT 1, part 5: with the launch argument `native=1`, an image's compiled
/// module (`<image>.native.dylib` beside it, which apps/Shared/build-images.sh
/// builds when the shell is built with KAJO_SHELL_AOT=1) is handed to the
/// VM through the host surface (`Headless.Options.native`). Without the
/// argument, or without the file, the image runs interpreted; a module
/// that does not load is printed and the image runs interpreted.
func shellNativeModule(for imagePath: String) -> NativeModule? {
    guard LaunchOptions()["native"] == "1" else { return nil }
    let path = imagePath + ".native.dylib"
    guard FileManager.default.fileExists(atPath: path) else {
        print("native=refused no \((path as NSString).lastPathComponent)")
        return nil
    }
    switch NativeModule.load(dylib: path) {
    case .success(let m):
        print("native=loaded \((path as NSString).lastPathComponent)")
        return m
    case .failure(let e):
        print("native=refused \(e)")
        return nil
    }
}
