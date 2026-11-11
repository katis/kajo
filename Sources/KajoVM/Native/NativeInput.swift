// AOT 1: the image `kajo aot` generates from, loaded exactly as `kajo run`
// loads it (kasm files into a fresh image, or an image file), so the oops
// the generator folds are the ones the run's image has.

extension Headless {
    /// The loaded image and its nil, true and false (the caller destroys
    /// it), or the load's failure.
    package static func imageForNative(files: [(path: String, text: String)], image bytes: [UInt8]?,
                                       options: Options = Options()) -> Result<Image, Failure> {
        let config: ObjectMemoryConfig
        switch configs(options) {
        case .success(let c): config = c.1
        case .failure(let f): return .failure(f)
        }
        if let bytes {
            do { return .success(try Image.load(image: bytes, config: config)) } catch { return .failure(.load("\(error)")) }
        }
        let image: Image
        do { image = try Image(memory: ObjectMemory(config)) } catch { return .failure(.load("\(error)")) }
        do {
            try image.load(files.map { (file: $0.path, text: $0.text) })
        } catch {
            image.destroy()
            return .failure(.load("\(error)"))
        }
        return .success(image)
    }
}

extension Image {
    package var nilOop: UInt64 { nilObject.raw }
    package var trueOop: UInt64 { trueObject.raw }
    package var falseOop: UInt64 { falseObject.raw }
    package func close() { destroy() }
}
