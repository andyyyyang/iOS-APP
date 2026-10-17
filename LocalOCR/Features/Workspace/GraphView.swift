import SwiftUI

// MARK: - 資料

/// 關聯圖的顏色：依最上層資料夾分組（同一個資料夾同一個顏色），淺色、深色模式各一組。
enum GraphPalette {
    static let colors: [Color] = [
        .adaptive(dark: 0x7AA5FF, light: 0x4F7FE0), // 藍
        .adaptive(dark: 0x5CCB8A, light: 0x2F9E62), // 綠
        .adaptive(dark: 0xF2A65A, light: 0xE07F2E), // 橘
        .adaptive(dark: 0xB08CF0, light: 0x8A5CD6), // 紫
        .adaptive(dark: 0xF07FA5, light: 0xD9547F), // 粉
        .adaptive(dark: 0x4CC2BA, light: 0x22958E), // 青
        .adaptive(dark: 0xE0BC45, light: 0xB8901A), // 黃
    ]
    /// 其他資料夾與最上層的筆記
    static let other = Color.adaptive(dark: 0x8B93A3, light: 0x8A90A0)
}

/// 關聯圖的顯示選項。
struct GraphOptions: Equatable {
    /// 顯示沒有任何連結的筆記
    var showOrphans = false
    /// 顯示 AI 對話紀錄（它們連到很多筆記，會變成很大的中心點）
    var showHistory = false
    /// 隱藏的資料夾（最上層資料夾名稱，空字串是最上層的筆記）
    var hiddenGroups: Set<String> = []
}

/// 關聯圖的資料：節點是筆記，連線是 [[連結]]（不分方向），依最上層資料夾分組上色。
struct GraphData {
    struct Node {
        let path: String
        let title: String
        let group: String
        let degree: Int
    }

    struct Group: Identifiable, Equatable {
        let name: String
        /// 符合條件的筆記數（含隱藏的）
        let count: Int
        let colorIndex: Int?

        var id: String { name }
        var title: String { name.isEmpty ? "最上層" : name }
        var color: Color { colorIndex.map { GraphPalette.colors[$0] } ?? GraphPalette.other }
    }

    var nodes: [Node] = []
    var edges: [(Int, Int)] = []
    /// 圖例：筆記多的資料夾在前
    var groups: [Group] = []

