// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// Korean and Simplified Chinese sample content, mirroring the English meetings line by line.
extension SampleContent {
    // MARK: Korean

    static let korean = SampleContent(
        people: [
            Person(name: "나", note: "", aliases: []),
            Person(name: "김서연", note: "프로덕트 리드", aliases: ["서연"]),
            Person(name: "박대현", note: "엔지니어링 매니저", aliases: ["대현"]),
            Person(name: "이지우", note: "디자인", aliases: ["지우"]),
        ],
        project: Person(name: "아틀라스 출시", note: "28일 정식 출시", aliases: ["아틀라스"]),
        client: Person(name: "노스윈드", note: "파일럿 고객", aliases: []),
        glossary: [("SLA", "서비스 수준 협약"), ("RC", "릴리스 후보")],
        meetings: [
            SampleMeeting(
                daysAgo: 0, hour: 10, minutes: 24, title: "주간 프로덕트 회의",
                lines: [
                    Line(mine: false, text: "참석해 주셔서 감사합니다. 먼저 아틀라스 출시일부터 얘기하죠. 대현 님, 베타는 어떻게 되고 있나요?"),
                    Line(mine: false, text: "베타 빌드는 안정적입니다. 어제 마지막 차단 버그를 해결해서 목요일에 테스터에게 배포할 수 있습니다."),
                    Line(mine: true, text: "좋네요. 지우 님, 그 빌드에 맞춘 온보딩 화면은 준비됐나요?"),
                    Line(mine: false, text: "거의요. 빈 상태 화면이 남았는데 수요일까지 넘길 수 있어요."),
                    Line(mine: false, text: "그럼 결정하죠. 베타는 목요일에 테스터에게 배포하고 정식 출시는 28일로 유지합니다."),
                    Line(mine: true, text: "알겠습니다. 릴리스 노트를 작성해서 목요일 전에 노스윈드에 보내겠습니다."),
                    Line(mine: false, text: "위험 요소는 동기화 서비스입니다. 큰 워크스페이스에서는 아직 시간 초과가 납니다."),
                    Line(mine: true, text: "첫 베타는 항목이 500개 미만인 워크스페이스로 제한할 수 있을까요?"),
                    Line(mine: false, text: "네, 그렇게 하고 첫 주 피드백을 본 뒤에 다시 검토하죠."),
                    Line(mine: false, text: "다음 주에 노스윈드와 짧은 사용성 테스트도 두 번 하고 싶습니다."),
                    Line(mine: false, text: "좋은 생각이에요. 지우 님, 일정을 잡아 주세요. 출시 주간 지원은 누가 맡을지 정해졌나요?"),
                    Line(mine: true, text: "아직요. 미정이라 지원팀과 얘기해야 합니다."),
                    Line(mine: false, text: "베타에 문제가 생길 때를 대비해 롤백 계획도 준비하겠습니다."),
                    Line(mine: false, text: "완벽해요. 여기서 마치겠습니다. 모두 감사합니다."),
                ],
                summary: "팀은 아틀라스 베타를 목요일에 테스터에게 배포하고 정식 출시를 28일로 유지하기로 합의했다. 동기화 서비스가 큰 워크스페이스에서 아직 시간 초과가 나므로 첫 베타는 작은 워크스페이스로 제한한다. 디자인은 수요일까지 온보딩의 빈 상태 화면을 넘기고, 다음 주에 노스윈드와 사용성 테스트를 두 번 진행할 예정이다.",
                topics: ["아틀라스 출시", "베타 배포", "동기화 서비스", "사용성 테스트"],
                decisions: [("베타는 목요일에 테스터에게 배포하고 정식 출시는 28일로 유지한다.", 4),
                            ("첫 베타는 항목이 500개 미만인 워크스페이스로 제한한다.", 8)],
                tasks: [SampleTask(text: "릴리스 노트를 작성해 노스윈드에 보내기", owner: 0, dueInDays: 2, segment: 5),
                        SampleTask(text: "온보딩 빈 상태 화면 전달하기", owner: 3, dueInDays: 1, segment: 3),
                        SampleTask(text: "노스윈드와 사용성 테스트 두 번 잡기", owner: 3, dueInDays: 7, segment: 10),
                        SampleTask(text: "베타 롤백 계획 준비하기", owner: 2, dueInDays: 3, segment: 12)],
                questions: ["출시 주간 지원은 누가 맡나요?", "큰 워크스페이스의 동기화 시간 초과는 어떻게 해결하나요?"],
                attendees: [1, 2, 3]),
            SampleMeeting(
                daysAgo: 1, hour: 16, minutes: 31, title: "대현 님과 1:1",
                lines: [
                    Line(mine: true, text: "지난 릴리스 이후 팀 분위기는 어떤가요?"),
                    Line(mine: false, text: "피곤하지만 만족하고 있어요. 베타 전에 모두에게 회복 휴무를 하루 주고 싶습니다."),
                    Line(mine: true, text: "좋아요. 계획을 보내 주시면 오늘 승인할게요."),
                    Line(mine: false, text: "그리고 밀린 버그를 줄이기 위해 분기마다 안정화 스프린트를 하자고 제안합니다."),
                ],
                summary: "대현 님이 베타 전에 팀에 회복 휴무를 하루 주는 것과, 밀린 버그를 줄이기 위한 분기별 안정화 스프린트를 제안했다.",
                topics: ["팀 컨디션", "안정화 스프린트"],
                decisions: [("베타 전에 팀에 회복 휴무를 하루 준다.", 2)],
                tasks: [SampleTask(text: "대현 님의 회복 휴무 계획 승인하기", owner: 0, dueInDays: 0, segment: 2)],
                questions: [], attendees: [2]),
            SampleMeeting(
                daysAgo: 4, hour: 11, minutes: 47, title: "노스윈드 킥오프 미팅",
                lines: [
                    Line(mine: true, text: "환영합니다. 파일럿 고객이 되어 주셔서 감사합니다. 계획을 설명드리겠습니다."),
                    Line(mine: false, text: "저희는 공유 워크스페이스와 감사 내보내기에 특히 관심이 있습니다."),
                    Line(mine: true, text: "둘 다 베타에 들어 있습니다. 서연 님이 이번 주에 테스트 계정을 공유할 거예요."),
                    Line(mine: false, text: "좋네요. 저희 팀은 다음 주 월요일부터 테스트를 시작할 수 있습니다."),
                ],
                summary: "노스윈드는 공유 워크스페이스와 감사 내보내기를 중심으로 아틀라스를 시범 사용한다. 테스트 계정은 이번 주에 공유되고 다음 주 월요일부터 테스트가 시작된다.",
                topics: ["노스윈드 파일럿", "공유 워크스페이스", "감사 내보내기"],
                decisions: [],
                tasks: [SampleTask(text: "노스윈드에 테스트 계정 공유하기", owner: 1, dueInDays: 3, segment: 2)],
                questions: ["파일럿 중에 노스윈드에 싱글 사인온이 필요한가요?"], attendees: [1]),
            SampleMeeting(
                daysAgo: 6, hour: 15, minutes: 38, title: "디자인 리뷰",
                lines: [
                    Line(mine: false, text: "새 온보딩 흐름입니다. 여섯 단계에서 네 단계로 줄였어요."),
                    Line(mine: true, text: "훨씬 명확하네요. 권한 단계는 마지막에 둘 수 있을까요?"),
                    Line(mine: false, text: "네, 파일럿 사용자에게는 그쪽이 결과가 더 좋았어요."),
                ],
                summary: "지우 님이 네 단계로 줄인 온보딩 흐름을 발표했다. 권한 단계는 결과가 더 좋았기 때문에 마지막에 둔다.",
                topics: ["온보딩 흐름", "권한"],
                decisions: [("온보딩에서 권한 단계는 마지막에 둔다.", 2)],
                tasks: [], questions: [], attendees: [3]),
        ],
        liveTranscript: [
            Line(mine: false, text: "그러니까 베타 빌드는 안정적이라 목요일에 배포할 수 있습니다."),
            Line(mine: true, text: "좋아요. 오늘 릴리스 노트를 쓰겠습니다."),
            Line(mine: false, text: "위험 요소는 큰 워크스페이스에서의 동기화 서비스입니다."),
        ],
        livePoints: ["베타 빌드가 안정적이다", "큰 워크스페이스에서 동기화 시간 초과가 난다"],
        liveDecisions: ["베타는 목요일에 테스터에게 배포한다"],
        liveTasks: ["릴리스 노트 작성 (나)"],
        askQuestion: "베타에 대해 무엇을 결정했나요?",
        askAnswer: "베타는 목요일에 항목 500개 미만의 워크스페이스로 제한해 테스터에게 배포하고, 정식 출시는 28일로 유지합니다.",
        askClaims: [("베타는 목요일에 테스터에게 배포하고 정식 출시는 28일로 유지합니다.", 4),
                    ("첫 베타는 항목이 500개 미만인 워크스페이스로 제한합니다.", 8)],
        notes: ["노스윈드에 싱글 사인온 확인하기", "릴리스 노트에 마이그레이션 항목이 필요함"],
        searchQuery: "베타")

