// Module 8d: installing from Smalltalk through the whole stack: the kernel's
// LiveCompileTest in a development image and in the same image sealed, the
// release flag in the header and in the loader's report, `kajo build-image
// --release`.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoVM

@Suite(.serialized) struct LiveInstallTests {
    @Test func installingWorksInADevelopmentImageAndIsForbiddenInTheSameImageSealed() throws {
        #expect(Headless.isReleaseImage(kernelImage) == false)
        // every LiveCompileTest in the development image (the slow one
        // makes every method of the image)
        let (r, lines) = runKernelTests(kernelImage, ["--filter", "LiveCompileTest"])
        let report = TestReport(lines)
        #expect(try r.get() == 0, "\(report.failures.prefix(3))")
        #expect(report.total >= 9 && report.passed == report.total)

        let sealed = try Headless.seal(image: kernelImage).get()
        #expect(Headless.isReleaseImage(sealed) == true)
        let img = try Image.load(image: sealed)
        #expect(img.isRelease)
        // sealing survives a load and a save, and nothing clears it
        let again = img.saveImage()
        img.destroy()
        #expect(Headless.isReleaseImage(again) == true)
        let (sr, slines) = runKernelTests(sealed, ["--filter", "LiveCompileTest>>testTheReleaseFlag"])
        let sreport = TestReport(slines)
        #expect(try sr.get() == 0, "\(sreport.failures.prefix(3))")
        #expect(sreport.total == 1 && sreport.passed == 1)
        // and the rest of the kernel's tests still pass in it
        let (rr, rlines) = runKernelTests(sealed, ["--filter", "ClassVariableTest"])
        #expect(try rr.get() == 0 && TestReport(rlines).passed == TestReport(rlines).total)
    }

    @Test func theLoaderReportsTheKind() throws {
        var o = Headless.Options()
        o.heapMiB = 256
        let dev = Headless.run(image: kernelImage, options: o)
        #expect(dev.report.contains { $0.name == "image" && $0.value == "development" })
        let sealed = try Headless.seal(image: kernelImage).get()
        let rel = Headless.run(image: sealed, options: o)
        #expect(rel.report.contains { $0.name == "image" && $0.value == "release" })
        // a release flag next to an unknown bit is refused, not read
        var bad = sealed
        bad[40] |= 2
        #expect(throws: (any Error).self) { try Image.load(image: bad).destroy() }
    }

    @Test func buildImageReleaseMarksTheImage() throws {
        var o = KernelBuild.Options()
        o.release = true
        let r = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory]), options: o)
        #expect(Headless.isReleaseImage(r.image) == true)
    }
}
