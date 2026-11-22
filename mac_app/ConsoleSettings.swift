import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConsoleItem: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let target: String
    let shell: String
    var subscriptionScript: String = ""
    var typeName: String { kind == "subscription" ? "订阅更新" : kind == "app" ? "应用" : kind == "script" ? "Shell 脚本" : "Shell 命令" }
    var typeColor: Color {
        switch kind {
        case "app": return .blue
        case "script": return .purple
        case "command": return .orange
        case "subscription": return .green
        default: return .gray
        }
    }
}

private struct ConsoleDragSession {
    var plan: ConsoleReorderPlan
    let grabOffset: CGFloat
    var pointer: CGPoint
    var offset: CGFloat
}

private struct ConsoleFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

@MainActor struct ConsoleSettings: View {
    @ObservedObject var model: ControlModel
    @ViewState private var editor = false
    @ViewState private var editing: ConsoleItem?
    @ViewState private var deleting: ConsoleItem?
    @ViewState private var sorting = false
    @ViewState private var geometry: [String: CGRect] = [:]
    @ViewState private var drag: ConsoleDragSession?
    @ViewState private var settling = false
    @ViewState private var cancelledUntilRelease = false
    @ViewState private var icons: [String: NSImage] = [:]
    @GestureState private var gestureActive = false
    private let spring = Animation.interactiveSpring(response: 0.26, dampingFraction: 0.88)