    static func group(of path: String) -> String {
        guard let slash = path.firstIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    @MainActor
    static func build(store: NotesStore, options: GraphOptions, limit: Int = 1500) -> GraphData {
        let historyPrefix = KnowledgeAssistant.historyFolder + "/"
        // 還沒下載的筆記的連結來自伺服器的索引；沒有索引時只有這台裝置上的筆記知道連結
        let hasIndex = !VaultIndexStore.shared.notes.isEmpty
        let eligible = store.notes.filter { note in
            (hasIndex || note.isLocal) && (options.showHistory || !note.path.hasPrefix(historyPrefix))
        }
        let eligiblePaths = Set(eligible.map(\.path))

        var adjacency: [String: Set<String>] = [:]
        for note in eligible {
            for target in store.outgoingLinks(of: note) where eligiblePaths.contains(target) {
                adjacency[note.path, default: []].insert(target)
                adjacency[target, default: []].insert(note.path)
            }
        }

        // 顏色依資料夾的筆記數排名（不受篩選影響，切換時顏色不變）
        var counts: [String: Int] = [:]
        for note in eligible where options.showOrphans || !(adjacency[note.path]?.isEmpty ?? true) {
            counts[group(of: note.path), default: 0] += 1
        }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var colorIndex: [String: Int] = [:]
        for (rank, entry) in ranked.filter({ !$0.key.isEmpty }).prefix(GraphPalette.colors.count).enumerated() {
            colorIndex[entry.key] = rank
        }
        let groups = ranked.map { Group(name: $0.key, count: $0.value, colorIndex: colorIndex[$0.key]) }

        let selected = eligible
            .filter { note in
                !options.hiddenGroups.contains(group(of: note.path)) && (options.showOrphans || !(adjacency[note.path]?.isEmpty ?? true))
            }
            .sorted { (adjacency[$0.path]?.count ?? 0) > (adjacency[$1.path]?.count ?? 0) }
            .prefix(limit)
        let index = Dictionary(uniqueKeysWithValues: selected.enumerated().map { ($0.element.path, $0.offset) })
        var edges: [(Int, Int)] = []
        var degrees = Array(repeating: 0, count: selected.count)
        for (path, a) in index {
            for neighbor in adjacency[path] ?? [] {
                if let b = index[neighbor], a < b {
                    edges.append((a, b))
                    degrees[a] += 1
                    degrees[b] += 1
                }
            }
        }
        let nodes = selected.enumerated().map { offset, note in
            Node(path: note.path, title: note.title, group: group(of: note.path), degree: degrees[offset])
        }
        return GraphData(nodes: nodes, edges: edges, groups: groups)
    }
}

// MARK: - 排版

/// 力導向排版（d3-force 的做法）：節點互斥用 Barnes-Hut 四分樹估算（上千個節點也順），
/// 連線像彈簧、整體往中心收。初始位置依資料夾分群，同一個資料夾的筆記會聚在一起。
final class GraphLayout: @unchecked Sendable {
    private(set) var x: [Double]
    private(set) var y: [Double]
    private var vx: [Double]
    private var vy: [Double]
    private let links: [(Int, Int)]
    private let linkStrength: [Double]
    private let linkBias: [Double]
    private(set) var alpha = 1.0
    var alphaTarget = 0.0
    private let alphaMin = 0.002
    private let alphaDecay = 1 - pow(0.002, 1.0 / 300)
    private let velocityDecay = 0.6
    private let charge = -42.0
    private let linkDistance = 36.0
    private let gravity = 0.05
    private let theta2 = 0.81
    /// 正在拖曳的節點（固定在手指位置）
    var pinned: Int?
    private var pinnedPoint = CGPoint.zero

    var count: Int { x.count }
    var isSettled: Bool { alpha < alphaMin && pinned == nil && alphaTarget == 0 }

    init(count: Int, edges: [(Int, Int)], groups: [Int], previous: [Int: CGPoint] = [:]) {
        links = edges
        var linkCount = Array(repeating: 0, count: count)
        for (a, b) in edges {
            linkCount[a] += 1
            linkCount[b] += 1
        }
        linkStrength = edges.map { 1 / Double(max(1, min(linkCount[$0.0], linkCount[$0.1]))) }
        linkBias = edges.map { Double(linkCount[$0.0]) / Double(max(1, linkCount[$0.0] + linkCount[$0.1])) }

        // 每個資料夾一個起點，資料夾裡的筆記以葵花籽螺旋散開
        let groupCount = max(1, (groups.max() ?? 0) + 1)
        let spread = 18 * sqrt(Double(max(count, 1)))
        var seen = Array(repeating: 0, count: groupCount)
        var xs: [Double] = []
        var ys: [Double] = []
        for index in 0..<count {
            if let point = previous[index] {
                xs.append(point.x)
                ys.append(point.y)
                continue
            }
            let group = groups.indices.contains(index) ? groups[index] : 0
            let angle = 2 * Double.pi * Double(group) / Double(groupCount)
            let centerX = groupCount > 1 ? cos(angle) * spread * 0.6 : 0
            let centerY = groupCount > 1 ? sin(angle) * spread * 0.6 : 0
            let k = Double(seen[group])
            seen[group] += 1
            let a = k * 2.399963
            let r = 9 * sqrt(k + 0.5)
            xs.append(centerX + cos(a) * r)
            ys.append(centerY + sin(a) * r)
        }
        x = xs
        y = ys
        vx = Array(repeating: 0, count: count)
        vy = Array(repeating: 0, count: count)
        if !previous.isEmpty { alpha = previous.count == count ? 0.3 : 0.6 }
    }

