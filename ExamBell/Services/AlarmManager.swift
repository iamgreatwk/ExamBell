import Foundation
import EventKit

/// 通过 EventKit 管理考试打铃闹钟
/// 使用系统日历创建带提醒的事件实现"闹钟"效果
@MainActor
final class AlarmManager: ObservableObject {

    private let eventStore = EKEventStore()
    private let calendarTitle = "考试打铃"

    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var lastResult: AlarmOperationResult?

    /// 检查/请求日历权限
    func requestAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            do {
                let granted: Bool
                if #available(iOS 17.0, *) {
                    granted = try await eventStore.requestFullAccessToEvents()
                } else {
                    granted = await withCheckedContinuation { continuation in
                        eventStore.requestAccess(to: .event) { granted, _ in
                            continuation.resume(returning: granted)
                        }
                    }
                }
                authorizationStatus = granted ? .authorized : .denied
                return granted
            } catch {
                authorizationStatus = .denied
                return false
            }
        default:
            return false
        }
    }

    /// 为选中的打铃时间创建日历事件
    func createAlarms(for bells: [BellTime], dateOverrides: [UUID: Date] = [:]) async -> AlarmOperationResult {
        guard await requestAccess() else {
            return .failure("未获得日历访问权限。请在 设置 → 隐私 → 日历 中开启权限。")
        }

        guard let calendar = getOrCreateCalendar() else {
            return .failure("无法创建日历，请检查日历权限。")
        }

        var created = 0
        var errors: [String] = []

        for bell in bells {
            let bellDate = dateOverrides[bell.id] ?? bell.date

            let event = EKEvent(eventStore: eventStore)
            event.title = bell.label
            event.calendar = calendar
            event.startDate = bellDate
            event.endDate = bellDate.addingTimeInterval(60)  // 持续1分钟
            event.notes = bell.summary
            event.isAllDay = false

            // 添加提醒——在前0秒触发（即事件开始时打铃）
            let alarm = EKAlarm(absoluteDate: bellDate)
            event.addAlarm(alarm)

            // 第二个提醒：提前5分钟
            let earlyAlarm = EKAlarm(absoluteDate: bellDate.addingTimeInterval(-300))
            event.addAlarm(earlyAlarm)

            do {
                try eventStore.save(event, span: .thisEvent)
                created += 1
            } catch {
                errors.append("创建失败 \(bell.timeString): \(error.localizedDescription)")
            }
        }

        if created == 0 {
            return .failure(errors.first ?? "创建失败")
        }

        let result: AlarmOperationResult = errors.isEmpty
            ? .success(created: created, deleted: 0)
            : .partial(created: created, deleted: 0, errors: errors)
        lastResult = result
        return result
    }

    /// 删除指定日期范围内的所有打铃事件
    func deleteAllAlarms(for date: Date) async -> AlarmOperationResult {
        guard await requestAccess() else {
            return .failure("未获得日历访问权限。")
        }

        guard let calendar = getOrCreateCalendar() else {
            return .failure("找不到日历。")
        }

        // 查询该日期全天的事件
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = eventStore.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: [calendar]
        )

        let events = eventStore.events(matching: predicate)
        var deleted = 0
        var errors: [String] = []

        for event in events {
            do {
                try eventStore.remove(event, span: .thisEvent)
                deleted += 1
            } catch {
                errors.append("删除失败 \(event.title ?? ""): \(error.localizedDescription)")
            }
        }

        if deleted == 0 && errors.isEmpty {
            return .failure("该日期没有已设置的打铃闹钟。")
        }

        let result: AlarmOperationResult = errors.isEmpty
            ? .success(created: 0, deleted: deleted)
            : .partial(created: 0, deleted: deleted, errors: errors)
        lastResult = result
        return result
    }

    /// 获取指定日期的打铃事件列表
    func getAlarms(for date: Date) -> [EKEvent] {
        guard let calendar = getOrCreateCalendar() else { return [] }
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        let predicate = eventStore.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: [calendar]
        )
        return eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Private

    private func getOrCreateCalendar() -> EKCalendar? {
        // 查找已有日历
        if let existing = eventStore.calendars(for: .event)
            .first(where: { $0.title == calendarTitle }) {
            return existing
        }

        // 创建新日历——优先本地日历，其次 iCloud
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = calendarTitle
        calendar.cgColor = UIColor.systemOrange.cgColor

        // 优先使用本地日历源
        if let localSource = eventStore.sources.first(where: { $0.sourceType == .local }) {
            calendar.source = localSource
        } else if let icloudSource = eventStore.sources.first(where: { $0.sourceType == .calDAV }) {
            calendar.source = icloudSource
        } else if let firstSource = eventStore.sources.first {
            calendar.source = firstSource
        } else {
            return nil
        }

        do {
            try eventStore.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            print("创建日历失败: \(error)")
            return nil
        }
    }
}