    // MARK: Simplified Chinese

    static let simplifiedChinese = SampleContent(
        people: [
            Person(name: "我", note: "", aliases: []),
            Person(name: "陈思雨", note: "产品负责人", aliases: ["思雨"]),
            Person(name: "王大伟", note: "工程经理", aliases: ["大伟"]),
            Person(name: "林雅琪", note: "设计", aliases: ["雅琪"]),
        ],
        project: Person(name: "Atlas 发布", note: "28 日公开发布", aliases: ["Atlas"]),
        client: Person(name: "Northwind", note: "试点客户", aliases: []),
        glossary: [("SLA", "服务级别协议"), ("RC", "发布候选版本")],
        meetings: [
            SampleMeeting(
                daysAgo: 0, hour: 10, minutes: 24, title: "产品周会",
                lines: [
                    Line(mine: false, text: "感谢大家参加。先从 Atlas 的发布日期说起。大伟，测试版进展如何？"),
                    Line(mine: false, text: "测试版构建很稳定。昨天我们关闭了最后一个阻塞性缺陷，所以周四可以发给测试人员。"),
                    Line(mine: true, text: "太好了。雅琪，这个版本的引导页面准备好了吗？"),
                    Line(mine: false, text: "快好了。空状态页面还没做完，不过周三之前可以交付。"),
                    Line(mine: false, text: "那就定下来：测试版周四发给测试人员，公开发布仍然定在 28 日。"),
                    Line(mine: true, text: "同意。我来写发布说明，周四前发给 Northwind。"),
                    Line(mine: false, text: "有一个风险是同步服务。在大型工作区里它仍然会超时。"),
                    Line(mine: true, text: "第一个测试版能不能只限于项目少于五百个的工作区？"),
                    Line(mine: false, text: "可以，就这么做，等收到第一周的反馈后再重新评估。"),
                    Line(mine: false, text: "我还想下周和 Northwind 做两次简短的可用性测试。"),
                    Line(mine: false, text: "好主意。雅琪，请你安排一下。发布那周由谁负责支持，我们定了吗？"),
                    Line(mine: true, text: "还没有。这件事还没定，我们需要和支持团队谈谈。"),
                    Line(mine: false, text: "我也会准备一份回滚方案，以防测试版出问题。"),
                    Line(mine: false, text: "很好。今天就到这里。谢谢大家。"),
                ],
                summary: "团队同意周四把 Atlas 测试版发给测试人员，公开发布仍定在 28 日。由于同步服务在大型工作区里仍会超时，第一个测试版只限于小型工作区。设计团队将在周三前交付引导页面的空状态，下周计划与 Northwind 进行两次可用性测试。",
                topics: ["Atlas 发布", "测试版推出", "同步服务", "可用性测试"],
                decisions: [("测试版周四发给测试人员，公开发布仍定在 28 日。", 4),
                            ("第一个测试版只限于项目少于 500 个的工作区。", 8)],
                tasks: [SampleTask(text: "撰写发布说明并发给 Northwind", owner: 0, dueInDays: 2, segment: 5),
                        SampleTask(text: "交付引导页面的空状态", owner: 3, dueInDays: 1, segment: 3),
                        SampleTask(text: "与 Northwind 安排两次可用性测试", owner: 3, dueInDays: 7, segment: 10),
                        SampleTask(text: "为测试版准备回滚方案", owner: 2, dueInDays: 3, segment: 12)],
                questions: ["发布那周由谁负责支持？", "大型工作区的同步超时如何解决？"],
                attendees: [1, 2, 3]),
            SampleMeeting(
                daysAgo: 1, hour: 16, minutes: 31, title: "与大伟的一对一",
                lines: [
                    Line(mine: true, text: "上次发布之后，团队状态怎么样？"),
                    Line(mine: false, text: "有点累，但很满意。我想在测试版之前给大家放一天恢复假。"),
                    Line(mine: true, text: "没问题。把方案发给我，我今天就批准。"),
                    Line(mine: false, text: "另外我建议每季度做一次稳定性冲刺，来减少积压的缺陷。"),
                ],
                summary: "大伟提议在测试版之前给团队放一天恢复假，并每季度做一次稳定性冲刺来减少积压的缺陷。",
                topics: ["团队状态", "稳定性冲刺"],
                decisions: [("在测试版之前给团队放一天恢复假。", 2)],
                tasks: [SampleTask(text: "批准大伟的恢复假方案", owner: 0, dueInDays: 0, segment: 2)],
                questions: [], attendees: [2]),
            SampleMeeting(
                daysAgo: 4, hour: 11, minutes: 47, title: "Northwind 启动会",
                lines: [
                    Line(mine: true, text: "欢迎，也感谢你们成为我们的试点客户。我来介绍一下计划。"),
                    Line(mine: false, text: "我们最关心的是共享工作区和审计导出。"),
                    Line(mine: true, text: "这两项都在测试版里。思雨本周会分享测试账号。"),
                    Line(mine: false, text: "太好了，我们团队下周一就可以开始测试。"),
                ],
                summary: "Northwind 将试用 Atlas，重点关注共享工作区和审计导出。测试账号本周分享，下周一开始测试。",
                topics: ["Northwind 试点", "共享工作区", "审计导出"],
                decisions: [],
                tasks: [SampleTask(text: "与 Northwind 分享测试账号", owner: 1, dueInDays: 3, segment: 2)],
                questions: ["试点期间 Northwind 需要单点登录吗？"], attendees: [1]),
            SampleMeeting(
                daysAgo: 6, hour: 15, minutes: 38, title: "设计评审",
                lines: [
                    Line(mine: false, text: "这是新的引导流程，从六步缩短为四步。"),
                    Line(mine: true, text: "清晰多了。权限这一步可以放在最后吗？"),
                    Line(mine: false, text: "可以，试点用户的测试结果也是这样更好。"),
                ],
                summary: "雅琪展示了缩短为四步的引导流程。权限步骤放在最后，因为测试效果更好。",
                topics: ["引导流程", "权限"],
                decisions: [("引导流程中把权限步骤放在最后。", 2)],
                tasks: [], questions: [], attendees: [3]),
        ],
        liveTranscript: [
            Line(mine: false, text: "所以测试版构建很稳定，我们周四就可以发布。"),
            Line(mine: true, text: "太好了，我今天就写发布说明。"),
            Line(mine: false, text: "有一个风险是大型工作区里的同步服务。"),
        ],
        livePoints: ["测试版构建很稳定", "大型工作区里同步会超时"],
        liveDecisions: ["测试版周四发给测试人员"],
        liveTasks: ["撰写发布说明（我）"],
        askQuestion: "我们对测试版做了什么决定？",
        askAnswer: "测试版周四发给测试人员，限于项目少于 500 个的工作区，公开发布仍定在 28 日。",
        askClaims: [("测试版周四发给测试人员，公开发布仍定在 28 日。", 4),
                    ("第一个测试版只限于项目少于 500 个的工作区。", 8)],
        notes: ["向 Northwind 确认单点登录", "发布说明需要增加一小节迁移说明"],
        searchQuery: "测试版")
}
#endif