    func reheat(_ value: Double = 0.5) {
        alpha = max(alpha, value)
    }

    func pin(_ index: Int, at point: CGPoint) {
        guard index < count else { return }
        pinned = index
        pinnedPoint = point
        x[index] = point.x
        y[index] = point.y
        vx[index] = 0
        vy[index] = 0
    }

    func tick(_ steps: Int) {
        for _ in 0..<steps {
            guard !isSettled else { return }
            step()
        }
    }

    func step() {
        let n = count
        guard n > 0 else { return }

        // 互斥（Barnes-Hut）
        let root = Quad.build(x: x, y: y)
        for i in 0..<n {
            apply(root, to: i)
        }

        // 連線
        for (k, link) in links.enumerated() {
            let (s, t) = link
            var dx = x[t] + vx[t] - x[s] - vx[s]
            var dy = y[t] + vy[t] - y[s] - vy[s]
            if dx == 0 { dx = jiggle() }
            if dy == 0 { dy = jiggle() }
            var l = sqrt(dx * dx + dy * dy)
            l = (l - linkDistance) / l * alpha * linkStrength[k]
            dx *= l
            dy *= l
            let b = linkBias[k]
            vx[t] -= dx * b
            vy[t] -= dy * b
            vx[s] += dx * (1 - b)
            vy[s] += dy * (1 - b)
        }

        // 往中心收，然後移動
        for i in 0..<n {
            if i == pinned {
                x[i] = pinnedPoint.x
                y[i] = pinnedPoint.y
                vx[i] = 0
                vy[i] = 0
                continue
            }
            vx[i] += -x[i] * gravity * alpha
            vy[i] += -y[i] * gravity * alpha
            vx[i] *= velocityDecay
            vy[i] *= velocityDecay
            x[i] += vx[i]
            y[i] += vy[i]
        }
        alpha += (alphaTarget - alpha) * alphaDecay
    }

    private func apply(_ quad: Quad, to i: Int) {
        guard quad.mass > 0 else { return }
        let dx = quad.cx - x[i]
        let dy = quad.cy - y[i]
        var l = dx * dx + dy * dy
        let width = quad.x1 - quad.x0
        if !quad.isLeaf {
            if width * width / theta2 < l {
                if l < 1 { l = sqrt(l) }
                let f = charge * alpha * quad.mass / max(l, 0.01)
                vx[i] += dx * f
                vy[i] += dy * f
                return
            }
            for child in quad.children {
                if let child { apply(child, to: i) }
            }
            return
        }
        for j in quad.indices where j != i {
            var dx = x[j] - x[i]
            var dy = y[j] - y[i]
            if dx == 0 { dx = jiggle() }
            if dy == 0 { dy = jiggle() }
            var l = dx * dx + dy * dy
            if l < 1 { l = sqrt(l) }
            let f = charge * alpha / l
            vx[i] += dx * f
            vy[i] += dy * f
        }
    }

    private func jiggle() -> Double {
        Double.random(in: -1e-6...1e-6)
    }

    /// 所有節點的範圍（置中與縮放用）。
    var bounds: CGRect {
        guard let minX = x.min(), let maxX = x.max(), let minY = y.min(), let maxY = y.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func point(_ index: Int) -> CGPoint {
        CGPoint(x: x[index], y: y[index])
    }
}

/// Barnes-Hut 四分樹。
private final class Quad {
    let x0: Double
    let y0: Double
    let x1: Double
    let y1: Double
    var mass = 0.0
    var cx = 0.0
    var cy = 0.0
    var children: [Quad?] = [nil, nil, nil, nil]
    var indices: [Int] = []
    var isLeaf = true

