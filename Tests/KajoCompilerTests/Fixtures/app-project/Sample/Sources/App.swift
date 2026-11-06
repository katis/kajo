// The app's whole Swift, the same for the Mac and iOS targets: the
// bundled image to Kajo. Debug adds the development half, which serves
// the development protocol from launch; Release links none of it.

import KajoPin
#if DEBUG
import KajoPinDevelopment
#endif

@main enum Main {
    static func main() {
        let app = KajoAppConfiguration(name: "Sample", appClass: "SampleApp")
        #if DEBUG
        KajoApplication.main(app, development: Development())
        #else
        KajoApplication.main(app)
        #endif
    }
}
