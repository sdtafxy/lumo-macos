// Lumo 原生核心 —— 编排引擎
// 感知 → 推荐 → 处理 → 压缩，串成一条自动工作流。App 与 CLI 共用。
import Foundation
import CoreGraphics

public enum PipelineError: LocalizedError {
    case cannotOpen(String)
    case emptyPageSelection
    case nothingRendered

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let p):     return "无法打开 PDF：\(p)"
        case .emptyPageSelection:    return "页码范围没有选中任何页面"
        case .nothingRendered:       return "页面渲染失败，文件可能已损坏"
        }
    }
}

public enum Pipeline {
    /// 处理分辨率。
    /// 关键约束：**不放大**。源件只有 150dpi 时重采样到 200dpi 不会变清晰，
    /// 只会凭空多出 78% 的像素，压完比源文件还大——CI 里就是这样翻车的。
    /// 反过来说也不该低于 150：再低 OCR 就开始掉字。
    public static func procDpi(_ estimated: Int) -> Int {
        guard estimated > 0 else { return 300 }
        return min(max(estimated, 150), 300)
    }

    // MARK: - 体检 + 推荐 + 预估

    public static func report(fileURL: URL) throws -> ReportResponse {
        guard let doc = PDFReader.open(fileURL) else {
            throw PipelineError.cannotOpen(fileURL.lastPathComponent)
        }
        let n = PDFReader.pageCount(doc)
        guard n > 0 else { throw PipelineError.cannotOpen(fileURL.lastPathComponent) }

        let fileSize = Self.fileSize(fileURL)
        let box = PDFReader.mediaBox(doc, 0)
        let dpi = PDFReader.estimateDPI(fileURL, pageWidthPt: box.width)

        // 文字层：整份文件的字符数 / 页数，超过阈值就认为已经有文字层
        let chars = PDFReader.existingTextChars(fileURL)
        let hasText = chars > n * 20
        let textRatio = min(1.0, Double(chars) / Double(max(1, n * 200)))

        let sample = Array(0..<min(n, 6))
        var modes: [String] = []
        var skewSum = 0.0
        var noiseSum = 0.0
        var bgSum = 0.0
        var paperSum = 0.0
        for i in sample {
            // 同理，抽样渲染也要有池：120dpi 的位图虽然小，但 6 页叠起来
            // 在大文件上依然可观，而且这些位图用完就该还回去。
            autoreleasepool {
                guard let img = PDFReader.render(doc, i, dpi: 120) else { return }
                modes.append(Analyzer.colorMode(of: img).rawValue)
                skewSum += Enhance.detectSkew(img)
                noiseSum += Analyzer.noiseLevel(img)
                bgSum += Analyzer.backgroundUnevenness(img)
                paperSum += Enhance.paperLevel(img)
            }
        }
        let cnt = max(1, modes.count)
        let docMode = modes.contains("color") ? "color" : (modes.contains("gray") ? "gray" : "mono")

        let analysis = Analysis(pageCount: n, fileSize: fileSize, hasTextLayer: hasText,
                                textRatio: textRatio, colorMode: docMode, estimatedDpi: dpi,
                                skewAngle: skewSum / Double(cnt),
                                noiseLevel: noiseSum / Double(cnt),
                                bgUnevenness: bgSum / Double(cnt),
                                paperWhite: paperSum / Double(cnt),
                                pageModes: modes)

        var rec = Workflow.recommend(analysis)
        var plans = Workflow.definePlans(analysis)

        // 用真实抽样页「增强后」编码来预估体积，比任何公式都准
        let dpi2 = procDpi(dpi)
        var samples: [CGImage] = []
        for i in Array(0..<min(n, 4)) {
            // 这里的 img 必须留下（体积预估要拿它当样本），但 raw 不必——
            // 池子保证 Enhance.apply 之后那张原图尽快还回去。
            autoreleasepool {
                guard let raw = PDFReader.render(doc, i, dpi: dpi2) else { return }
                let enhanced = Enhance.apply(raw, spec: rec.enhance)
                samples.append(enhanced)
            }
        }
        if !samples.isEmpty {
            for k in plans.indices {
                let est = Compressor.estimateBytes(samples: samples,
                                                   spec: plans[k].settings.asCompressSpec,
                                                   pageCount: n)
                plans[k].estBytes = est
                plans[k].estRatio = est > 0 ? Double(fileSize) / Double(est) : 0
            }
        }
        // 推荐档默认对齐「均衡」
        if let balanced = plans.first(where: { $0.recommended == true }) {
            rec.compress = balanced.settings.asCompressSpec
        }

        return ReportResponse(fileId: fileURL.path, analysis: analysis, recommendation: rec,
                              plans: plans, procDpi: dpi2,
                              availableLangs: OCR.languages.map { $0.id })
    }

