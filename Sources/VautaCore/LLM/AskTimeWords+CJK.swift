// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The words `AskTimeScope` reads in Japanese, Korean and Chinese, where particles attach to the word ("지난주에", "先週の"):
/// periods are looked for as substrings, numbers and dates by pattern, and the context is the text right before and after.
extension AskTimeWords {
    struct Script: Sendable {
        var periods: [(text: String, period: Relative, current: Bool)] = []
        var excluded: [String] = []
        /// Patterns with named groups: `n` a number and `u` its unit; `w` a weekday; `y`, `m`, `d` a date; `q` a quarter.
        var ago = "", rolling = "", weekdayLastWeek = "", weekdayPast = "", date = "", quarter = "", year = ""
        var units: [String: (unit: Unit, count: Int)] = [:]
        var weekdays: [String: Int] = [:]
        /// Markers right after the time (or before it, `…Before`), as in `Lexicon`.
        var deadlineAfter: [String] = [], deadlineBefore: [String] = []
        var sinceAfter: [String] = [], sinceBefore: [String] = []
        var intoAfter: [String] = [], intoBefore: [String] = []
        var genitiveAfter: [String] = []
        var meetings: [String] = []
    }

    static let scripts: [String: Script] = ["ja": japanese, "ko": korean, "zh": chinese]

    /// Han numerals up to 99 ("三", "十二", "二十"), and Korean native numbers up to ten ("한 달", "두 주").
    static func cjkNumber(_ text: String) -> Int? {
        if let n = Int(text) { return n }
        if let n = koreanNumbers[text] { return n }
        let digits: [Character: Int] = ["一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let parts = text.split(separator: "十", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return text.count == 1 ? digits[text.first!] : nil
        case 2:
            let tens = parts[0].isEmpty ? 1 : (parts[0].count == 1 ? digits[parts[0].first!] : nil)
            let ones = parts[1].isEmpty ? 0 : (parts[1].count == 1 ? digits[parts[1].first!] : nil)
            guard let tens, let ones else { return nil }
            return tens * 10 + ones
        default: return nil
        }
    }

    private static let koreanNumbers: [String: Int] = ["한": 1, "두": 2, "세": 3, "네": 4, "다섯": 5, "여섯": 6, "일곱": 7, "여덟": 8, "아홉": 9, "열": 10]

    private static let hanNumber = "[0-9]{1,3}|[一二三四五六七八九十两兩]{1,3}"
    private static let hanMonth = "[0-9]{1,2}|十一|十二|十|[一二三四五六七八九]"
    private static let hanDay = "[0-9]{1,2}|[一二三]?十[一二三四五六七八九]?|[一二三四五六七八九]"