    private func cacheIcons() {
        let paths = Set(model.consoleItems.filter { $0.kind == "app" }.map(\.target))
        guard paths != Set(icons.keys) else { return }
        // 拖动逐帧重算布局时复用图标，避免同步读取应用资源。
        icons = Dictionary(uniqueKeysWithValues: paths.map { ($0, icons[$0] ?? NSWorkspace.shared.icon(forFile: $0)) })
    }
    private func move(_ id: String, to target: ConsoleItem) {
        guard !sorting, id != target.id else { return }
        let original = model.consoleItems
        let slots = original.indices.filter { original[$0].kind == target.kind }
        var items = slots.map { original[$0] }
        guard let source = items.firstIndex(where: { $0.id == id }),
              let destination = items.firstIndex(where: { $0.id == target.id }) else { return }
        items.insert(items.remove(at: source), at: destination)
        var preview = original
        for (slot, item) in zip(slots, items) { preview[slot] = item }
        sorting = true
        model.consoleItems = preview
        Task {
            do {
                _ = try await Task.detached { try ControlModel.request(["action": "console-move", "id": id, "targetID": target.id]) }.value
                model.failed = false; model.message = "顺序已保存"
            } catch {
                if model.consoleItems == preview { withAnimation(spring) { model.consoleItems = original } }
                model.failed = true; model.message = (error as NSError).domain
            }
            sorting = false
        }
    }
    private func dragCoordinate(_ pointer: CGPoint, plan: ConsoleReorderPlan) -> CGFloat {
        let content = geometry["content"] ?? .zero
        if plan.horizontal {
            // 横向列表滚动会移动槽位，跟手位置须扣除这段滚动增量。
            let shift = (geometry[plan.ids[0]]?.minX ?? plan.frames[0].minY) - plan.frames[0].minY
            return pointer.x - content.minX - shift
        }
        return pointer.y - content.minY
    }
    private func updateDrag(_ pointer: CGPoint) {
        guard var session = drag, !settling else { return }
        session.pointer = pointer
        let center = dragCoordinate(pointer, plan: session.plan) + session.grabOffset
        session.offset = center - session.plan.frames[session.plan.source].midY
        session.plan.update(centerY: center)
        drag = session
    }
    private func finishDrag(save: Bool) {
        guard var session = drag, !settling else { return }
        if !save { session.plan.destination = session.plan.source }
        session.offset = session.plan.landingOffset
        settling = true
        drag = session
        Task {
            // shortcut: macOS 13 缺少动画完成回调，按落位时长延迟交接；提高最低系统版本后改用完成回调。
            try? await Task.sleep(nanoseconds: 260_000_000)
            // 卡片落稳后再交换真实布局与位移，两个位置完全重合，避免松手时重建拖放快照。
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if save, let targetID = session.plan.targetID,
                   let target = model.consoleItems.first(where: { $0.id == targetID }) {
                    move(session.plan.sourceID, to: target)
                }
                drag = nil; settling = false
            }
        }
    }
    private func reorderGesture(_ item: ConsoleItem, items: [ConsoleItem]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("consoleViewport"))
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !model.busy, !sorting, !settling, !cancelledUntilRelease else { return }
                if drag == nil {
                    guard let plan = ConsoleReorderPlan(sourceID: item.id, ids: items.map(\.id), frames: geometry, horizontal: item.kind == "subscription") else { return }
                    let grab = plan.frames[plan.source].midY - dragCoordinate(value.startLocation, plan: plan)
                    drag = ConsoleDragSession(plan: plan, grabOffset: grab, pointer: value.location, offset: 0)
                }
                guard drag?.plan.sourceID == item.id else { return }
                updateDrag(value.location)
            }
            .onEnded { value in
                guard let session = drag, session.plan.sourceID == item.id, !settling else { return }
                updateDrag(value.location)
                let center = dragCoordinate(value.location, plan: session.plan) + session.grabOffset
                let row = geometry[item.id] ?? .zero
                let contentY = value.location.y - (geometry["content"]?.minY ?? 0)
                let withinRow = !session.plan.horizontal || (row.minY...row.maxY).contains(contentY)
                let inside = (geometry["viewport"]?.contains(value.location) ?? false) &&
                    center >= session.plan.frames.first!.minY && center <= session.plan.frames.last!.maxY && withinRow
                finishDrag(save: inside && !cancelledUntilRelease)
            }
    }
    private var scrollDirection: Int {
        guard let session = drag, !session.plan.horizontal, !settling, let viewport = geometry["viewport"] else { return 0 }
        let top = geometry["content"]?.minY ?? 0
        if session.pointer.y < 36, session.plan.frames.first!.minY + top < 0 { return -1 }
        if session.pointer.y > viewport.height - 36, session.plan.frames.last!.maxY + top > viewport.height { return 1 }
        return 0
    }
    private func autoscroll(_ proxy: ScrollViewProxy, direction: Int) async {
        while !Task.isCancelled, direction != 0, scrollDirection == direction, let session = drag {
            let top = geometry["content"]?.minY ?? 0, height = geometry["viewport"]?.height ?? 0
            let indices = Array(session.plan.frames.indices)
            let next = direction > 0
                ? indices.first { session.plan.frames[$0].maxY + top > height + 1 }
                : indices.reversed().first { session.plan.frames[$0].minY + top < -1 }
            guard let next else { return }
            withAnimation(.linear(duration: 0.15)) {
                proxy.scrollTo(session.plan.ids[next], anchor: direction > 0 ? .bottom : .top)
            }
            do { try await Task.sleep(nanoseconds: 160_000_000) } catch { return }
        }
    }
    private func typeBadge(_ item: ConsoleItem) -> some View {
        Text(item.typeName).font(.caption)
            .foregroundStyle(item.kind == "app" ? Color.blue : Color.primary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(item.typeColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
    private func dragHandle(_ item: ConsoleItem, items: [ConsoleItem]) -> some View {
        let horizontal = item.kind == "subscription"
        return Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary).frame(width: 20, height: horizontal ? 24 : 40)
            .contentShape(Rectangle()).help("拖动以调整同组顺序")
            .accessibilityLabel("拖动排序 " + item.name)
            .accessibilityAction(named: Text(horizontal ? "左移" : "上移")) {
                if let index = items.firstIndex(where: { $0.id == item.id }), index > 0 {
                    withAnimation(spring) { move(item.id, to: items[index - 1]) }
                }
            }
            .accessibilityAction(named: Text(horizontal ? "右移" : "下移")) {
                if let index = items.firstIndex(where: { $0.id == item.id }), index + 1 < items.count {
                    withAnimation(spring) { move(item.id, to: items[index + 1]) }
                }
            }
            .highPriorityGesture(reorderGesture(item, items: items))
    }
    @ViewBuilder private func itemActions(_ item: ConsoleItem) -> some View {
        Button("编辑") { if !sorting && drag == nil { editing = item } }
        Button("删除", role: .destructive) { if !sorting && drag == nil { deleting = item } }.foregroundStyle(.red)
    }
    private func card(_ item: ConsoleItem, items: [ConsoleItem]) -> some View {
        GroupBox {
            if item.kind == "subscription" {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        dragHandle(item, items: items)
                        Spacer(minLength: 0)
                        Image(systemName: "terminal").foregroundStyle(Color.accentColor)
                    }
                    Text(item.name).font(.headline).lineLimit(1).help(item.name)
                    HStack(spacing: 6) {
                        typeBadge(item)
                        Spacer(minLength: 0)
                        Text(item.target).font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1).help(item.target)
                    }
                    HStack(spacing: 8) { itemActions(item) }.controlSize(.small)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    dragHandle(item, items: items)
                    if item.kind == "app", let image = icons[item.target] {
                        Image(nsImage: image).resizable().frame(width: 40, height: 40)
                    } else {
                        Image(systemName: item.kind == "app" ? "app" : item.kind == "script" ? "doc.text" : "terminal")
                            .font(.title2).foregroundStyle(Color.accentColor).frame(width: 40, height: 40)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.headline).lineLimit(1)
                        typeBadge(item)
                    }.layoutPriority(1)
                    // 长路径保持单行，悬停可看完整值，避免重新撑高卡片。
                    Text(item.target).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(item.target)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    itemActions(item)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func row(_ item: ConsoleItem, items: [ConsoleItem]) -> some View {
        let source = drag?.plan.sourceID == item.id
        let lifted = source && !settling
        let offset = source ? (drag?.offset ?? 0) : (drag?.plan.displacement(for: item.id) ?? 0)
        return ZStack {
            card(item, items: items)
                .scaleEffect(lifted ? 1.01 : 1)
                .shadow(color: .black.opacity(lifted ? 0.16 : 0), radius: lifted ? 10 : 0, y: lifted ? 4 : 0)
                .offset(x: item.kind == "subscription" ? offset : 0, y: item.kind == "subscription" ? 0 : offset)
                .animation(source ? (settling ? .easeOut(duration: 0.18) : nil) : spring, value: offset)
                .animation(.easeOut(duration: 0.14), value: lifted)
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ConsoleFrames.self, value: [item.id: proxy.frame(in: .named("consoleRows"))])
        })
        .frame(maxWidth: .infinity).zIndex(source ? 1 : 0).id(item.id)
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("配置后，已配对网页可运行这些项目。拖动左侧手柄可在同组内排序。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("添加项目") { if !sorting && drag == nil { editor = true } }.buttonStyle(.borderedProminent)
                    }
                    if model.consoleItems.isEmpty {
                        Text("暂无快捷项目，添加一个应用或脚本开始使用。")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach(["app", "script", "command", "subscription"], id: \.self) { kind in
                        let items = model.consoleItems.filter { $0.kind == kind }
                        if !items.isEmpty {
                            Text(kind == "subscription" ? "订阅更新" : kind == "app" ? "应用" : kind == "script" ? "脚本" : "命令").font(.headline)
                            if kind == "subscription" {
                                ScrollView(.horizontal) {
                                    HStack(alignment: .top, spacing: 18) {
                                        ForEach(items) { item in row(item, items: items).frame(width: 144) }
                                    }.padding(.vertical, 6)
                                }.fixedSize(horizontal: false, vertical: true)
                            } else {
                                ForEach(items) { item in row(item, items: items) }
                            }
                        }
                    }
                    Button("刷新列表") { if !sorting && drag == nil { Task { await model.loadConsole() } } }
                    Text("应用在这台 Mac 上打开；脚本后台执行，以脚本所在目录为工作目录，Shell 命令以用户主目录为工作目录。一次运行一个项目，最多等待 5 分钟；不支持终端交互输入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6).coordinateSpace(name: "consoleRows")
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ConsoleFrames.self, value: ["content": geometry.frame(in: .named("consoleViewport"))])
                })
            }
            .coordinateSpace(name: "consoleViewport")
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ConsoleFrames.self, value: ["viewport": CGRect(origin: .zero, size: geometry.size)])
            })
            .onPreferenceChange(ConsoleFrames.self) { frames in
                geometry = frames
                if let session = drag, !settling { updateDrag(session.pointer) }
            }
            .task(id: scrollDirection) { await autoscroll(proxy, direction: scrollDirection) }
        }
        .task { await model.loadConsole(); cacheIcons() }
        .onChange(of: model.consoleItems) { _ in cacheIcons() }
        .onChange(of: gestureActive) { active in
            if !active {
                cancelledUntilRelease = false
                if drag != nil && !settling { finishDrag(save: false) }
            }
        }
        .onExitCommand {
            if drag != nil && !settling { cancelledUntilRelease = true; finishDrag(save: false) }
        }
        .onDisappear { if !settling { drag = nil } }
        .sheet(isPresented: $editor) { ConsoleItemEditor(model: model, item: nil) }
        .sheet(item: $editing) { item in ConsoleItemEditor(model: model, item: item) }
        .alert("删除快捷项目？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                guard let item = deleting else { return }; deleting = nil
                Task {
                    await model.perform(["action": "console-delete", "id": item.id], success: "快捷项目已删除")
                    if !model.failed { await model.loadConsole() }
                }
            }
        } message: { Text("只移除控制台入口，不删除应用或脚本文件；已经启动的任务会继续运行。") }
    }
}

