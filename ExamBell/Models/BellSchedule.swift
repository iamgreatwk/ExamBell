import Foundation

/// 单次打铃记录
struct BellTime: Identifiable, Equatable {
    let id = UUID()
    /// 打铃的完整日期时间
    let date: Date
    /// 原始时间字符串 (如 "08:40")
    let timeString: String
    /// 描述 (如 "第一次打铃(组织考生进入考室)")
    let label: String
    /// 场次 (上午/下午)
    let session: String
    /// 第几次打铃
    let bellNumber: Int
    /// 完整摘要
    let summary: String
    /// 是否被选中设置闹钟
    var isSelected: Bool = true
}

/// 一天的打铃计划
struct BellDay: Identifiable {
    let id = UUID()
    /// 日期字符串 (如 "6月13日")
    let dateString: String
    /// 解析出的日期
    let date: Date
    /// 上午的打铃列表
    var morningBells: [BellTime] = []
    /// 下午的打铃列表
    var afternoonBells: [BellTime] = []
}

/// 解析结果
struct ParseResult {
    let days: [BellDay]
    let rawText: String
    let warnings: [String]
}

/// 闹钟操作结果
enum AlarmOperationResult {
    case success(created: Int, deleted: Int)
    case failure(String)
    case partial(created: Int, deleted: Int, errors: [String])
}
