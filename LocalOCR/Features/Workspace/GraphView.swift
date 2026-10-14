import SwiftUI

/// 關聯圖的資料：節點是筆記，連線是 [[連結]]（不分方向）。
struct GraphData {
    struct Node {
        let path: String
        let title: String
        let degree: Int
        let color: Color
    }

    var nodes: [Node] = []
    var edges: [(Int, Int)] = []

    /// focus 為 nil 時是整個 vault（最多 `limit` 個，連結多的優先）；否則是 focus 周圍 `depth` 層內的筆記。
    @MainActor
    static func build(store: NotesStore, focus: String?, depth: Int = 2, limit: Int = 260) -> GraphData {
        var adjacency: [String: Set<String>] = [:]
        for note in store.notes {
            for target in store.outgoingLinks(of: note) {
                adjacency[note.path, default: []].insert(target)
                adjacency[target, default: []].insert(note.path)
            }
        }
        var selected: [String]
        if let focus {
            selected = [focus]
            var seen: Set<String> = [focus]
            var frontier = [focus]
            for _ in 0..<depth {
                var next: [String] = []
                for path in frontier {
                    for neighbor in (adjacency[path] ?? []).sorted() where seen.insert(neighbor).inserted {
                        next.append(neighbor)
                    }
                }
                selected += next
                frontier = next
                if selected.count >= limit { break }
            }
            selected = Array(selected.prefix(limit))
        } else {
            selected = store.notes
                .sorted { (adjacency[$0.path]?.count ?? 0, $0.mtime) > (adjacency[$1.path]?.count ?? 0, $1.mtime) }
                .prefix(limit)
                .map(\.path)
        }
        let index = Dictionary(uniqueKeysWithValues: selected.enumerated().map { ($0.element, $0.offset) })
        var edges: [(Int, Int)] = []
        for (path, a) in index {
            for neighbor in adjacency[path] ?? [] {
                if let b = index[neighbor], a < b { edges.append((a, b)) }
            }
        }
        let nodes = selected.map { path in
            Node(
                path: path,
                title: WorkspaceTab.note(path).title,
                degree: adjacency[path]?.count ?? 0,
                color: Midnight.hue(for: (path as NSString).deletingLastPathComponent)
            )
        }
        return GraphData(nodes: nodes, edges: edges)
    }
}

/// 力導向排版：節點互斥、連線像彈簧、整體往中心收；熱度（alpha）逐漸降低直到靜止。
@MainActor
final class GraphSimulation {
    private(set) var positions: [CGPoint]
    private var velocities: [CGVector]
    private let edges: [(Int, Int)]
    private(set) var alpha: CGFloat = 1
    /// 正在拖曳的節點（固定在手指位置）。
    var pinned: Int?

    var isSettled: Bool { alpha < 0.004 && pinned == nil }

