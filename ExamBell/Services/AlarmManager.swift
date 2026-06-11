import Foundation
import EventKit
import UIKit
import UserNotifications

/// 双通道打铃提醒：日历事件（保底）+ 强提醒通知（timeSensitive）
@MainActor
final class AlarmManager: ObservableObject {

    private let eventStore = EKEventStore()
    private let notificationCenter = UNUserNotificationCenter.current()
    private let calendarTitle = "考试打铃"
    private let identifierPrefix = "exambell-"

    @Published var lastResult: AlarmOperationResult?

    // MARK: - Create (Dual Channel)

    /// 双通道创建：日历事件 + timeSensitive 通知
    func createAlarms(for bells: [BellTime], advanceMinutes: Int = 5, offsets: [UUID: Int] = [:]) async -> AlarmOperationResult {
        // 请求日历权限
        var calendarGranted = false
        do {
            calendarGranted = try await requestCalendarAccess()
        } catch {
            calendarGranted = false
        }

        // 请求通知权限
        let notifyGranted = await checkNotificationAccess()

        if !calendarGranted && !notifyGranted {
            return .failure("需要日历或通知权限。请在 设置 中开启。")
        }

        let calendar = calendarGranted ? getOrCreateCalendar() : nil
        var created = 0
        var errors: [String] = []

        for bell in bells {
            let now = Date()

            // 应用上下午偏移
            let offsetMinutes = offsets[bell.id] ?? 0
            let shiftedBell = bell.date.addingTimeInterval(TimeInterval(offsetMinutes * 60))

            guard shiftedBell > now else {
                errors.append("跳过已过期: \(bell.timeString)")
                continue
            }

            // 实际提醒时间 = (打铃时间 + 偏移) - 提前量
            let alertDate = shiftedBell.addingTimeInterval(TimeInterval(-advanceMinutes * 60))
            guard alertDate > now else {
                errors.append("跳过已过期: \(bell.timeString)")
                continue
            }

            // 通知内容使用调整后的打铃时间
            let df2 = DateFormatter()
            df2.dateFormat = "HH:mm"
            let shiftedTimeStr = df2.string(from: shiftedBell)
            let offsetSuffix = offsetMinutes != 0 ? "（已偏移\(offsetMinutes > 0 ? "+" : "")\(offsetMinutes)分）" : ""
            let advanceSuffix = advanceMinutes > 0 ? "（\(advanceMinutes)分钟后打铃）" : ""
            let alertLabel = "🔔 \(bell.label)\(offsetSuffix)"

            var bellOK = false

            // ── 通道1: 日历事件（保底 + 日历可见） ──
            if let cal = calendar {
                let event = EKEvent(eventStore: eventStore)
                event.title = alertLabel
                event.calendar = cal
                event.startDate = alertDate
                event.endDate = alertDate.addingTimeInterval(60)
                event.notes = "\(bell.summary) — 偏移\(offsetSuffix) 提前\(advanceMinutes)分提醒"
                event.isAllDay = false
                event.addAlarm(EKAlarm(absoluteDate: alertDate))

                if let _ = try? eventStore.save(event, span: .thisEvent) {
                    bellOK = true
                }
            }

            // ── 通道2: timeSensitive 强提醒通知 ──
            if notifyGranted {
                let content = UNMutableNotificationContent()
                content.title = alertLabel
                content.body = "\(bell.session) \(shiftedTimeStr)\(advanceSuffix)\(offsetSuffix) — 考试打铃"
                content.sound = .default
                if #available(iOS 15.0, *) {
                    content.interruptionLevel = .timeSensitive
                }

                let interval = alertDate.timeIntervalSinceNow
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 1), repeats: false)
                let request = UNNotificationRequest(
                    identifier: makeIdentifier(bell, type: "alert"),
                    content: content,
                    trigger: trigger
                )

                if let _ = try? await notificationCenter.add(request) {
                    bellOK = true
                }
            }

            if bellOK {
                created += 1
            } else {
                errors.append("创建失败 \(bell.timeString)")
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

    // MARK: - Delete

    func deleteAllAlarms(for date: Date) async -> AlarmOperationResult {
        var deleted = 0
        var errors: [String] = []

        // 删除日历事件
        if let calendar = getOrCreateCalendar() {
            let startOfDay = Calendar.current.startOfDay(for: date)
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
            let predicate = eventStore.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: [calendar])
            let events = eventStore.events(matching: predicate)
            for event in events {
                do {
                    try eventStore.remove(event, span: .thisEvent)
                    deleted += 1
                } catch {
                    errors.append("日历删除失败: \(error.localizedDescription)")
                }
            }
        }

        // 删除通知
        let pending = await notificationCenter.pendingNotificationRequests()
        let notifyIds = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        if !notifyIds.isEmpty {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: notifyIds)
            deleted += notifyIds.count
        }

        if deleted == 0 && errors.isEmpty {
            return .failure("该日期没有已设置的打铃提醒。")
        }

        let result: AlarmOperationResult = errors.isEmpty
            ? .success(created: 0, deleted: deleted)
            : .partial(created: 0, deleted: deleted, errors: errors)
        lastResult = result
        return result
    }

    // MARK: - Query

    func getAlarms(for date: Date) async -> [PendingAlarm] {
        let pending = await notificationCenter.pendingNotificationRequests()
        return pending
            .filter { $0.identifier.hasPrefix(identifierPrefix) }
            .compactMap { request in
                guard let trigger = request.trigger as? UNTimeIntervalNotificationTrigger,
                      let fireDate = Calendar.current.date(byAdding: .second, value: Int(trigger.timeInterval), to: Date())
                else { return nil }
                return PendingAlarm(identifier: request.identifier, title: request.content.title, body: request.content.body, fireDate: fireDate)
            }
            .sorted { $0.fireDate < $1.fireDate }
    }

    func deleteAlarm(identifier: String) {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - Private

    private func requestCalendarAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            if #available(iOS 17.0, *) {
                return try await eventStore.requestFullAccessToEvents()
            } else {
                return await withCheckedContinuation { c in
                    eventStore.requestAccess(to: .event) { granted, _ in c.resume(returning: granted) }
                }
            }
        default:
            return false
        }
    }

    private func getOrCreateCalendar() -> EKCalendar? {
        if let existing = eventStore.calendars(for: .event).first(where: { $0.title == calendarTitle }) {
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: eventStore)
        cal.title = calendarTitle
        cal.cgColor = UIColor.systemOrange.cgColor
        cal.source = eventStore.sources.first(where: { $0.sourceType == .local })
            ?? eventStore.sources.first(where: { $0.sourceType == .calDAV })
            ?? eventStore.sources.first
        guard let _ = cal.source else { return nil }
        return (try? eventStore.saveCalendar(cal, commit: true)) != nil ? cal : nil
    }

    private func checkNotificationAccess() async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return ((try? await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])) ?? false)
        default:
            return false
        }
    }

    private func makeIdentifier(_ bell: BellTime, type: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        return "\(identifierPrefix)\(df.string(from: bell.date))-\(type)"
    }
}

/// 待发送的提醒
struct PendingAlarm: Identifiable {
    let id = UUID()
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date
}