    private static let japanese = Script(
        periods: [("一昨日", .day(-2), false), ("おととい", .day(-2), false), ("昨日", .day(-1), false), ("きのう", .day(-1), false), ("今朝", .day(0), false),
                  ("今日", .day(0), true), ("本日", .day(0), true), ("きょう", .day(0), true), ("今週", .week(0), true), ("先週", .week(-1), false),
                  ("今月", .month(0), true), ("先月", .month(-1), false), ("今四半期", .quarter(0), true), ("前四半期", .quarter(-1), false),
                  ("今年", .year(0), true), ("本年", .year(0), true), ("去年", .year(-1), false), ("昨年", .year(-1), false)],
        ago: "(?<n>\(hanNumber))\\s?(?<u>日|週間|週|か月|ヶ月|カ月|ケ月|ヵ月|年)\\s?前",
        rolling: "(?:過去|直近|ここ|この)\\s?(?<n>\(hanNumber))\\s?(?<u>日|週間|週|か月|ヶ月|カ月|ケ月|ヵ月|年)",
        weekdayLastWeek: "先週\\s?の?\\s?(?<w>[月火水木金土日])曜",
        date: "(?:(?<y>[0-9]{4})\\s?年\\s?)?(?<m>\(hanMonth))\\s?月(?:\\s?(?<d>\(hanDay))\\s?日)?",
        quarter: "(?:(?<y>[0-9]{4})\\s?年\\s?度?\\s?の?\\s?)?第?\\s?(?<q>[1-4一二三四])\\s?四半期",
        year: "(?<y>[0-9]{4})\\s?年(?!\\s?度?\\s?の?\\s?(?:[0-9]{1,2}|[一二三四五六七八九十]{1,2})\\s?月)(?!\\s?度?\\s?の?\\s?第?\\s?[1-4一二三四]\\s?四半期)",
        units: ["日": (.day, 1), "週間": (.week, 1), "週": (.week, 1), "か月": (.month, 1), "ヶ月": (.month, 1), "カ月": (.month, 1), "ケ月": (.month, 1),
                "ヵ月": (.month, 1), "年": (.year, 1)],
        weekdays: ["日": 1, "月": 2, "火": 3, "水": 4, "木": 5, "金": 6, "土": 7],
        deadlineAfter: ["までに", "まで", "以前", "より前", "中に"],
        sinceAfter: ["から", "以来", "以降"],
        intoAfter: ["に", "の間"],
        genitiveAfter: ["の"],
        meetings: ["会議", "ミーティング", "打ち合わせ", "打合せ", "通話", "面談", "定例", "会合"])

    private static let korean = Script(
        periods: [("그저께", .day(-2), false), ("그제", .day(-2), false), ("어제", .day(-1), false), ("오늘 아침", .day(0), false), ("오늘", .day(0), true),
                  ("이번 주", .week(0), true), ("이번주", .week(0), true), ("금주", .week(0), true), ("지난주", .week(-1), false), ("지난 주", .week(-1), false),
                  ("저번 주", .week(-1), false), ("저번주", .week(-1), false), ("이번 달", .month(0), true), ("이번달", .month(0), true),
                  ("지난달", .month(-1), false), ("지난 달", .month(-1), false), ("저번 달", .month(-1), false), ("저번달", .month(-1), false),
                  ("이번 분기", .quarter(0), true), ("지난 분기", .quarter(-1), false), ("올해", .year(0), true), ("금년", .year(0), true),
                  ("작년", .year(-1), false), ("지난해", .year(-1), false)],
        excluded: ["오늘날"],
        ago: "(?<n>[0-9]{1,3}|한|두|세|네|다섯|여섯|일곱|여덟|아홉|열)\\s?(?<u>일|주일|주|달|개월|년)\\s?전",
        rolling: "(?:지난|최근|요)\\s?(?<n>[0-9]{1,3}|한|두|세|네|다섯|여섯|일곱|여덟|아홉|열)\\s?(?<u>일|주일|주|달|개월|년)",
        weekdayLastWeek: "(?:지난|저번)\\s?주\\s?(?<w>[월화수목금토일])요일",
        weekdayPast: "(?:지난|저번)\\s?(?<w>[월화수목금토일])요일",
        date: "(?:(?<y>[0-9]{4})\\s?년\\s?)?(?<m>[0-9]{1,2})\\s?월(?:\\s?(?<d>[0-9]{1,2})\\s?일)?",
        quarter: "(?:(?<y>[0-9]{4})\\s?년\\s?)?(?<q>[1-4])\\s?분기",
        year: "(?<y>[0-9]{4})\\s?년(?!\\s?[0-9]{1,2}\\s?월)(?!\\s?[1-4]\\s?분기)",
        units: ["일": (.day, 1), "주일": (.week, 1), "주": (.week, 1), "달": (.month, 1), "개월": (.month, 1), "년": (.year, 1)],
        weekdays: ["일": 1, "월": 2, "화": 3, "수": 4, "목": 5, "금": 6, "토": 7],
        deadlineAfter: ["까지", "이전", "전까지", "전"],
        sinceAfter: ["부터", "이후", "이래"],
        intoAfter: ["에", "동안", "중에"],
        genitiveAfter: ["의"],
        meetings: ["회의", "미팅", "통화", "면담", "모임"])