    init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    static func build(x: [Double], y: [Double]) -> Quad {
        let minX = x.min() ?? 0, maxX = x.max() ?? 1, minY = y.min() ?? 0, maxY = y.max() ?? 1
        let size = max(maxX - minX, maxY - minY, 1)
        let root = Quad(x0: minX - 1, y0: minY - 1, x1: minX + size + 1, y1: minY + size + 1)
        for i in x.indices {
            root.insert(i, x: x, y: y, depth: 0)
        }
        root.accumulate(x: x, y: y)
        return root
    }

    private func insert(_ i: Int, x: [Double], y: [Double], depth: Int) {
        if isLeaf {
            if indices.isEmpty || depth >= 16 {
                indices.append(i)
                return
            }
            // 分成四塊，把原本的點往下放
            isLeaf = false
            let existing = indices
            indices = []
            for j in existing { child(for: j, x: x, y: y).insert(j, x: x, y: y, depth: depth + 1) }
        }
        child(for: i, x: x, y: y).insert(i, x: x, y: y, depth: depth + 1)
    }

    private func child(for i: Int, x: [Double], y: [Double]) -> Quad {
        let mx = (x0 + x1) / 2
        let my = (y0 + y1) / 2
        let right = x[i] >= mx
        let bottom = y[i] >= my
        let slot = (bottom ? 2 : 0) + (right ? 1 : 0)
        if let existing = children[slot] { return existing }
        let quad = Quad(x0: right ? mx : x0, y0: bottom ? my : y0, x1: right ? x1 : mx, y1: bottom ? y1 : my)
        children[slot] = quad
        return quad
    }

    private func accumulate(x: [Double], y: [Double]) {
        if isLeaf {
            mass = Double(indices.count)
            guard mass > 0 else { return }
            cx = indices.reduce(0) { $0 + x[$1] } / mass
            cy = indices.reduce(0) { $0 + y[$1] } / mass
            return
        }
        var sx = 0.0, sy = 0.0, m = 0.0
        for child in children {
            guard let child else { continue }
            child.accumulate(x: x, y: y)
            m += child.mass
            sx += child.cx * child.mass
            sy += child.cy * child.mass
        }
        mass = m
        if m > 0 {
            cx = sx / m
            cy = sy / m
        }
    }
}

/// 排好版的關聯圖（資料＋排版＋相鄰關係）。
@MainActor
final class GraphModel {
    let data: GraphData
    let layout: GraphLayout
    let neighbors: [Set<Int>]
    /// 名稱的優先順序（連結多的先放）
    let labelOrder: [Int]
    let colors: [Color]
    var needsFit: Bool

    init(data: GraphData, layout: GraphLayout, needsFit: Bool) {
        self.data = data
        self.layout = layout
        self.needsFit = needsFit
        var neighbors = Array(repeating: Set<Int>(), count: data.nodes.count)
        for (a, b) in data.edges {
            neighbors[a].insert(b)
            neighbors[b].insert(a)
        }
        self.neighbors = neighbors
        labelOrder = data.nodes.indices.sorted { data.nodes[$0].degree > data.nodes[$1].degree }
        let groupColors = Dictionary(uniqueKeysWithValues: data.groups.map { ($0.name, $0.color) })
        colors = data.nodes.map { groupColors[$0.group] ?? GraphPalette.other }
    }

    /// 節點半徑（圖上的單位）：連結越多越大。
    func radius(_ index: Int) -> CGFloat {
        min(2.4 + sqrt(CGFloat(data.nodes[index].degree)) * 1.15, 12)
    }