struct ConsoleItemEditor: View {
    @ObservedObject var model: ControlModel
    let item: ConsoleItem?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name: String
    @ViewState private var kind: String
    @ViewState private var target: String
    @ViewState private var shell: String
    @ViewState private var subscriptionScript: String
    @ViewState private var allSubscriptions: Bool
    init(model: ControlModel, item: ConsoleItem?) {
        self.model = model; self.item = item
        _name = ViewState(initialValue: item?.name ?? "")
        _kind = ViewState(initialValue: item?.kind ?? "app")
        _target = ViewState(initialValue: item?.target ?? "")
        _shell = ViewState(initialValue: item?.shell ?? "/bin/zsh")
        _subscriptionScript = ViewState(initialValue: item?.subscriptionScript ?? "")
        _allSubscriptions = ViewState(initialValue: item?.target == "all" || item == nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item == nil ? "添加快捷项目" : "编辑快捷项目").font(.title2.bold())
            TextField("显示名称", text: $name).textFieldStyle(.roundedBorder)
            Picker("类型", selection: $kind) {
                Text("应用").tag("app")
                Text("脚本文件").tag("script")
                Text("Shell 命令").tag("command")
                Text("订阅更新").tag("subscription")
            }.pickerStyle(.segmented).onChange(of: kind) { _ in
                target = kind == "subscription" ? "all" : ""
                if kind == "subscription" { allSubscriptions = true; shell = "/usr/bin/python3" }
                else { shell = "/bin/zsh" }
            }
            if kind == "subscription" {
                HStack {
                    TextField("订阅脚本绝对路径", text: $subscriptionScript).textFieldStyle(.roundedBorder)
                    Button("选择脚本…") { chooseFile(subscription: true) }
                }
                HStack {
                    TextField("解释器绝对路径，例如 /usr/bin/python3", text: $shell).textFieldStyle(.roundedBorder)
                    Button("选择解释器…") { chooseInterpreter() }
                }
                Toggle("更新全部订阅", isOn: $allSubscriptions).onChange(of: allSubscriptions) { all in target = all ? "all" : "" }
                if !allSubscriptions { TextField("订阅 ID", text: $target).textFieldStyle(.roundedBorder) }
                Text("脚本需支持 sync（全部）或 sync --id 订阅ID（单项）。以脚本目录为工作目录，校验与失败回滚由所选脚本负责；路径和参数仅存本机。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if kind == "command" {
                Text("Shell 命令").font(.headline)
                TextEditor(text: $target).font(.system(.body, design: .monospaced)).frame(height: 130)
                    .border(Color.secondary.opacity(0.3)).accessibilityLabel("Shell 命令内容")
            } else {
                HStack {
                    TextField(kind == "app" ? "应用路径（.app）" : "Shell 脚本路径", text: $target).textFieldStyle(.roundedBorder)
                    Button("选择文件…") { chooseFile() }
                }
            }
            if kind == "script" || kind == "command" {
                Picker("解释器", selection: $shell) {
                    Text("zsh").tag("/bin/zsh"); Text("bash").tag("/bin/bash")
                }
                Text("点击网页项目后，会以当前 Mac 用户身份执行。请使用无需交互输入的 Shell 脚本或命令；路径和命令内容只保存在本机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.failed { Text(model.message).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    var body: [String: Any] = ["action": "console-save", "name": name, "kind": kind, "target": target, "shell": shell]
                    if kind == "subscription" { body["subscriptionScript"] = subscriptionScript }
                    if let item { body["id"] = item.id }
                    Task {
                        await model.perform(body, success: "快捷项目已保存")
                        if !model.failed { await model.loadConsole(); if !model.failed { dismiss() } }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (kind == "subscription" && (subscriptionScript.isEmpty || shell.isEmpty)))
            }
        }.padding(24).frame(width: 540).disabled(model.busy)
    }
    private func chooseFile(subscription: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if kind == "app" && !subscription { panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications") }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if subscription { subscriptionScript = url.path } else { target = url.path }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = kind == "app" ? appDisplayName(url.path) : url.deletingPathExtension().lastPathComponent
        }
    }
    private func chooseInterpreter() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        shell = url.path
    }
}