    private static let chinese = Script(
        periods: [("前天", .day(-2), false), ("昨天", .day(-1), false), ("昨日", .day(-1), false), ("今天早上", .day(0), false), ("今天上午", .day(0), false),
                  ("今早", .day(0), false), ("今天", .day(0), true), ("今日", .day(0), true), ("本周", .week(0), true), ("本週", .week(0), true),
                  ("这周", .week(0), true), ("這週", .week(0), true), ("这个星期", .week(0), true), ("這個星期", .week(0), true), ("这星期", .week(0), true),
                  ("這星期", .week(0), true), ("上周", .week(-1), false), ("上週", .week(-1), false), ("上个星期", .week(-1), false),
                  ("上個星期", .week(-1), false), ("上星期", .week(-1), false), ("上礼拜", .week(-1), false), ("上禮拜", .week(-1), false),
                  ("本月", .month(0), true), ("这个月", .month(0), true), ("這個月", .month(0), true), ("上个月", .month(-1), false),
                  ("上個月", .month(-1), false), ("上月", .month(-1), false), ("本季度", .quarter(0), true), ("这个季度", .quarter(0), true),
                  ("這個季度", .quarter(0), true), ("上季度", .quarter(-1), false), ("上个季度", .quarter(-1), false), ("上個季度", .quarter(-1), false),
                  ("今年", .year(0), true), ("去年", .year(-1), false)],
        ago: "(?<n>\(hanNumber))\\s?(?<u>天|日|周|週|个星期|個星期|星期|个礼拜|個禮拜|礼拜|禮拜|个月|個月|年)\\s?(?:以前|之前|前)",
        rolling: "(?:过去|過去|最近|近|这|這)\\s?的?\\s?(?<n>\(hanNumber))\\s?(?<u>天|日|周|週|个星期|個星期|星期|个礼拜|個禮拜|个月|個月|年)",
        weekdayLastWeek: "(?:上周|上週|上星期|上个星期|上個星期|上礼拜|上禮拜)\\s?(?<w>[一二三四五六日天])",
        date: "(?:(?<y>[0-9]{4})\\s?年\\s?)?(?<m>\(hanMonth))\\s?月份?(?:\\s?(?<d>\(hanDay))\\s?[日号號])?",
        quarter: "(?:(?<y>[0-9]{4})\\s?年\\s?的?\\s?)?第?\\s?(?<q>[1-4一二三四])\\s?季度",
        year: "(?<y>[0-9]{4})\\s?年(?!\\s?(?:[0-9]{1,2}|[一二三四五六七八九十]{1,2})\\s?月)(?!\\s?的?\\s?第?\\s?[1-4一二三四]\\s?季度)",
        units: ["天": (.day, 1), "日": (.day, 1), "周": (.week, 1), "週": (.week, 1), "个星期": (.week, 1), "個星期": (.week, 1), "星期": (.week, 1),
                "个礼拜": (.week, 1), "個禮拜": (.week, 1), "礼拜": (.week, 1), "禮拜": (.week, 1), "个月": (.month, 1), "個月": (.month, 1), "年": (.year, 1)],
        weekdays: ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7],
        deadlineAfter: ["之前", "以前", "前", "为止", "為止"], deadlineBefore: ["截至", "截止", "直到"],
        sinceAfter: ["以来", "以來", "开始", "開始", "起"], sinceBefore: ["从", "從", "自从", "自從", "自"],
        intoAfter: ["内", "內", "里", "裡", "期间", "期間"], intoBefore: ["在"],
        genitiveAfter: ["的"],
        meetings: ["会议", "會議", "开会", "開會", "例会", "例會", "通话", "通話", "讨论会", "討論會", "会上", "會上"])
}