    // MARK: - 处理

    public static func process(fileURL: URL, spec: ProcessSpec, outURL: URL,
                               previewDir: URL? = nil,
                               progress: ((Double, String) -> Void)? = nil) throws -> ProcessResponse {
        let t0 = Date()
        guard let doc = PDFReader.open(fileURL) else {
            throw PipelineError.cannotOpen(fileURL.lastPathComponent)
        }
        let total = PDFReader.pageCount(doc)
        let idxs = PDFReader.parsePageSelection(total, spec.pages)
        guard !idxs.isEmpty else { throw PipelineError.emptyPageSelection }

        let dpi = procDpi(spec.procDpi ?? 300)
        progress?(0, "已选择 \(idxs.count) 页")

        // 流式写入：处理一页写一页，内存不再随页数增长。
        // 以前是把所有 OutputPage 攒在数组里最后一次性写，配合 300dpi 位图
        // 不回收，几 MB 的源文件就能吃掉几个 GB（见 StreamingWriter 的说明）。
        let writer = try PDFWriter.StreamingWriter(url: outURL,
                                                   title: fileURL.deletingPathExtension().lastPathComponent + "（Lumo）",
                                                   pageCount: idxs.count)

        var writtenPages = 0
        var ocrChars = 0
        var mrcPages = 0
        var ocrEngine: String?
        var allText = ""
        var notes: [String] = []
        /// 被判为"已经够干净"的页码。逐页各发一条 warning 会把日志刷爆，
        /// 所以先攒起来，循环结束后汇总成一条（见下方）。
        var cleanPages: [Int] = []
        var previewBefore: String?
        var previewAfter: String?

        for (k, i) in idxs.enumerated() {
            // autoreleasepool 是这里的关键之一。PDFReader.render / Enhance.apply /
            // Compressor 走的是 CoreGraphics 与 Core Image，产生的对象交给
            // autorelease 管理；在循环里不设池，它们要等整个函数返回才释放，
            // 于是几十页的位图会一直堆着。池子让每轮结束就把这一页的东西还回去。
            try autoreleasepool {
                guard let raw = PDFReader.render(doc, i, dpi: dpi) else { return }
                if k == 0, let dir = previewDir {
                    if let d = makePreviewPNG(raw), let p = writeTo(dir, "before.png", d) { previewBefore = p }
                }
                // 走 applyReporting 而不是 apply：裁边结论与"这页已经够干净"
                // 都必须随 warnings 回到用户眼前。裁边是全流程里唯一会丢像素的
                // 步骤，用户有权知道机器为什么动了手、或为什么没动手。
                let applied = Enhance.applyReporting(raw, spec: spec.enhance)
                let img = applied.image
                for n in applied.notes where !notes.contains(n) { notes.append(n) }
                if applied.judgedClean { cleanPages.append(i + 1) }

                if k == 0, let dir = previewDir {
                    if let d = makePreviewPNG(img), let p = writeTo(dir, "after.png", d) { previewAfter = p }
                }

                var lines: [OCRLine]?
                if spec.ocr.enabled && !spec.ocr.skip {
                    if let r = try? OCR.recognize(img, langID: spec.ocr.lang) {
                        lines = r.lines
                        ocrChars += r.text.count
                        allText += r.text
                        ocrEngine = OCR.engineName
                    } else {
                        notes.append("第 \(i + 1) 页未识别出文字")
                    }
                }

                let pe = Compressor.encodeWithLayers(img, spec.compress)
                let encoded = pe.flat
                if pe.mrc != nil { mrcPages += 1 }
                if let note = encoded.note, !notes.contains(note) { notes.append(note) }

                // 写出去就完事：encoded / mrc / lines / img / raw 都在这一轮
                // 末尾失去引用，不再有"攒到最后"的数组把它们钉在内存里。
                try writer.append(OutputPage(image: encoded, dpi: dpi, lines: lines,
                                             visibleText: spec.ocr.output == "editable",
                                             mrc: pe.mrc))
                writtenPages += 1
            }
            progress?(Double(k + 1) / Double(idxs.count), "处理中 \(k + 1)/\(idxs.count) 页")
        }

        // 干净页提示汇总成一条：逐页各发一条的话，几十页的文件会刷出几十行，
        // 那种"提示"只会被当成噪音，而它本来是要解释"为什么滑块看起来没反应"。
        if !cleanPages.isEmpty {
            notes.append("第 \(Self.pageList(cleanPages)) 页体检判定为已经够干净：背景强度照常按设定应用，但这几页视觉上可能看不出变化")
        }

        guard writtenPages > 0 else { throw PipelineError.nothingRendered }
        try writer.finish()

        let inSize = Self.fileSize(fileURL)
        let outSize = Self.fileSize(outURL)
        let saved = inSize > 0 ? (1.0 - Double(outSize) / Double(inSize)) * 100.0 : 0

        var sidecar: String?
        if spec.ocr.output == "editable" && !allText.isEmpty {
            let p = outURL.deletingPathExtension().appendingPathExtension("txt")
            if (try? allText.write(to: p, atomically: true, encoding: .utf8)) != nil {
                sidecar = p.path
            }
        }

        return ProcessResponse(fileId: fileURL.path, outPath: outURL.path,
                               inSize: inSize, outSize: outSize, savedPct: saved,
                               pagesProcessed: writtenPages, ocrEngine: ocrEngine,
                               ocrChars: ocrChars,
                               steps: summarize(spec, idxs.count, mrcPages),
                               elapsedSec: Date().timeIntervalSince(t0),
                               previewBefore: previewBefore, previewAfter: previewAfter,
                               sidecar: sidecar, download: outURL.path, warnings: notes)
    }

