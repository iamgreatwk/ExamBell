import SwiftUI

// MARK: - ContentView

struct ContentView: View {

    @StateObject private var alarmManager = AlarmManager()

    // 输入
    @State private var rawText = ""
    @State private var examDate = Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()

    // 解析
    @State private var parseResult: ParseResult?
    @State private var bellTimes: [BellTime] = []
    @State private var selectedBells: Set<UUID> = []

    // 状态
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isLoading = false
    @State private var showExistingAlarms = false
    @State private var advanceMinutes = 10  // 提前提醒分钟数
    @State private var existingAlarms: [PendingAlarm] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    pasteArea
                    datePickerRow
                    advanceRow
                    actionButtons
                    if !bellTimes.isEmpty {
                        schedulePreview
                    }
                }
                .padding()
            }
            .navigationTitle("考试打铃")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        loadExistingAlarms()
                    } label: {
                        Image(systemName: "clock.badge.checkmark")
                    }
                }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .sheet(isPresented: $showExistingAlarms) {
                existingAlarmsView
            }
            .overlay {
                if isLoading {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView("处理中...")
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(12)
                }
            }
        }
    }

    // MARK: - Subviews

    /// 粘贴区域
    private var pasteArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("粘贴考试时间表").font(.headline)
                Spacer()
                PasteButton(payloadType: String.self) { strings in
                    rawText = strings.first ?? ""
                    parseSchedule()
                }
            }

            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: rawText) { _ in parseSchedule() }

            if let warnings = parseResult?.warnings, !warnings.isEmpty {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    /// 日期选择
    private var datePickerRow: some View {
        HStack {
            Text("考试日期").font(.headline)
            Spacer()
            DatePicker("", selection: $examDate, displayedComponents: .date)
                .labelsHidden()
                .onChange(of: examDate) { _ in parseSchedule() }
        }
    }

    /// 提前提醒
    private var advanceRow: some View {
        HStack {
            Text("提前提醒").font(.headline)
            Spacer()
            Stepper("\(advanceMinutes) 分钟", value: $advanceMinutes, in: 0...60, step: 5)
                .labelsHidden()
            Text("\(advanceMinutes) 分钟")
                .font(.subheadline.monospacedDigit())
                .foregroundColor(advanceMinutes == 0 ? .secondary : .blue)
        }
    }

    /// 操作按钮
    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button(action: setAlarms) {
                Label("设置闹钟 (\(selectedCount))", systemImage: "bell.badge.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedCount == 0 || isLoading)

            Button(role: .destructive, action: deleteAlarms) {
                Label("取消全部", systemImage: "bell.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(bellTimes.isEmpty || isLoading)
        }
    }

    /// 打铃预览
    private var schedulePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("解析结果").font(.headline)
                Spacer()
                Text("已选 \(selectedCount)/\(bellTimes.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(selectedCount == bellTimes.count ? "取消全选" : "全选") {
                    toggleSelectAll()
                }
                .font(.caption)
            }

            ForEach(bellTimes) { bell in
                HStack {
                    Image(systemName: selectedBells.contains(bell.id)
                          ? "checkmark.circle.fill"
                          : "circle")
                        .foregroundColor(selectedBells.contains(bell.id) ? .blue : .gray)
                        .font(.title3)
                        .onTapGesture { toggleBell(bell.id) }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(bell.timeString)
                            .font(.system(.title3, design: .monospaced))
                            .fontWeight(.semibold)
                        Text(bell.label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    if bell.session == "下午" {
                        Text("下午")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(4)
                    } else {
                        Text("上午")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }

    /// 已有闹钟查看
    private var existingAlarmsView: some View {
        NavigationStack {
            List {
                if existingAlarms.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无闹钟")
                            .font(.headline)
                        Text("该日期还没有设置打铃闹钟")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(existingAlarms) { alarm in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(alarm.fireDate, style: .time)
                                .font(.headline.monospaced())
                            Text(alarm.title)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onDelete { indexSet in
                        deleteSpecificAlarms(at: indexSet)
                    }
                }
            }
            .navigationTitle("已设闹钟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showExistingAlarms = false }
                }
            }
        }
    }

    // MARK: - Computed

    private var selectedCount: Int {
        selectedBells.count
    }

    // MARK: - Actions

    private func parseSchedule() {
        let result = ScheduleParser.parse(rawText)
        parseResult = result

        // 重新计算日期——将解析出的时间应用到 examDate 那天
        let calendar = Calendar.current
        let examComponents = calendar.dateComponents([.year, .month, .day], from: examDate)

        var allBells: [BellTime] = []
        for day in result.days {
            for bell in day.morningBells {
                var comps = calendar.dateComponents([.hour, .minute], from: bell.date)
                comps.year = examComponents.year
                comps.month = examComponents.month
                comps.day = examComponents.day
                if let newDate = calendar.date(from: comps) {
                    allBells.append(BellTime(
                        date: newDate,
                        timeString: bell.timeString,
                        label: bell.label,
                        session: bell.session,
                        bellNumber: bell.bellNumber,
                        summary: bell.summary,
                        isSelected: selectedBells.contains(bell.id) || selectedBells.isEmpty
                    ))
                }
            }
        }

        bellTimes = allBells

        // 首次解析时全选
        if selectedBells.isEmpty && !allBells.isEmpty {
            selectedBells = Set(allBells.map(\.id))
        } else {
            // 保留之前的选择状态
            let existingIds = selectedBells
            selectedBells = Set(allBells.filter { bell in
                existingIds.contains(where: { existing in
                    // Match by timeString and session since IDs change on re-parse
                    bell.timeString == bellTimes.first(where: { $0.id == existing })?.timeString
                })
            }.map(\.id))
            if selectedBells.isEmpty {
                selectedBells = Set(allBells.map(\.id))
            }
        }
    }

    private func toggleBell(_ id: UUID) {
        if selectedBells.contains(id) {
            selectedBells.remove(id)
        } else {
            selectedBells.insert(id)
        }
    }

    private func toggleSelectAll() {
        if selectedCount == bellTimes.count {
            selectedBells = []
        } else {
            selectedBells = Set(bellTimes.map(\.id))
        }
    }

    private func setAlarms() {
        isLoading = true
        let selected = bellTimes.filter { selectedBells.contains($0.id) }
        Task {
            let result = await alarmManager.createAlarms(for: selected, advanceMinutes: advanceMinutes)
            isLoading = false
            switch result {
            case .success(let created, _):
                showAlert("成功", "已创建 \(created) 个打铃闹钟")
            case .failure(let msg):
                showAlert("失败", msg)
            case .partial(let created, _, let errors):
                showAlert("部分成功", "创建了 \(created) 个。\n\(errors.joined(separator: "\n"))")
            }
        }
    }

    private func deleteAlarms() {
        isLoading = true
        Task {
            let result = await alarmManager.deleteAllAlarms(for: examDate)
            isLoading = false
            switch result {
            case .success(_, let deleted):
                showAlert("已取消", "已删除 \(deleted) 个打铃闹钟")
            case .failure(let msg):
                showAlert("提示", msg)
            case .partial(_, let deleted, let errors):
                showAlert("部分删除", "删除了 \(deleted) 个。\n\(errors.joined(separator: "\n"))")
            }
        }
    }

    private func loadExistingAlarms() {
        Task {
            let alarms = await alarmManager.getAlarms(for: examDate)
            existingAlarms = alarms
            showExistingAlarms = true
        }
    }

    private func deleteSpecificAlarms(at offsets: IndexSet) {
        for idx in offsets {
            alarmManager.deleteAlarm(identifier: existingAlarms[idx].identifier)
        }
        existingAlarms.remove(atOffsets: offsets)
    }

    private func showAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}