    /// 排版好的新模型；`previous` 的節點位置會沿用，切換篩選時不會整張重排。
    nonisolated static func layout(_ data: GraphData, previous: [String: CGPoint]) async -> GraphLayout {
        let groupNames = Array(Set(data.nodes.map(\.group))).sorted()
        let groupIndex = Dictionary(uniqueKeysWithValues: groupNames.enumerated().map { ($0.element, $0.offset) })
        var carried: [Int: CGPoint] = [:]
        for (index, node) in data.nodes.enumerated() {
            if let point = previous[node.path] { carried[index] = point }
        }
        let layout = GraphLayout(count: data.nodes.count, edges: data.edges, groups: data.nodes.map { groupIndex[$0.group] ?? 0 }, previous: carried)
        return await Task.detached(priority: .userInitiated) {
            layout.tick(carried.isEmpty ? 320 : 160)
            return layout
        }.value
    }

    var positionsByPath: [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: data.nodes.indices.map { (data.nodes[$0].path, layout.point($0)) })
    }
}

// MARK: - 畫面

/// 關聯圖：依資料夾上色的節點與連線。拖曳空白處移動、兩指縮放、拖曳節點；
/// 點一下選取（標出相鄰的筆記），點兩下開啟。名稱只放得下的才顯示，放大後顯示更多。
struct GraphView: View {
    let model: GraphModel
    @Binding var selected: Int?
    /// 要置中的節點（搜尋時）
    @Binding var centerRequest: Int?
    var onOpen: (String) -> Void

