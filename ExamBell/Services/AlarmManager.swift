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
    func createAlarms(for bells: [BellTime], advanceMinutes: Int = 5) async -> AlarmOperationResult {
        // 请求日历权限
        var calendarGranted = false
        do {
            calendarGranted = try await requestCalendarAccess()
        } catch {
            calendarGranted = false
        }

        // 请求通知权限
        let notifyGranted: Bool = {
            let settings = await notificationCenter.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .notDetermined:
                return ((try? await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])) ?? false)
            default:
                return false
            }
        }()

        if !calendarGranted && !notifyGranted {
            return .failure("需要日历或通知权限。请在 设置 中开启。")
        }

        let calendar = calendarGranted ? getOrCreateCalendar() : nil
        var created = 0
        var errors: [String] = []

        for bell in bells {
            let now = Date()
            guard bell.date > now else {
                errors.append("跳过已过期: \(bell.timeString)")
                continue
            }

            var bellOK = false

            // ── 通道1: 日历事件（保底 + 日历可见） ──
            if let cal = calendar {
                let event = EKEvent(eventStore: eventStore)
                event.title = bell.label
                event.calendar = cal
                event.startDate = bell.date
                event.endDate = bell.date.addingTimeInterval(60)
                event.notes = bell.summary
                event.isAllDay = false

                // 日历正点提醒
                event.addAlarm(EKAlarm(absoluteDate: bell.date))

                // 日历提前提醒
                if advanceMinutes > 0 {
                    let earlyDate = bell.date.addingTimeInterval(TimeInterval(-advanceMinutes * 60))
                    if earlyDate > now {
                        event.addAlarm(EKAlarm(absoluteDate: earlyDate))
                    }
                }

                if let _ = try? eventStore.save(event, span: .thisEvent) {
                    bellOK = true
                }
            }

            // ── 通道2: timeSensitive 强提醒通知 ──
            if notifyGranted {
                // 正点通知
                let content = UNMutableNotificationContent()
                content.title = "🔔 \(bell.label)"
                content.body = "\(bell.session) \(bell.timeString) — 考试打铃"
                content.sound = .default
                if #available(iOS 15.0, *) {
                    content.interruptionLevel = .timeSensitive
                }

                let mainInterval = bell.date.timeIntervalSinceNow
                let mainTrigger = UNTimeIntervalNotificationTrigger(timeInterval: max(mainInterval, 1), repeats: false)
                let mainRequest = UNNotificationRequest(
                    identifier: makeIdentifier(bell, type: "main"),
                    content: content,
                    trigger: mainTrigger
                )

                if let _ = try? await notificationCenter.add(mainRequest) {
                    bellOK = true
                }

                // 提前提醒通知
                if advanceMinutes > 0 {
                    let earlyDate = bell.date.addingTimeInterval(TimeInterval(-advanceMinutes * 60))
                    guard earlyDate > now else { continue }

                    let earlyContent = UNMutableNotificationContent()
                    earlyContent.title = "⚠️ 即将打铃"
                    earlyContent.body = "\(bell.label) — \(advanceMinutes)分钟后 (\(bell.timeString))"
                    earlyContent.sound = .default
                    if #available(iOS 15.0, *) {
                        earlyContent.interruptionLevel = .timeSensitive
                    }

                    let earlyInterval = earlyDate.timeIntervalSinceNow
                    let earlyTrigger = UNTimeIntervalNotificationTrigger(timeInterval: max(earlyInterval, 1), repeats: false)
                    let earlyRequest = UNNotificationRequest(
                        identifier: makeIdentifier(bell, type: "early"),
                        content: earlyContent,
                        trigger: earlyTrigger
                    )
                    try? await notificationCenter.add(earlyRequest)
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
