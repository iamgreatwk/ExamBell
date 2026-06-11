import Foundation
import UserNotifications

/// 通过本地推送通知实现打铃提醒
/// 使用 .timeSensitive 中断级别，穿透专注模式，音量与系统通知相同
@MainActor
final class AlarmManager: ObservableObject {

    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "exambell-"

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var lastResult: AlarmOperationResult?

    /// 检查/请求通知权限
    func requestAccess() async -> Bool {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
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

    /// 为选中的打铃时间创建通知
    func createAlarms(for bells: [BellTime], advanceMinutes: Int = 5) async -> AlarmOperationResult {
        guard await requestAccess() else {
            return .failure("未获得通知权限。请在 设置 → 通知 → 考试打铃 中开启。")
        }

        var created = 0
        var errors: [String] = []

        for bell in bells {
            let now = Date()
            guard bell.date > now else {
                errors.append("跳过已过期: \(bell.timeString)")
                continue
            }

            // 通知内容
            let content = UNMutableNotificationContent()
            content.title = bell.label
            content.body = "\(bell.session) \(bell.timeString) — 考试打铃"
            content.sound = .default
            content.badge = 1

            // timeSensitive: 可穿透专注模式/睡眠模式 (iOS 15+)
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
            }

            // 正点通知
            let triggerInterval = bell.date.timeIntervalSinceNow
            let mainTrigger = UNTimeIntervalNotificationTrigger(timeInterval: max(triggerInterval, 1), repeats: false)
            let mainRequest = UNNotificationRequest(
                identifier: makeIdentifier(bell, type: "main"),
                content: content,
                trigger: mainTrigger
            )

            do {
                try await center.add(mainRequest)
                created += 1
            } catch {
                errors.append("创建失败 \(bell.timeString): \(error.localizedDescription)")
                continue
            }

            // 提前提醒
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

                do {
                    try await center.add(earlyRequest)
                } catch {
                    errors.append("提前提醒失败 \(bell.timeString): \(error.localizedDescription)")
                }
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

    /// 取消所有打铃通知
    func deleteAllAlarms(for date: Date) async -> AlarmOperationResult {
        let pending = await center.pendingNotificationRequests()
        let targetIds = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }

        if targetIds.isEmpty {
            return .failure("该日期没有已设置的打铃提醒。")
        }

        center.removePendingNotificationRequests(withIdentifiers: targetIds)
        let result: AlarmOperationResult = .success(created: 0, deleted: targetIds.count)
        lastResult = result
        return result
    }

    /// 获取待发送的打铃通知列表
    func getAlarms(for date: Date) async -> [PendingAlarm] {
        let pending = await center.pendingNotificationRequests()
        let targetIds = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }

        // 从通知中心取详细信息
        return pending
            .filter { targetIds.contains($0.identifier) }
            .compactMap { request in
                guard let trigger = request.trigger as? UNTimeIntervalNotificationTrigger,
                      let fireDate = Calendar.current.date(
                        byAdding: .second,
                        value: Int(trigger.timeInterval),
                        to: Date()
                      ) else { return nil }
                return PendingAlarm(
                    identifier: request.identifier,
                    title: request.content.title,
                    body: request.content.body,
                    fireDate: fireDate
                )
            }
            .sorted { $0.fireDate < $1.fireDate }
    }

    /// 取消单条通知
    func deleteAlarm(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - Private

    private func makeIdentifier(_ bell: BellTime, type: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        return "\(identifierPrefix)\(df.string(from: bell.date))-\(type)"
    }
}

/// 待发送的提醒（替代 EKEvent）
struct PendingAlarm: Identifiable {
    let id = UUID()
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date
}
