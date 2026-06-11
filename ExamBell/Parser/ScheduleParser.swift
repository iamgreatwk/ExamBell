import Foundation

/// 从粘贴的考试时间表文本中解析打铃时间
struct ScheduleParser {

    /// 解析粘贴文本，返回 ParseResult
    /// 支持的格式示例:
    ///   6月13日上午
    ///   08:40第一次打铃(组织考生进入考室)
    ///   09:00第二次打铃(考试开始、禁止迟到考生入场)
    static func parse(_ rawText: String) -> ParseResult {
        var warnings: [String] = []
        var days: [BellDay] = []

        // 按行分割
        let lines = rawText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var currentDay: BellDay? = nil
        var currentSession = ""  // 上午 or 下午
        let currentYear = Calendar.current.component(.year, from: Date())

        for line in lines {
            // 检测日期行: "6月13日上午" 或 "6月13日下午"
            if let (day, session) = parseDateLine(line, year: currentYear) {
                if let existing = currentDay {
                    days.append(existing)
                }
                currentDay = BellDay(
                    dateString: day,
                    date: makeDate(year: currentYear, monthDay: day, hour: 0, minute: 0)
                )
                currentSession = session
                continue
            }

            // 检测时间行: "08:40第一次打铃(组织考生进入考室)"
            if let bell = parseTimeLine(line, session: currentSession, day: currentDay) {
                currentDay?.morningBells.append(bell)
                if currentSession == "下午" {
                    currentDay?.afternoonBells.append(bell)
                }
                continue
            }

            // 无法识别的行
            if currentDay != nil {
                warnings.append("未识别的行: \(line)")
            }
        }

        // 保存最后一天
        if let last = currentDay {
            days.append(last)
        }

        if days.isEmpty {
            warnings.append("未找到有效的打铃时间。请确认格式: 日期行(如\"6月13日上午\") + 时间行(如\"08:40第一次打铃(...)\")")
        }

        return ParseResult(days: days, rawText: rawText, warnings: warnings)
    }

    // MARK: - Private Helpers

    /// 解析日期行: "6月13日上午" → ("6月13日", "上午")
    private static func parseDateLine(_ line: String, year: Int) -> (String, String)? {
        let pattern = #"(\d{1,2})月(\d{1,2})日?\s*(上午|下午)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        guard let monthRange = Range(match.range(at: 1), in: line),
              let dayRange = Range(match.range(at: 2), in: line),
              let sessionRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        let month = String(line[monthRange])
        let day = String(line[dayRange])
        let session = String(line[sessionRange])
        let dateStr = "\(month)月\(day)日"

        return (dateStr, session)
    }

    /// 解析时间行: "08:40第一次打铃(组织考生进入考室)"
    private static func parseTimeLine(_ line: String, session: String, day: BellDay?) -> BellTime? {
        // 匹配 HH:MM 开头
        let pattern = #"^(\d{1,2}):(\d{2})\D"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        guard let hourRange = Range(match.range(at: 1), in: line),
              let minuteRange = Range(match.range(at: 2), in: line),
              let hour = Int(line[hourRange]),
              let minute = Int(line[minuteRange]) else {
            return nil
        }

        let timeString = "\(String(format: "%02d", hour)):\(String(format: "%02d", minute))"
        let label = String(line.dropFirst(match.range.length - 1))  // 去掉时间前缀

        // 提取第几次打铃
        var bellNumber = 0
        if let numRange = label.range(of: #"第[一二三四五六七八九十]+次"#, options: .regularExpression) {
            let numStr = String(label[numRange])
            bellNumber = chineseNumToInt(numStr)
        }

        guard let day = day else { return nil }

        let fullDate = makeDate(year: Calendar.current.component(.year, from: day.date),
                                 monthDay: day.dateString,
                                 hour: hour,
                                 minute: minute)

        let summary = "\(day.dateString)\(session) \(timeString) \(label)"

        return BellTime(
            date: fullDate,
            timeString: timeString,
            label: label,
            session: session,
            bellNumber: bellNumber,
            summary: summary
        )
    }

    /// 构造完整日期
    private static func makeDate(year: Int, monthDay: String, hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.hour = hour
        comps.minute = minute
        comps.second = 0

        // 解析 monthDay: "6月13日"
        let parts = monthDay.components(separatedBy: CharacterSet(charactersIn: "月日"))
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            comps.month = Int(parts[0])
            comps.day = Int(parts[1])
        }

        return Calendar.current.date(from: comps) ?? Date()
    }

    /// 中文数字转整型: "第三"次 → 3
    private static func chineseNumToInt(_ s: String) -> Int {
        let map: [Character: Int] = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ]
        for (ch, val) in map {
            if s.contains(ch) {
                if ch == "十" { return 10 }
                return val
            }
        }
        return 0
    }
}