    @State private var frame = 0
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pinch: (scale: CGFloat, offset: CGSize)?
    @State private var panStart: CGSize?
    @State private var draggedNode: Int?
    @State private var hovered: Int?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let tick = frame
            Canvas { context, canvasSize in
                _ = tick
                draw(in: &context, size: canvasSize)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
            .simultaneousGesture(magnifyGesture(size: size))
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                if let index = hit(location, size: size) { onOpen(model.data.nodes[index].path) }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                selected = hit(location, size: size)
                frame &+= 1
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location): hovered = hit(location, size: size)
                case .ended: hovered = nil
                }
                frame &+= 1
            }
            .onAppear {
                if model.needsFit {
                    model.needsFit = false
                    fit(size: size, animated: false)
                }
            }
            .onChange(of: ObjectIdentifier(model)) {
                if model.needsFit {
                    model.needsFit = false
                    fit(size: size, animated: false)
                }
                frame &+= 1
            }
            .onChange(of: centerRequest) { _, index in
                guard let index else { return }
                center(on: index, size: size)
                centerRequest = nil
            }
            .task(id: ObjectIdentifier(model)) { await run() }
            .overlay(alignment: .bottom) {
                palette(size: size)
                    .padding(.bottom, 16)
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("關聯圖")
        .accessibilityValue("\(model.data.nodes.count) 則筆記，\(model.data.edges.count) 條連結")
    }

    // MARK: 動畫

    /// 拖曳節點時才需要繼續排版（一開始已經在背景排好）。
    private func run() async {
        while !Task.isCancelled {
            if model.layout.isSettled {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            model.layout.step()
            frame &+= 1
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func fit(size: CGSize, animated: Bool = true) {
        guard !model.data.nodes.isEmpty, size.width > 0 else { return }
        let bounds = model.layout.bounds.insetBy(dx: -30, dy: -30)
        let target = min(size.width / max(bounds.width, 1), (size.height - 80) / max(bounds.height, 1))
        let change = {
            scale = min(max(target, 0.12), 2.5)
            offset = CGSize(width: -bounds.midX * scale, height: -bounds.midY * scale - 20)
        }
        if animated { withAnimation(.smooth(duration: 0.45), change) } else { change() }
        frame &+= 1
    }

    private func center(on index: Int, size: CGSize) {
        let point = model.layout.point(index)
        withAnimation(.smooth(duration: 0.45)) {
            scale = max(scale, 1.1)
            offset = CGSize(width: -point.x * scale, height: -point.y * scale)
        }
        selected = index
        frame &+= 1
    }

    // MARK: 座標

    private func origin(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
    }

    private func toScreen(_ point: CGPoint, size: CGSize) -> CGPoint {
        let origin = origin(size)
        return CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    private func toGraph(_ point: CGPoint, size: CGSize) -> CGPoint {
        let origin = origin(size)
        return CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    private func screenRadius(_ index: Int) -> CGFloat {
        min(max(model.radius(index) * scale, 1.8), 22)
    }

    private func hit(_ location: CGPoint, size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for index in model.data.nodes.indices {
            let point = toScreen(model.layout.point(index), size: size)
            let distance = hypot(point.x - location.x, point.y - location.y)
            if distance <= screenRadius(index) + 12, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }

    // MARK: 手勢

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if draggedNode == nil && panStart == nil {
                    if let index = hit(value.startLocation, size: size) {
                        draggedNode = index
                        selected = index
                        model.layout.alphaTarget = 0.25
                        model.layout.reheat(0.25)
                    } else {
                        panStart = offset
                    }
                }
                if let index = draggedNode {
                    model.layout.pin(index, at: toGraph(value.location, size: size))
                } else if let start = panStart {
                    offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                frame &+= 1
            }
            .onEnded { _ in
                model.layout.pinned = nil
                model.layout.alphaTarget = 0
                draggedNode = nil
                panStart = nil
            }
    }

    /// 兩指縮放：以手指的位置為中心。
    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinch ?? (scale, offset)
                if pinch == nil { pinch = start }
                let newScale = min(max(start.scale * value.magnification, 0.12), 4)
                let anchor = CGPoint(x: value.startLocation.x - size.width / 2, y: value.startLocation.y - size.height / 2)
                let k = newScale / start.scale
                offset = CGSize(
                    width: anchor.x - (anchor.x - start.offset.width) * k,
                    height: anchor.y - (anchor.y - start.offset.height) * k
                )
                scale = newScale
                frame &+= 1
            }
            .onEnded { _ in pinch = nil }
    }

    private func zoom(by factor: CGFloat) {
        withAnimation(.smooth(duration: 0.3)) {
            let newScale = min(max(scale * factor, 0.12), 4)
            offset = CGSize(width: offset.width * newScale / scale, height: offset.height * newScale / scale)
            scale = newScale
        }
        frame &+= 1
    }

    // MARK: 繪製

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let count = model.data.nodes.count
        guard model.layout.count == count, count > 0 else { return }
        let highlight = hovered ?? draggedNode ?? selected
        let lit: Set<Int> = highlight.map { model.neighbors[$0].union([$0]) } ?? []
        let screen = (0..<count).map { toScreen(model.layout.point($0), size: size) }
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)

        // 連線：淡淡的細線；選取時只有相鄰的連線清楚（用節點的顏色）
        var plain = Path()
        var bright = Path()
        for (a, b) in model.data.edges {
            guard visible.contains(screen[a]) || visible.contains(screen[b]) else { continue }
            if let highlight, a == highlight || b == highlight {
                bright.move(to: screen[a])
                bright.addLine(to: screen[b])
            } else {
                plain.move(to: screen[a])
                plain.addLine(to: screen[b])
            }
        }
        let edgeOpacity = highlight == nil ? min(0.42, 0.18 + scale * 0.12) : 0.07
        context.stroke(plain, with: .color(DS.textTertiary.opacity(edgeOpacity)), lineWidth: max(0.4, min(scale * 0.7, 1)))
        if let highlight {
            context.stroke(bright, with: .color(model.colors[highlight].opacity(0.85)), lineWidth: 1.3)
        }

        // 節點：資料夾的顏色；選取時其他節點變淡
        for index in 0..<count where visible.contains(screen[index]) {
            let radius = screenRadius(index)
            let point = screen[index]
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            let dimmed = highlight != nil && !lit.contains(index)
            context.fill(Path(ellipseIn: rect), with: .color(model.colors[index].opacity(dimmed ? 0.18 : 1)))
            if index == highlight {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(DS.text.opacity(0.8)), lineWidth: 1.5)
            }
        }

        drawLabels(in: &context, screen: screen, highlight: highlight, lit: lit, visible: visible)
    }

    /// 名稱：重要的先放（選取的節點與相鄰的、連結多的），和已經放的重疊就不放。
    private func drawLabels(in context: inout GraphicsContext, screen: [CGPoint], highlight: Int?, lit: Set<Int>, visible: CGRect) {
        var candidates: [Int] = []
        if let highlight {
            candidates.append(highlight)
            candidates += model.neighbors[highlight].sorted { model.data.nodes[$0].degree > model.data.nodes[$1].degree }
        } else {
            candidates = model.labelOrder
        }
        let budget = highlight == nil ? Int(18 + 60 * min(scale, 1.5)) : 60
        var placed: [CGRect] = []
        var examined = 0
        for index in candidates {
            if placed.count >= budget || examined >= 320 { break }
            let point = screen[index]
            guard visible.contains(point) else { continue }
            let radius = screenRadius(index)
            let isPriority = index == highlight
            // 太小的點不放名稱（放大後就會出現）
            if highlight == nil && radius < 3.4 { continue }
            examined += 1
            var title = model.data.nodes[index].title
            if title.count > 18 { title = String(title.prefix(17)) + "…" }
            let text = Text(title)
                .font(.system(size: isPriority ? 13 : 11, weight: isPriority ? .semibold : .regular))
                .foregroundStyle(isPriority ? DS.text : DS.textSecondary)
            let resolved = context.resolve(text)
            let measured = resolved.measure(in: CGSize(width: 260, height: 40))
            let rect = CGRect(x: point.x - measured.width / 2 - 4, y: point.y + radius + 3, width: measured.width + 8, height: measured.height + 2)
            if placed.contains(where: { $0.intersects(rect) }) { continue }
            placed.append(rect)
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(DS.pane.opacity(0.82)))
            context.draw(resolved, in: rect.insetBy(dx: 4, dy: 1))
        }
    }

    // MARK: 工具列

    private func palette(size: CGSize) -> some View {
        FloatingPalette {
            PaletteButton(title: "縮小", systemImage: "minus", size: 36) { zoom(by: 1 / 1.35) }
            PaletteButton(title: "放大", systemImage: "plus", size: 36) { zoom(by: 1.35) }
            PaletteButton(title: "整張圖置中", systemImage: "arrow.up.left.and.arrow.down.right", size: 36) { fit(size: size) }
            PaletteButton(title: "重新排列", systemImage: "arrow.clockwise", pastel: .lavender, size: 36) {
                model.layout.reheat(0.8)
                frame &+= 1
            }
        }
    }
}

