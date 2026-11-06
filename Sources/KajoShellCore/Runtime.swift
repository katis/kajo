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
    let rt = try ShellRuntime(imagePath: imagePath, options: options, platform: platform, events: events, client: host.callback)
    rt.attachClient(host, secrets: pairing)
    Telemetry.noteImage(release: rt.vm.isReleaseImage)
    return rt
}
