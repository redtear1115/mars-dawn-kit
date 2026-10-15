#if os(macOS)
import CoreGraphics
import Foundation

/// Counts image XObjects actually drawn in an exported PDF, by walking each page's `/Resources`
/// (recursing into form XObjects), so a loaded image that silently failed to print is caught
/// even though the DOM says it loaded (redtear1115/mars-dawn#2).
enum PDFImageInspector {
    static func imageXObjectCount(at url: URL) -> Int {
        guard let document = CGPDFDocument(url as CFURL) else { return 0 }
        var total = 0
        for index in 1...max(document.numberOfPages, 0) where index <= document.numberOfPages {
            guard let page = document.page(at: index) else { continue }
            total += count(inPage: page)
        }
        return total
    }

    private static func count(inPage page: CGPDFPage) -> Int {
        guard let dict = page.dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return 0 }
        var total = 0
        count(inResources: resources, total: &total)
        return total
    }

    /// Recurses into any form XObject's own `/Resources`. PDF resource dictionaries don't have
    /// cyclic references in practice (a form can't legally contain itself), so no visited set.
    private static func count(inResources resources: CGPDFDictionaryRef, total: inout Int) {
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }

        var subXObjectDictionaries: [CGPDFDictionaryRef] = []
        var imageCount = 0
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return true }
            guard let streamDict = CGPDFStreamGetDictionary(stream) else { return true }
            var subtypePointer: UnsafePointer<Int8>?
            if CGPDFDictionaryGetName(streamDict, "Subtype", &subtypePointer),
               let subtypePointer, String(cString: subtypePointer) == "Image" {
                imageCount += 1
            }
            var formResources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(streamDict, "Resources", &formResources), let formResources {
                subXObjectDictionaries.append(formResources)
            }
            return true
        }, nil)
        total += imageCount
        for sub in subXObjectDictionaries { count(inResources: sub, total: &total) }
    }
}
#endif