    // MARK: - 辅助

    private static func summarize(_ spec: ProcessSpec, _ n: Int, _ mrcPages: Int = 0) -> [String] {
        var s = ["处理 \(n) 页"]
        if let p = spec.enhance.preset, p != "original" {
            s.append("增强模式：\(EnhancePreset(p).title)")
        }
        if spec.enhance.autoCrop == true { s.append("自动裁边 + 透视校正") }
        if spec.enhance.deskew == true { s.append("纠偏") }
        if spec.enhance.bgRemove == true { s.append("背景去除") }
        if spec.enhance.descreen == true { s.append("去网纹") }
        if let a = spec.enhance.sharpen, a > 0 { s.append("文本锐化") }
        // 把实际生效的强度写进步骤里：L4 那个"拉了半天没反应"的问题，
        // 一半是滑块真的没生效，另一半是**用户看不出它有没有生效**。
        // 日志里报出这个数字，至少能让人一眼确认请求传到底了。
        if Enhance.usesBackgroundStrength(spec.enhance) {
            let v = Int(((spec.enhance.bgStrength ?? Enhance.defaultStrength) * 100).rounded())
            s.append("背景清理强度 \(v)%")
        }
        if spec.ocr.enabled && !spec.ocr.skip {
            s.append("OCR 识别（\(OCR.name(of: spec.ocr.lang))）")
        } else {
            s.append("跳过 OCR")
        }
        let mode = spec.compress.adaptive ? "自适应" : spec.compress.colorMode
        s.append("压缩：\(mode) / \(spec.compress.colorEncoder)+\(spec.compress.monoEncoder) / 质量\(spec.compress.quality)")
        if mrcPages > 0 { s.append("\(mrcPages) 页启用分层（MRC）：文字 1bit 蒙版 + 低分辨率背景") }
        return s
    }

    /// 把页码压成 "1,3-5" 的区间写法。几十页的文件逐个列出来会占满一行，
    /// 而这条提示要表达的重点是"有这么一批页"，不是"具体是哪几页"。
    static func pageList(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(j > i ? "\(sorted[i])-\(sorted[j])" : "\(sorted[i])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    private static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let v = attrs?[.size] as? NSNumber { return v.intValue }
        if let v = attrs?[.size] as? Int { return v }
        return 0
    }

    private static func writeTo(_ dir: URL, _ name: String, _ data: Data) -> String? {
        let p = dir.appendingPathComponent(name)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
                || FileManager.default.fileExists(atPath: dir.path) else { return nil }
        do { try data.write(to: p); return p.path } catch { return nil }
    }
}