/// 關聯圖分頁：整個 vault。上方可以搜尋筆記、依資料夾隱藏、顯示孤立筆記與 AI 對話；選取的筆記在下方顯示資訊卡。
struct GraphPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = NotesStore.shared
    @State private var options = GraphOptions()
    @State private var model: GraphModel?
    @State private var isLaying = false
    @State private var selected: Int?
    @State private var centerRequest: Int?
    @State private var query = ""

    private var isCompact: Bool { sizeClass == .compact }

    private var dataKey: String {
        "\(store.notes.count)|\(store.notes.reduce(0) { $0 + $1.links.count })|\(options.showOrphans)|\(options.showHistory)|\(options.hiddenGroups.sorted().joined(separator: ","))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ZStack {
                if let model {
                    GraphView(model: model, selected: $selected, centerRequest: $centerRequest) { path in
                        workspace.openNote(path)
                    }
                    if model.data.nodes.isEmpty {
                        EmptyStateView(title: "沒有可以顯示的筆記")
                    }
                }
                if isLaying {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("排列中…")
                            .font(.footnote)
                            .foregroundStyle(DS.textSecondary)
                    }
                    .padding(16)
                    .background(DS.card.opacity(0.92), in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if let model, let selected, model.data.nodes.indices.contains(selected) {
                    infoCard(model: model, index: selected)
                        .padding(.horizontal, isCompact ? 12 : 24)
                        .padding(.bottom, 76)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                if !query.isEmpty, let model {
                    searchResults(model: model)
                        .padding(.horizontal, isCompact ? 16 : 24)
                }
            }
        }
        .background(DS.pane)
        .task(id: dataKey) { await rebuild() }
        .animation(.smooth(duration: 0.25), value: selected)
    }

    // MARK: 上方

    private var header: some View {
        PageToolbar(
            "關聯圖",
            subtitle: model.map { "\($0.data.nodes.count) 則筆記 · \($0.data.edges.count) 條連結" },
            query: $query,
            searchPlaceholder: "找一則筆記"
        ) {
        } chips: {
            ToggleChip(title: "孤立筆記", isOn: $options.showOrphans)
            ToggleChip(title: "AI 對話", isOn: $options.showHistory)
            if let groups = model?.data.groups, !groups.isEmpty {
                Rectangle()
                    .fill(DS.hairline)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 2)
                ForEach(groups.prefix(12)) { group in
                    groupChip(group)
                }
            }
        }
    }

    private func groupChip(_ group: GraphData.Group) -> some View {
        let hidden = options.hiddenGroups.contains(group.name)
        return Button {
            if hidden {
                options.hiddenGroups.remove(group.name)
            } else {
                options.hiddenGroups.insert(group.name)
            }
            selected = nil
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(group.color)
                    .frame(width: 8, height: 8)
                Text(group.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DS.text)
                    .strikethrough(hidden)
                    .lineLimit(1)
                Text("\(group.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DS.control, in: Capsule(style: .continuous))
            .opacity(hidden ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title)，\(group.count) 則筆記，\(hidden ? "已隱藏" : "顯示中")")
    }

    private func searchResults(model: GraphModel) -> some View {
        let matches = model.data.nodes.indices
            .filter { model.data.nodes[$0].title.localizedCaseInsensitiveContains(query) }
            .sorted { model.data.nodes[$0].degree > model.data.nodes[$1].degree }
            .prefix(6)
        return VStack(alignment: .leading, spacing: 0) {
            if matches.isEmpty {
                Text("沒有符合的筆記")
                    .font(.subheadline)
                    .foregroundStyle(DS.textTertiary)
                    .padding(12)
            }
            ForEach(Array(matches), id: \.self) { index in
                Button {
                    centerRequest = index
                    query = ""
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(model.colors[index]).frame(width: 8, height: 8)
                        Text(model.data.nodes[index].title)
                            .font(.subheadline)
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        Spacer()
                        Text("\(model.data.nodes[index].degree)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .card(padding: 0)
        .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .trailing)
    }

    private func infoCard(model: GraphModel, index: Int) -> some View {
        let node = model.data.nodes[index]
        return HStack(spacing: 12) {
            Circle()
                .fill(model.colors[index])
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.headline)
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text("\(node.group.isEmpty ? "最上層" : node.group) · \(node.degree) 個連結")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("開啟") { workspace.openNote(node.path) }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            Button {
                selected = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(CircleIconButtonStyle(size: 30))
            .accessibilityLabel("取消選取")
        }
        .frame(maxWidth: 520)
        .card(padding: 14)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .frame(maxWidth: .infinity)
    }

    // MARK: 排版

    private func rebuild() async {
        let data = GraphData.build(store: store, options: options)
        let previous = model?.positionsByPath ?? [:]
        let selectedPath = selected.flatMap { model?.data.nodes.indices.contains($0) == true ? model?.data.nodes[$0].path : nil }
        isLaying = model == nil || previous.isEmpty
        let layout = await GraphModel.layout(data, previous: previous)
        guard !Task.isCancelled else { return }
        model = GraphModel(data: data, layout: layout, needsFit: previous.isEmpty)
        selected = selectedPath.flatMap { path in data.nodes.firstIndex { $0.path == path } }
        isLaying = false
    }
}