    init(count: Int, edges: [(Int, Int)], previous: [Int: CGPoint] = [:]) {
        self.edges = edges
        // 葵花籽螺旋排列，起始位置分散又不規則
        positions = (0..<count).map { index in
            if let point = previous[index] { return point }
            let angle = Double(index) * 2.399963
            let radius = 14 * sqrt(Double(index) + 0.5)
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        velocities = Array(repeating: .zero, count: count)
        if !previous.isEmpty { alpha = 0.5 }
    }

    func reheat(_ value: CGFloat = 0.5) {
        alpha = max(alpha, value)
    }

    func move(_ index: Int, to point: CGPoint) {
        guard positions.indices.contains(index) else { return }
        positions[index] = point
        velocities[index] = .zero
    }

    func step() {
        let count = positions.count
        guard count > 0, alpha >= 0.004 || pinned != nil else { return }
        var forces = Array(repeating: CGVector.zero, count: count)
        let repulsion: CGFloat = 1100
        for i in 0..<count {
            for j in (i + 1)..<count {
                var dx = positions[i].x - positions[j].x
                var dy = positions[i].y - positions[j].y
                var distanceSquared = dx * dx + dy * dy
                if distanceSquared < 0.01 {
                    dx = CGFloat.random(in: -1...1)
                    dy = CGFloat.random(in: -1...1)
                    distanceSquared = 1
                }
                let distance = sqrt(distanceSquared)
                let force = repulsion / distanceSquared
                let fx = dx / distance * force
                let fy = dy / distance * force
                forces[i].dx += fx
                forces[i].dy += fy
                forces[j].dx -= fx
                forces[j].dy -= fy
            }
        }
        for (a, b) in edges {
            let dx = positions[b].x - positions[a].x
            let dy = positions[b].y - positions[a].y
            let distance = max(sqrt(dx * dx + dy * dy), 0.1)
            let force = (distance - 64) * 0.045
            let fx = dx / distance * force
            let fy = dy / distance * force
            forces[a].dx += fx
            forces[a].dy += fy
            forces[b].dx -= fx
            forces[b].dy -= fy
        }
        for i in 0..<count where i != pinned {
            forces[i].dx -= positions[i].x * 0.014
            forces[i].dy -= positions[i].y * 0.014
            var vx = (velocities[i].dx + forces[i].dx * alpha) * 0.62
            var vy = (velocities[i].dy + forces[i].dy * alpha) * 0.62
            let speed = sqrt(vx * vx + vy * vy)
            if speed > 36 {
                vx *= 36 / speed
                vy *= 36 / speed
            }
            velocities[i] = CGVector(dx: vx, dy: vy)
            positions[i].x += vx
            positions[i].y += vy
        }
        alpha *= 0.986
    }

    /// 所有節點的範圍（置中與縮放用）。
    var bounds: CGRect {
        guard let first = positions.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for point in positions { rect = rect.union(CGRect(origin: point, size: .zero)) }
        return rect
    }
}

/// 排好版的關聯圖（資料＋模擬＋相鄰關係）。
@MainActor
final class GraphModel {
    let data: GraphData
    let simulation: GraphSimulation
    let neighbors: [Set<Int>]
    let focusIndex: Int?
    /// 一直顯示名稱的節點（連結最多的幾個）。
    let labeled: Set<Int>
    let key: String

    init(data: GraphData, focus: String?, key: String, previous: GraphModel?) {
        self.data = data
        self.key = key
        var neighbors = Array(repeating: Set<Int>(), count: data.nodes.count)
        for (a, b) in data.edges {
            neighbors[a].insert(b)
            neighbors[b].insert(a)
        }
        self.neighbors = neighbors
        focusIndex = focus.flatMap { path in data.nodes.firstIndex { $0.path == path } }
        labeled = Set(data.nodes.indices.sorted { data.nodes[$0].degree > data.nodes[$1].degree }.prefix(14))
        var carried: [Int: CGPoint] = [:]
        if let previous {
            let old = Dictionary(uniqueKeysWithValues: previous.data.nodes.enumerated().map { ($0.element.path, $0.offset) })
            for (index, node) in data.nodes.enumerated() {
                if let oldIndex = old[node.path], previous.simulation.positions.indices.contains(oldIndex) {
                    carried[index] = previous.simulation.positions[oldIndex]
                }
            }
        }
        simulation = GraphSimulation(count: data.nodes.count, edges: data.edges, previous: carried)
    }

    func radius(_ index: Int) -> CGFloat {
        let degree = CGFloat(data.nodes[index].degree)
        return min(4 + sqrt(degree) * 2.4, 15) + (index == focusIndex ? 3 : 0)
    }
}

/// 關聯圖：發光的節點與連線。拖曳空白處移動、兩指縮放、拖曳節點、點一下開啟筆記；滑鼠移上去會標出相鄰的筆記。
struct GraphView: View {
    let focus: String?
    var showsControls = false

    @Environment(Workspace.self) private var workspace
    @State private var store = NotesStore.shared
    @State private var model: GraphModel?
    @State private var frame = 0
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var draggedNode: Int?
    @State private var hovered: Int?

