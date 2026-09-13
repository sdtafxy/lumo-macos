// Lumo 原生核心 —— 单页效果预览
// 增强必须「先看再跑」：一份几十页的扫描件全量处理动辄几十秒，
// 而用户真正要确认的只有一件事——「这个模式对我这份文件好不好看」。
// 所以这里只渲染一页、只跑增强（不做 OCR、不做压缩），几百毫秒出结果。
import Foundation
import CoreGraphics
import ImageIO

/// 预览结果用 PNG 字节而不是 CGImage 往回传：
/// CGImage 不是 Sendable，跨线程带回主线程会逼着到处写 @unchecked；
/// Data 天然安全，主线程一行 NSImage(data:) 就能还原。
public struct PreviewPair: Sendable {
    public let before: Data
    public let after: Data
    /// 这一步的过程说明（目前是裁边结论与"这页已经够干净"的提示）。
    /// 默认空数组，老调用方不用改。
    public let notes: [String]
    public init(before: Data, after: Data, notes: [String] = []) {
        self.before = before
        self.after = after
        self.notes = notes
    }
}

public enum PagePreview {
    /// 渲染第 page 页（1 起算），按 spec 增强，返回前后的 PNG。
    /// dpi 故意压到 110：预览只为看效果，按原稿 300dpi 渲染只是白等。
    public static func beforeAfter(fileURL: URL, page: Int, spec: EnhanceSpec,
                                   dpi: Int = 110, maxDim: Int = 900) -> PreviewPair? {
        guard let doc = PDFReader.open(fileURL) else { return nil }
        let n = PDFReader.pageCount(doc)
        guard n > 0 else { return nil }
        let idx = min(max(0, page - 1), n - 1)
        guard let raw = PDFReader.render(doc, idx, dpi: dpi) else { return nil }
        guard let b = png(fit(raw, maxDim: maxDim)) else { return nil }
        // 用 applyReporting：用户在预览界面拉滑块，"这页已经够干净、
        // 看不出变化"这句话必须当场告诉他，否则他会以为滑块坏了（L4）。
        let applied = Enhance.applyReporting(raw, spec: spec)
        guard let a = png(fit(applied.image, maxDim: maxDim)) else { return nil }
        return PreviewPair(before: b, after: a, notes: applied.notes)
    }

    public static func pageCount(_ fileURL: URL) -> Int {
        guard let doc = PDFReader.open(fileURL) else { return 0 }
        return PDFReader.pageCount(doc)
    }

    private static func fit(_ image: CGImage, maxDim: Int) -> CGImage {
        guard maxDim > 0, max(image.width, image.height) > maxDim else { return image }
        let s = Double(maxDim) / Double(max(image.width, image.height))
        return resized(image, scale: s) ?? image
    }

    /// PNG 编码。CLI 的对照图导出、产物回看都要用，所以对外暴露。
    public static func png(_ image: CGImage) -> Data? { pngImpl(image) }

    private static func pngImpl(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