    private var dataKey: String {
        "\(focus ?? "*")|\(store.notes.count)|\(store.notes.reduce(0) { $0 + $1.links.count })"
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let tick = frame
            ZStack {
                DotGrid(spacing: 26, opacity: 0.07)
                if let model {
                    Canvas { context, canvasSize in
                        _ = tick
                        draw(model, in: &context, size: canvasSize)
                    }
                    if model.data.nodes.isEmpty || (focus == nil && model.data.edges.isEmpty && model.data.nodes.count < 2) {
                        Text(focus == nil ? "筆記之間還沒有連結。在筆記中寫 [[筆記名稱]] 就會出現在這裡。" : "這則筆記還沒有連結。")
                            .font(.footnote)
                            .foregroundStyle(Midnight.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(24)
                    }
                }
                if showsControls {
                    controls(size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(max(baseScale * value.magnification, 0.25), 3.5) }
                    .onEnded { _ in baseScale = scale }
            )
            .onTapGesture(coordinateSpace: .local) { location in
                guard let model, let index = hit(location, size: size, in: model) else { return }
                let path = model.data.nodes[index].path
                if path != focus { workspace.openNote(path) }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    hovered = model.flatMap { hit(location, size: size, in: $0) }
                case .ended:
                    hovered = nil
                }
                frame &+= 1
            }
            .task(id: dataKey) { rebuild(size: size) }
            .task(id: model.map { ObjectIdentifier($0) }) { await run() }
        }
        .clipShape(RoundedRectangle(cornerRadius: Midnight.radiusM, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(focus == nil ? "關聯圖" : "局部關聯圖")
        .accessibilityValue("\(model?.data.nodes.count ?? 0) 則筆記，\(model?.data.edges.count ?? 0) 條連結")
    }

    // MARK: - 排版與動畫

    private func rebuild(size: CGSize) {
        let data = GraphData.build(store: store, focus: focus, depth: 2, limit: focus == nil ? 260 : 80)
        let isFirst = model == nil
        model = GraphModel(data: data, focus: focus, key: dataKey, previous: model)
        if isFirst {
            // 依節點數估計縮放，讓整張圖大致放得進畫面
            let spread = 46 * sqrt(CGFloat(max(data.nodes.count, 1)))
            scale = min(1.2, max(0.3, min(size.width, size.height) / max(spread * 2.2, 1)))
            baseScale = scale
        }
    }

    /// 模擬一直跑到靜止；拖曳節點時會重新加熱。
    private func run() async {
        guard let model else { return }
        while !Task.isCancelled {
            if model.simulation.isSettled {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            model.simulation.step()
            frame &+= 1
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func fit(size: CGSize) {
        guard let model, !model.data.nodes.isEmpty else { return }
        let bounds = model.simulation.bounds.insetBy(dx: -40, dy: -40)
        let target = min(size.width / max(bounds.width, 1), size.height / max(bounds.height, 1))
        withAnimation(.smooth(duration: 0.5)) {
            scale = min(max(target, 0.25), 2.5)
            baseScale = scale
            offset = CGSize(width: -bounds.midX * scale, height: -bounds.midY * scale)
        }
        frame &+= 1
    }

    // MARK: - 座標

    private func center(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
    }

    private func toScreen(_ point: CGPoint, size: CGSize) -> CGPoint {
        let origin = center(size)
        return CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    private func toGraph(_ point: CGPoint, size: CGSize) -> CGPoint {
        let origin = center(size)
        return CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    private func hit(_ location: CGPoint, size: CGSize, in model: GraphModel) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for index in model.data.nodes.indices {
            let point = toScreen(model.simulation.positions[index], size: size)
            let distance = hypot(point.x - location.x, point.y - location.y)
            let reach = model.radius(index) * scale + 10
            if distance <= reach, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard let model else { return }
                if draggedNode == nil && panStart == nil {
                    if let index = hit(value.startLocation, size: size, in: model) {
                        draggedNode = index
                        model.simulation.pinned = index
                    } else {
                        panStart = offset
                    }
                }
                if let index = draggedNode {
                    model.simulation.move(index, to: toGraph(value.location, size: size))
                    model.simulation.reheat(0.3)
                } else if let start = panStart {
                    offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                frame &+= 1
            }
            .onEnded { _ in
                model?.simulation.pinned = nil
                draggedNode = nil
                panStart = nil
            }
    }

    // MARK: - 繪製

    private func draw(_ model: GraphModel, in context: inout GraphicsContext, size: CGSize) {
        let positions = model.simulation.positions
        guard positions.count == model.data.nodes.count else { return }
        let highlight = hovered ?? draggedNode ?? model.focusIndex
        let lit: Set<Int> = highlight.map { model.neighbors[$0].union([$0]) } ?? []
        let screen = positions.map { toScreen($0, size: size) }

        // 連線：一般的淡淡一條，與目前節點相連的用紫青漸層
        var plain = Path()
        var bright = Path()
        for (a, b) in model.data.edges {
            if let highlight, a == highlight || b == highlight {
                bright.move(to: screen[a])
                bright.addLine(to: screen[b])
            } else {
                plain.move(to: screen[a])
                plain.addLine(to: screen[b])
            }
        }
        context.stroke(plain, with: .color(Midnight.text.opacity(highlight == nil ? 0.16 : 0.07)), lineWidth: 0.8)
        context.stroke(
            bright,
            with: .linearGradient(Gradient(colors: [Midnight.violet, Midnight.cyan]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)),
            lineWidth: 1.6
        )

        // 光暈
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 9))
            for index in lit.isEmpty ? Set(model.labeled.prefix(6)) : lit {
                let radius = model.radius(index) * scale * 2.4
                let point = screen[index]
                layer.fill(
                    Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color((index == highlight ? Midnight.violet : model.data.nodes[index].color).opacity(0.55))
                )
            }
        }

        // 節點
        for (index, node) in model.data.nodes.enumerated() {
            let radius = model.radius(index) * scale
            let point = screen[index]
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            let dimmed = highlight != nil && !lit.contains(index)
            if index == highlight || index == model.focusIndex {
                context.fill(Path(ellipseIn: rect), with: .linearGradient(Gradient(colors: [Midnight.violet, Midnight.cyan]), startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5)), with: .color(Color.white.opacity(0.5)), lineWidth: 1)
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(node.color.opacity(dimmed ? 0.22 : 0.92)))
            }
        }

        // 名稱：目前節點與相鄰的、連結最多的幾個；放大後全部顯示
        for (index, node) in model.data.nodes.enumerated() {
            let show = lit.contains(index) || (highlight == nil && model.labeled.contains(index) && scale > 0.55) || scale > 1.7
            guard show else { continue }
            let dimmed = highlight != nil && !lit.contains(index)
            let point = screen[index]
            let label = Text(node.title)
                .font(.system(size: index == highlight ? 12 : 10, weight: index == highlight ? .semibold : .medium, design: .rounded))
                .foregroundStyle(index == highlight ? Midnight.text : Midnight.textSecondary.opacity(dimmed ? 0.35 : 1))
            context.draw(label, at: CGPoint(x: point.x, y: point.y + model.radius(index) * scale + 5), anchor: .top)
        }
    }

    private func controls(size: CGSize) -> some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 2) {
                    Button {
                        withAnimation(.smooth) {
                            scale = min(scale * 1.3, 3.5)
                            baseScale = scale
                        }
                        frame &+= 1
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .accessibilityLabel("放大")
                    Button {
                        withAnimation(.smooth) {
                            scale = max(scale / 1.3, 0.25)
                            baseScale = scale
                        }
                        frame &+= 1
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .accessibilityLabel("縮小")
                    Button {
                        fit(size: size)
                    } label: {
                        Image(systemName: "scope")
                    }
                    .accessibilityLabel("整張圖置中")
                    Button {
                        model?.simulation.reheat(1)
                    } label: {
                        Image(systemName: "wind")
                    }
                    .accessibilityLabel("重新排列")
                }
                .buttonStyle(GlassIconButtonStyle(size: 36))
                .padding(4)
                .glass(cornerRadius: 14, shadow: false)
            }
            Spacer()
        }
        .padding(16)
    }
}

/// 關聯圖分頁：整個 vault。
struct GraphPage: View {
    @State private var store = NotesStore.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            GraphView(focus: nil, showsControls: true)
                .padding(10)
            VStack(alignment: .leading, spacing: 6) {
                Text("關聯圖")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .gradientForeground()
                let links = store.notes.reduce(0) { $0 + $1.links.count }
                Text("\(store.notes.count) 則筆記 · \(links) 個連結")
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(Midnight.textSecondary)
                Text("拖曳移動 · 兩指縮放 · 點一下開啟")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Midnight.textTertiary)
            }
            .padding(28)
            .allowsHitTesting(false)
        }
    }
}
