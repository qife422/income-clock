---
title: 可视收入打卡机 Technical Design
document_type: tech_spec
version: "0.4"
status: review
last_updated: 2026-08-16
last_verified: null
approved_on: null
review_scope: "Technical 0.4 PD2RR follow-up repair candidate 完整文档 re-review"
historical_approved_version_record: "0.3（PD-001 批准事件仍有效；不可变内容快照缺失）"
proposed_supersedes_version: "0.3"
source_spec_version: "0.8"
source_ui_spec_version: "0.5"
review_method: "full_document_re_review"
candidate_snapshot_manifest: "contract_snapshots/2026-08-16-pd2rr-followup-repair-candidates/SHA256SUMS"
platform: "macOS 13+"
---

# 可视收入打卡机 — Technical Design

> `PD-001` 保留 Technical Design 0.3 曾获批准的历史事实，但项目没有该版本的不可变内容快照或可重放差异，不能证明 Technical 0.4 只包含 `PD-002` 增量。因此 Technical 0.4 必须作为完整文档重新审查；当前 follow-up repaired candidate 包含 S4R-003 发布硬门槛、“开始今天”全预计算/单原子提交协议、Settings missing/damaged 组合矩阵、跨日 clockOut 与冻结时区算法，状态仍为 `review`、`approved_on: null`，等待独立全文复审，不授权修改代码、进入 Stage 5 或发布。

## 1. 范围、来源与约束

### 1.1 唯一 Contract 来源

| 来源 | 本文引用范围 |
|---|---|
| `SPEC.md` 0.8 | 产品范围、七状态、DST v1、计薪公式、持久化、通知、窗口生命周期、S4R-003 延期、皮肤安全、能力协商和完成定义 |
| `UI_SPEC.md` 0.5 | standard panel/layout Profile、状态视图、DST v1 错误 UI、S4R-003 真实系统 UI 门槛、A/B Token 与资源、MenuBarExtra、设置窗口、无障碍和可观察 UI 验收 |

实现出现歧义时，先回到上述来源；技术层不能用“更容易实现”为理由改变业务或 UI Contract。本文不引入账号、服务端、网络同步、历史报表、未来 `shaped-panel` 或多个 `LayoutProfile`。

### 1.2 固定技术边界

- 原生 macOS 13+、Swift、SwiftUI 与必要 AppKit；不使用 Electron、Tauri、WidgetKit、WebView 或浏览器运行时。
- 首版一个应用进程，不增加 XPC 服务、登录辅助 App、Finder Extension 或网络服务。
- 首版只注册 `standard-theme@1`、`standard.panel.320x190.v1` 和 `standard.layout.income-card.v1`。
- A「暖屿」与 B「窗边搭子」共享同一 Profile、语义组件和命中区域。
- 窗口尺寸、布局、遮罩和 Theme Token 只能存在于 Presentation/Theme，不进入 Business Store、状态机或权威记录。

## 2. 工程与 App 生命周期

### 2.1 建议工程结构

首版创建一个 macOS App target；逻辑目录先保持单 target 边界，待规模或编译隔离确有需要时再拆本地 Swift Package。建议结构：

```text
IncomeClock/
├── App/                 # SwiftUI App、AppDelegate、依赖装配与生命周期
├── Domain/              # 值类型、七状态、计薪/状态纯函数、领域错误
├── Application/         # BusinessStore、用例、命令协调与只读 ViewState
├── Presentation/
│   ├── Panel/           # NSPanel bridge、standard layout 视图
│   ├── MenuBar/         # MenuBarExtra 内容
│   ├── Settings/        # 设置与皮肤管理窗口
│   └── Shared/          # 语义组件、格式化与无障碍适配
├── Infrastructure/
│   ├── Persistence/     # Codable 文件、迁移与原子写入
│   ├── Notifications/   # UNUserNotificationCenter adapter
│   ├── LoginItem/       # SMAppService adapter
│   ├── Clock/           # SystemClock 与 DebugClock
│   └── FileSystem/      # Application Support、临时目录与文件操作
├── Theme/               # Manifest、验证、Repository、Store、Profile registry
└── Resources/           # 内置 A/B Manifest、Token、预览和 Asset Catalog
```

未来测试 target 按 `DomainTests`、`ApplicationTests`、`InfrastructureTests`、`UITests` 分层；本轮不创建这些目录或 target。

### 2.2 启动顺序

1. SwiftUI `App` 创建唯一 `AppEnvironment`，注入 Clock、Repositories、NotificationScheduler、LoginItemService 和 ProfileRegistry。
2. `AppDelegate` 完成 AppKit 生命周期接入并创建单例 `PanelController`；面板内容由 `NSHostingController` 承载。
3. 并发读取设置、Theme 偏好和今日文件，但在 `BusinessStore` 的 MainActor 上按确定顺序提交恢复结果。
4. 今日记录校验完成前展示 `UI_SPEC.md` 16.1 loading；不能以 `¥0.00` 假装恢复完成。
5. `ThemeStore` 独立恢复；失败立即使用内置 A，不阻塞 BusinessStore 恢复。
6. 业务状态恢复后协调通知幂等状态，再按照已保存可见性和约束后位置显示或隐藏面板。

### 2.3 `LSUIElement` 与生命周期

- Info.plist 设置 `LSUIElement = true`，默认不显示 Dock 和应用切换器图标；该选择符合 `SPEC.md` 4.1。
- SwiftUI scenes 包含 `MenuBarExtra` 与 `Settings`；悬浮面板不使用 `WindowGroup`，由 `PanelController` 管理。
- `MenuBarExtra` 使用原生 menu 样式并严格映射 `UI_SPEC.md` 14 的顺序；不使用自绘 window-style 菜单或第二套状态机。设置使用独立 SwiftUI `Settings` scene。
- 菜单栏项是可靠主入口。移除或隐藏菜单栏项的用户能力不进入首版设置，避免失去显示面板、设置和退出入口。
- 面板关闭调用 `orderOut`，不销毁 store、不退出进程；明确的菜单“退出”才终止应用。
- `applicationShouldTerminateAfterLastWindowClosed` 返回 false；设置窗口关闭不影响业务生命周期。
- `NSWorkspace` 睡眠/唤醒、screen parameters、Space/active state 通知只触发重新推导和窗口约束，不累计工资。

## 3. 模块职责与依赖方向

| 模块 | 允许职责 | 禁止职责 |
|---|---|---|
| Domain | 金额/时间值类型、七状态、状态推导、计薪与舍入纯函数、校验规则 | SwiftUI/AppKit、文件、通知、Theme、窗口尺寸 |
| Application | 用例、命令幂等、持久化提交边界、只读 ViewState、跨服务协调 | 自行复制计薪公式、直接解压或绘制 UI |
| Presentation | 按 UI Spec 映射 ViewState、格式化、交互意图、窗口 bridge | 持久化、通知决策、从动画值计算工资 |
| Infrastructure | Clock、文件、通知、登录启动、系统 API adapter | UI 文案、Theme Token、状态机分支 |
| Theme | Token、资源、Profile registry、导入验证、安装、选择和回退 | 打卡命令、计薪、通知、工资设置、TodayRecord 修改 |

依赖方向：`Presentation → Application → Domain`；`Infrastructure` 实现 Application/Domain 声明的端口；Composition Root 负责注入。Theme 可读取 Application 的只读语义状态选择装饰，但 Application/Domain 不导入 Theme。

## 4. Domain 数据类型与计薪

### 4.1 权威类型

| 概念 | 类型选择 | 规则 |
|---|---|---|
| Unix 时间戳 | `Int64` 毫秒 | 持久化和纯函数边界统一；`Date` 只在系统 adapter 转换 |
| 日工资 | `Int64` cents | `DailyWageCents` 值类型，合法范围 1–99,999,999 |
| 计划/计薪时长 | `Int64` milliseconds | 所有减法使用检查运算，负值进入验证失败或按公式 clamp |
| 精确金额 | `RationalCents(numerator: Int64, denominator: Int64)` | 仅计算期存在，不持久化，不用二进制浮点 |
| 实时金额 | `Int64` milli-yuan | `LiveEarnedMilliYuan`，只供 EARNING 三位显示 |
| 结算金额 | `Int64` cents | `RoundedEarnedCents`，AWAITING/COMPLETED 两位显示 |
| 计划进度 | `Double` 0...1 | 仅 UI 派生值，不参与金额或持久化 |
| 工作日键 | `YYYY-MM-DD` 字符串值类型 | 由当天快照时区和 Calendar 生成并严格校验 |

在 Spec 最大工资与单日时长内，`dailyWageCents × 10 × earnedDurationMs` 可安全放入 `Int64`；实现仍必须使用溢出检查，任何溢出 fail closed 为数据/计算错误。

### 4.2 纯函数边界

`EarningsCalculator` 接受已验证的 `dailyWageCents`、`scheduledStartAtMs`、`scheduledEndAtMs`、`clockInAtMs`、可选 `clockOutAtMs` 与 `nowMs`，返回：

- effective start/end；
- `earnedDurationMs`；
- 精确 cents 有理数；
- half-up 后的 `liveEarnedMilliYuan`；
- half-up 后的 `roundedEarnedCents`；
- scheduled progress 与倒计时。

舍入使用整数商与余数实现普通 half-up：实时和最终分别直接从各自的权威分子/分母舍入。不得先舍入三位再计算两位；不得使用 `Double`、动画值、Timer 次数或帧数计算金额。

### 4.3 Clock/NowProvider

- `NowProvider` 是同步、`Sendable` 的只读端口，只返回当前 Unix 毫秒。
- `SystemClock` 是 Release 唯一实现，读取系统 `Date.now`。
- `FixedClock`、`AdvancingClock` 只用于测试与 DEBUG；它们不进入 Release 依赖装配。
- 一个用户命令只采样一次 command timestamp；一次 ViewState 推导也只采样一次，防止同一 transaction 内跨毫秒产生状态/金额不一致。
- `BusinessCommandContext` 在命令入口原子采样 `timestampMs` 和当时系统 `timeZoneIdentifier`，并立即构造 `commandDateKey`。命令内部所有 resolver、状态推导、错误、提交和 ViewState 只能读该不可变 context，不得二次读取 Clock/TimeZone。

### 4.4 LocalScheduleResolver 与 DST v1

- 新建纯、可测试的 `LocalScheduleResolver`（或等效 Domain/Application service），输入 dateKey、timeZoneIdentifier、start/end minute-of-day，输出唯一的 `WorkdaySchedule` 或结构化 `ScheduleTimeError`。
- 对每个墙上时间枚举与指定日期组件完全匹配的候选瞬间，并回转校验 year/month/day/hour/minute 与时区。候选为 0 时返回 `nonexistentLocalTime`；候选多于 1 时返回 `ambiguousLocalTime`；只有恰好 1 个候选才可使用。
- 不得只依赖 `Calendar.date(from:)` 的默认归一化，也不得以 `nextDate` 的宽松 matching policy、默认 repeated-time policy、固定加减一小时或“较早/较晚”偏好消除 gap/fold。
- start/end 均唯一后仍须验证 end > start、同一自然日边界与既有 Domain 约束。任何失败均 fail closed。
- 已通过严格唯一解析与一致性校验的 Today 使用持久化 `scheduledStartAtMs` / `scheduledEndAtMs` 作为权威边界。只有创建新工作日，或经单独 Contract 批准、确实缺少持久化边界的 legacy migration，才能从墙上时间调用 resolver；普通 Today restore 不重建边界。存在有效 Today 时，当天推导读取其 snapshot；当前 Settings 只代表后续工作日，不得覆盖该 snapshot。
- 已存在 Today 的恢复校验不用当前系统时区或新的 gap/fold 枚举重建边界；它仅验证持久化瞬间在 snapshot timezone 中 round-trip 到相同 `dateKey` 和墙上分钟，且 `scheduledEndAtMs > scheduledStartAtMs`。系统或 tzdb 变化不得重新解释已冻结 Today。

### 4.5 冻结日期关系与跨日 clockOut 验证

- 对已存在 Today，`RecordDateContext` 使用 `BusinessCommandContext.timestampMs` 与 `Today.settingsSnapshot.timeZoneIdentifier` 生成 `recordCurrentDateKey`。状态机只比较 `Today.dateKey` 与该键：`<` 为旧日流程，`=` 为当日流程，`>` 为 `.futureDatedTodayRecord` Recovery。
- 新工作日目标另外使用 command timezone 的 `commandDateKey`。东/西时区切换可使两个 date key 不同，但不得改变旧 Today 的关系判定。“开始今天”同时要求 `Today.dateKey < recordCurrentDateKey` 和 `Today.dateKey < commandDateKey`；后者不成立返回 `WorkdayTransitionError.targetDateNotAfterPreviousDate`。
- Today 的 `clockInAtMs` 必须在 snapshot timezone 中属于 `dateKey` 自然日，且 `clockInAtMs <= scheduledEndAtMs`。`clockOutAtMs` 若存在，唯一时序约束为 `clockOutAtMs >= clockInAtMs`；不要求它属于 Today 自然日，不与当前 now 比较，不设最大跨日数。
- 因此次日、多日后或系统时钟回拨后恢复的 clock-out 只要满足上述顺序就合法；`EarningsCalculator` 始终以 `min(clockOutAtMs, scheduledEndAtMs)` 截止计薪。

## 5. 七状态与转换映射

领域状态不直接持久化；它由有效 Settings、TodayRecord 与单次 `nowMs` 纯推导。确认页、loading、toast 等是 Presentation transient state，不增加第八个业务状态。

| 当前状态/事件 | Application 行为 | 成功后的领域状态 |
|---|---|---|
| Settings `.missing` 且无有效 Today | 不推导收入 | `UNCONFIGURED` |
| `UNCONFIGURED` / 保存设置 | 先以 command now 的当前日期/时区严格解析 proposed schedule；唯一有效后才原子写 Settings 并重推导 | `READY` |
| `READY` / 上班打卡 | 采样 now、冻结 snapshot、原子写 Today | 提前为 `CLOCKED_IN_WAITING`，否则 `EARNING`；下班后拒绝 |
| `CLOCKED_IN_WAITING` / 时间到 | 无写入，按 now 重推导 | `EARNING` |
| `CLOCKED_IN_WAITING` 或 `EARNING` / 取消下班 | 不写入 | 原状态 |
| `CLOCKED_IN_WAITING` 或 `EARNING` / 确认下班 | 重新采样 now，原子写 clockOutAt | `COMPLETED` |
| `EARNING` / 到 scheduledEnd | 无需靠 Timer 提交；重推导 | `AWAITING_CLOCK_OUT` |
| `AWAITING_CLOCK_OUT` / 下班打卡 | 记录真实操作时间并原子写 | `COMPLETED` |
| 任意可读 Today / 校验失败 | 保留原始数据、停计薪 | `RECOVERY_REQUIRED` |
| `RECOVERY_REQUIRED` / 确认重置 | 只删除 Today，成功后按 Settings typed result 重推导 | valid + 当前日程唯一为 `READY`；missing 为 `UNCONFIGURED`；damaged 为 Settings recovery；日程失败为 `ScheduleTimeError` |
| 有效未完成 Today / 跨入新自然日、次日启动或唤醒 | 保留 Today，继续使用冻结 snapshot；禁止创建新日 Today | 旧工作日 `AWAITING_CLOCK_OUT` |
| 旧工作日 `AWAITING_CLOCK_OUT` / 下班打卡 | 记录真实操作时间并原子写入旧 Today；计薪截止仍为旧 scheduledEnd | 旧工作日 `COMPLETED` |
| 旧工作日 `COMPLETED` / 用户确认“开始今天” | 执行第 5.1 节全预计算；任一失败零写入并保留旧 Today；成功后仅在单一 CAS 提交中清理旧 Today 并发布预计算目标 | Settings valid 为预计算 `READY`；missing 为 `UNCONFIGURED`；damaged/日程错误无转换 |

当前日程时间不存在或 ambiguous 时不进入上表任何状态。普通 restore 无可用 Today 时，BusinessStore 发布独立 `ScheduleTimeErrorViewState`，保持 `BusinessViewState == nil`。“开始今天” preflight 中同类错误则保留并继续发布旧 `COMPLETED` ViewState，同时附命令错误；两种路径都不发布目标新日 ViewState/success，也不扩充 `WorkdayState` 枚举。

旧工作日流程复用既有 `AWAITING_CLOCK_OUT`/`COMPLETED`，但 ViewState 必须携带权威 `dateKey`、snapshot timezone、“是否为旧工作日”与真实 clock-out 日期/时间语义。旧日记录存在时，新日 clock-in command 必须 fail closed；次日或多日后的 clock-out 仍写回该旧 Today，不得因 clockOut date 不等于 dateKey 进入 Recovery。

### 5.1 `StartTodayPlan` 全预计算与单一原子提交

`startToday` 必须是专用 Application command，不得复用“先 `resetToday()` 再 `reconcile()`”的两步流程。算法顺序固定为：

```text
context = sampleBusinessCommandContextOnce()
todayLoad = loadAndValidateTodayWithoutMutation()
settingsLoad = classifySettingsWithoutMutation() // missing | valid | damaged

require todayLoad.valid && todayLoad.completed
recordCurrentDateKey = dateKey(context.timestamp, today.snapshot.timeZone)
require today.dateKey < recordCurrentDateKey
require today.dateKey < context.commandDateKey
require settingsLoad != damaged

target = switch settingsLoad:
  missing -> resolveCurrentWorkday(context.commandDateKey)
             record scheduleResolution = notApplicable(settingsMissing)
             fullyConstructUnconfiguredTarget(context)
  valid   -> resolveCurrentWorkdayAndScheduleStrictly(context, settings)
             // includes gap/fold checks, then fully constructs READY target

plan = StartTodayPlan(
  context, target,
  expectedTodayRevision: today.revision,
  expectedSettingsToken: settingsLoad.revisionOrMissingToken
)

committed = commitStartToday(plan) // one repository-actor atomic CAS/delete linearization point; returns target
publishCommitted(committed.target) // same MainActor command turn; only after commit succeeds
```

- 从采样 context 到 `StartTodayPlan` 完整构造期间不允许任何 record 删除、替换、临时写入、revision 推进或 ViewState 切换。
- Settings damaged 返回 `SettingsReadError`；日程 gap/fold 返回 `ScheduleTimeError`；旧 Today 未完成或日期不合格返回 `WorkdayTransitionError`。任一错误都保留旧 Today bytes/revision、旧 `COMPLETED`/`AWAITING_CLOCK_OUT` ViewState 和可重试 UI，无部分写入。
- `commitStartToday` 在同一 repository actor 临界区内同时校验 expected Today revision 和 Settings revision/missing token。任一不匹配返回 `RevisionConflict`，不删除 Today。只有两者匹配才以删除已完成旧 Today 为唯一持久化线性化点，并把预构造 target 作为同一个 committed result 返回；提交后不再读 Clock/TimeZone 或首次解析日程。
- Application command 在同一 MainActor command turn 中消费 committed result 并发布其 target；该 command 对持久化和观察者表现为一次外部原子状态切换。提交前的失败保持 old Today/old ViewState，提交成功后的恢复只能得到 plan 所代表的 Today-missing + Settings-token 对应状态；观察者不得看到“old Today 已清理但 target 尚未构造/未知”的中间状态。
- 旧 Today `clockOutAt == nil` 时 `startToday` 一律拒绝；不存在以 Settings 结构合法为理由直接删除旧 Today 的分支。

### 5.2 Settings/Today typed load 矩阵与恢复优先级

`RecordRepository` 必须为 Settings 返回互斥的 `.missing(missingToken)`、`.loaded(record, revision)` 或 `.damaged(SettingsReadError, damageToken)`。只有文件不存在是 missing；读取、envelope、decode、schema、validation 或 migration 失败都是 damaged。

| Settings | Today | `BusinessViewState` | 独立错误/恢复 |
|---|---|---|---|
| missing | missing | `.unconfigured` + rounded zero | 无 Settings error |
| missing | valid | 从 Today snapshot 推导 | 新日需先配置 |
| damaged | missing | `nil` | blocking `SettingsReadErrorViewState` |
| damaged | valid | 从 Today snapshot 推导状态/金额 | non-blocking `SettingsReadErrorViewState`；依赖 Settings 的新日命令 disabled |
| missing/valid | damaged | `.recoveryRequired`，amount hidden | Today Recovery |
| damaged | damaged | `.recoveryRequired`，amount hidden | Today Recovery 主错误 + SettingsReadError 次错误 |

- `resetDamagedSettingsToMissing(expectedDamageToken)` 是专用原子命令，只隔离/删除 Settings，不读写 Today。成功后若有效 Today 存在，重发布其 snapshot 业务状态；若 Today missing，发布 `.unconfigured`；若 Today damaged，继续 `.recoveryRequired`。
- `replaceDamagedSettings(proposed, expectedDamageToken, context)` 先在任何写入前严格验证 proposed 及 command date/timezone 的 gap/fold，再原子替换 Settings。有效 Today 存在时，不使用新 Settings 重解释 Today；Today missing 时只有解析与写入都成功才发布 `.ready`；Today damaged 时继续 `.recoveryRequired`。
- `resetToday` 只删除 Today。提交后 Settings loaded 则用同一 command context 严格解析并发布 `.ready` 或 `ScheduleTimeError`；Settings missing 发布 `.unconfigured`；Settings damaged 发布 blocking Settings recovery。
- 双 damaged 的顺序是确定的：先 reset Today → Settings recovery；先 reset Settings → Today Recovery；先 replace Settings → Today Recovery。每个 CAS 失败都保持两个原文件和原错误优先级，不得由 Presentation 推测转移。

菜单栏和面板只发送同一 `BusinessCommand`。`BusinessStore` 在 MainActor 内设置 command-in-flight，并由 Repository revision compare-and-swap 形成第二层幂等保护；重复点击只允许一个提交。

## 6. Application Store、共享状态与并发

### 6.1 BusinessStore

- `@MainActor` 单实例，持有不可变 `BusinessViewState`、transient feedback 和 command-in-flight 标记。
- 只通过 Use Case 调用 actor repositories；不直接调用 FileManager、UNUserNotificationCenter 或 ThemeStore。
- 悬浮面板、MenuBarExtra、设置窗口通过 Environment 注入同一实例，消费同一 ViewState 和命令接口。
- 所有系统回调在提交 UI 前 hop 到 MainActor；陈旧异步结果带 revision/token，不能覆盖较新状态。
- restore/refresh/reconcile 必须返回 typed result；`ScheduleTimeError` 不得被吞掉、误标为某个 BusinessCommand 失败或以旧/nil ViewState 留在 loading。错误发生后仅允许安全读取、打开设置和提交新的工作时间；重试仍走同一 command-in-flight/revision 边界。
- `saveSettings` 在调用 Repository 前用该命令唯一采样的 now 解析 proposed schedule；失败直接返回 validation failure，Settings bytes/revision、内存 record、BusinessViewState 和 success feedback 均保持不变。
- Repository commit 成功后的 ViewState 推导若失败，命令不得发布 `.settingsSaved` 或其他 success；必须返回 typed failure 并保留可恢复错误表面。该规则不授权在本次 Contract Update 中修改实现。
- restore/refresh/reconcile 发现旧日有效 Today 时不得按日期直接删除：未完成记录恢复为旧日 AWAITING；已完成记录保留到用户确认“开始今天”。跨日清理与当前日期 clock-in 必须共享 command-in-flight/revision 边界。
- `startToday` 必须实现第 5.1 节 `StartTodayPlan`，不得先调用 Today delete/reset 再执行 reconcile/resolver。预计算期间发生 `ScheduleTimeError`、`SettingsReadError`、`WorkdayTransitionError` 或目标构造错误时，必须保留旧 Today 和旧 ViewState，只发布命令级 typed error。
- Settings load 返回 damaged 时发布独立 `SettingsReadErrorViewState`。没有有效 Today 时保持 `BusinessViewState == nil`；有有效 Today 时继续发布其业务 ViewState，并并行保留非阻塞 Settings 错误；Today 也 damaged 时以 Recovery ViewState 为主错误并附 Settings 次错误。任何路径都不得合成普通 `UNCONFIGURED`、`READY` 或 `¥0.00`。
- `resetDamagedSettingsToMissing`、`replaceDamagedSettings` 与 `resetToday` 必须由 Store 依第 5.2 节的确定矩阵发布结果；Presentation 不得在成功 callback 中无条件设置 `.ready`。

### 6.2 ThemeStore

- `@MainActor` 单实例，持有当前已验证 Theme、外观、导入任务摘要和非阻塞回退提示。
- 依赖 `ThemeRepository`、`ThemeValidator` 与 ProfileRegistry；不依赖 BusinessStore。
- Presentation 同时读取 BusinessViewState 与 ThemeViewState 组合渲染；ThemeStore 最多接收只读 `BusinessSemanticState` 选择 `stateDecoration`。
- 切换 Theme 只写 ThemePreferencesRecord；不能触发 BusinessCommand 或修改 Settings/Today。

### 6.3 Actor 隔离

| Actor/MainActor | 负责内容 |
|---|---|
| MainActor | BusinessStore、ThemeStore、PanelController、SwiftUI ViewState、预览最终渲染 |
| `RecordRepositoryActor` | 三类 record 的读取、迁移、revision 检查和串行原子写 |
| `ThemeRepositoryActor` | 用户皮肤目录、安装替换、删除和完整性清单 |
| `ThemeValidationTask` | ZIP 枚举、解压、JSON、媒体和哈希；后台 cooperative cancellation |
| `NotificationSchedulerActor` | 权限、pending request 查询、安排与取消顺序 |

导入取消以 Task cancellation + 每条目/每块数据检查实现；进入原子替换临界区后不响应 UI 取消。应用退出时未提交 staging 可删除，已提交目录必须完整。

## 7. Codable schema、迁移与原子写入

### 7.1 SettingsRecord v1

| 字段 | 类型/说明 |
|---|---|
| `schemaVersion` | 整数 1 |
| `revision` | 单调递增 UInt64 的 JSON 安全表示 |
| `dailyWageCents` | Int64 |
| `workStartMinuteOfDay` / `workEndMinuteOfDay` | 0...1439，end > start |
| `notificationsEnabled` | Bool |
| `alwaysOnTop` / `lockPanelPosition` / `hideInFullScreen` | Bool |
| `launchAtLogin` / `panelVisible` | Bool；前者是最后成功确认的系统状态 |
| `panelPlacement` | display UUID、snap corner、x/y offset、约束后的 frame |
| `updatedAtMs` | Int64，诊断用途，不参与计薪 |

record-level `validated()` 继续验证跨日期稳定的 schema/range；与“当前日期 + 当前时区”有关的 DST 唯一性由 `LocalScheduleResolver` 在 BusinessStore 保存前和日程推导时验证，不能靠 Repository 写入后补救。

### 7.2 TodayRecord v1

| 字段 | 类型/说明 |
|---|---|
| `schemaVersion` / `revision` | 1 / 单调 revision |
| `dateKey` | 严格本地工作日键 |
| `clockInAtMs` | Int64 |
| `clockOutAtMs` | 可选 Int64 |
| `settingsSnapshot` | wage cents、start/end minute、currency CNY、timeZoneIdentifier |
| `scheduledStartAtMs` / `scheduledEndAtMs` | 从 snapshot 构造并保存的确定性边界 |
| `notificationScheduledDateKey` | 可选工作日键 |
| `notificationRequestIdentifier` | 可选稳定 ID |
| `updatedAtMs` | Int64，诊断用途 |

保存计划边界和时区是对 Spec 最小 snapshot 的实现补充，用于系统时区变化后仍可重复结算；它不改变用户规则。

当天已有有效 Today 时，修改工资或时间只原子写新的 SettingsRecord；当前状态、计薪、结算和通知继续读取 Today 的 settingsSnapshot 与计划边界。Today 不持久化显示帧、实时三位值或最终金额，恢复和结算始终从权威字段重算。

Today validation 的可执行时间边界固定为：

1. `dateKey` 与 snapshot timezone 结构有效；持久化 scheduled instants 在该时区 round-trip 到相同 dateKey/start/end minute，且 end > start。
2. `clockInAtMs` 属于 snapshot timezone 中 dateKey 的 `[dayStart, nextDayStart)`，且 `clockInAtMs <= scheduledEndAtMs`。
3. `clockOutAtMs == nil || clockOutAtMs >= clockInAtMs`。不检查 clock-out 是否小于 `nextDayStart`、是否不晚于恢复 now，也不检查最大跨日天数。

这三条替代所有“时间戳属于合理工作日范围”的实现自由。

### 7.3 ThemePreferencesRecord v1

| 字段 | 类型/说明 |
|---|---|
| `schemaVersion` / `revision` | 1 / 单调 revision |
| `selectedThemeId` | 稳定 themeId |
| `preferredThemeAppearance` | system/light/dark |
| `themeSoundsEnabled` | Bool，默认 false |
| `updatedAtMs` | Int64 |

### 7.4 迁移策略

- 解码先读取轻量 envelope 的 schemaVersion，再选择明确 migrator；禁止“尽力猜字段”。
- 当前只实现 v1 reader/writer 和 migration protocol/fixture 边界；未知未来版本 fail closed。
- Today 未知/损坏进入 `RECOVERY_REQUIRED`，不自动改写。
- Settings 损坏时不展示为有效或 missing，也不进入普通 `UNCONFIGURED`/`READY`。Repository 返回带诊断与 damage token 的 damaged result，原文件保留；无有效 Today 时 BusinessStore 发布独立 blocking `SettingsReadErrorViewState` 且业务 ViewState 为 nil，有有效 Today 时继续使用冻结 snapshot 并附非阻塞错误，Today 也 damaged 时按 5.2 保留主/次错误。用户只能通过明确替换或重置 Settings 命令改变该结果，且两者都不触碰 Today。
- ThemePreferences 损坏时运行时使用 A + system + sounds off；保留损坏文件并显示 Theme 非阻塞原因，用户下一次明确保存偏好时先保存诊断副本再替换。
- 迁移必须纯转换、可重复；成功写回前保留旧文件，失败不部分升级。

### 7.5 原子写入

每类 record 独立使用完整 next-state 文件：规范化编码 → 同目录唯一临时文件 → flush/close → 原子 replace/rename → 更新内存 revision。写入由 actor 串行化，预期 revision 不匹配时拒绝陈旧提交。

- 上班、下班、设置和 Theme 选择只有原子写成功后才发布成功 ViewState。
- Settings 的 DST v1 校验位于 Repository 调用之前；校验失败不得创建临时文件、写 record、推进 revision 或发布 success。
- 不对 JSON 做字段级原地修改。
- Today 删除也在 actor 内串行；删除失败保持原状态。
- `commitStartToday(plan)` 是唯一允许清理有效已完成旧 Today 的 API。它在一个 actor 临界区内同时核对 Today revision 与 Settings loaded/missing token，再以单一原子 delete/rename 提交；不接受未构造完整 target 的调用。任一冲突或 I/O 失败不修改 Today、Settings 或内存 revision。
- 通知与本地文件无法形成跨系统事务，按第 11 节补偿协议处理。

## 8. Application Support 与恢复

推荐目录：

```text
~/Library/Application Support/<bundle-id>/
├── Records/
│   ├── settings.json
│   ├── today.json
│   └── theme-preferences.json
├── Themes/<themeId>/             # 用户已安装皮肤
├── Staging/import-<UUID>/        # 同卷临时验证与安装
└── Diagnostics/Corrupt/          # 用户动作前保存的可选诊断副本
```

- 内置 A/B 不复制到 Application Support；它们始终从签名 App bundle 加载。
- 路径通过 `FileManager.url(for: .applicationSupportDirectory, ...)` 和 bundle ID 构造，不拼接用户绝对路径。
- Staging 与 Themes 位于同一 Application Support 卷，确保最终 rename/replace 原子。
- 启动时删除不属于活跃验证任务且超过安全期限的 staging；不得删除 Themes、Records 或未知用户文件。
- Today 损坏时原文件留在原位直至用户确认重置；UI 不展示其中金额。
- 皮肤损坏只禁用该皮肤并回退 A，不进入业务 Recovery。
- 日期变化本身不允许删除 Today。有效未完成旧日 Today 必须保留到完成下班；有效已完成旧日 Today 必须保留到用户确认“开始今天”。只有该确认命令可以原子删除旧 Today；损坏、日期无法验证或未完成的记录不得走此清理路径。
- 启动/唤醒/跨日/时区变化后，只采样一个 restore timestamp 与系统时区，按第 4.5 节生成 command/record 两个 date key，再按第 5.2 节矩阵选择来源。有效 Today 使用其冻结 snapshot/瞬间，不用新系统时区重建；无有效 Today 时才使用 Settings loaded 与 command timezone 严格解析。Settings/Today 的 missing/damaged 组合按矩阵发布；所选新日来源不能唯一解析时，保留原始 bytes，结束 restoring 并发布 typed `ScheduleTimeError`，不得自动修正、删除、迁移或覆盖 record。
- Settings recovery surface 必须允许在没有 BusinessViewState 时提交新的工资/时间设置或明确重置为 missing；新值先用单一 command context 执行 DST 严格校验，通过后才调用 Repository。成功 commit 后按 5.2 矩阵重新推导；任一失败仍保留对应原文件/错误表面且不发布 success。

## 9. NSPanel、SwiftUI 与多显示器

### 9.1 Bridge

- `IncomePanel` 是 `NSPanel` 子类或集中配置工厂，内容为 `NSHostingController<PanelRootView>`。
- 首版固定 standard Profile，PanelController 从 ProfileRegistry 读取内容尺寸和命中定义；不能在 BusinessStore 写 `320 × 190`。
- PanelController 负责 styleMask、level、collectionBehavior、透明背景、阴影、close→hide、key status 和拖动；SwiftUI 负责内容与控件。
- 默认不激活应用、不抢焦点；用户点击控件或快捷键明确聚焦时才允许 key interaction。
- 同一 panel 实例复用；Theme 切换只更新环境，不重建 BusinessStore 或窗口位置。

### 9.2 位置与屏幕身份

- 使用 `CGDirectDisplayID` 对应的稳定 display UUID 保存屏幕身份，不能依赖 `NSScreen` 数组序号。
- 保存 snap corner、相对 visibleFrame offset 和最后约束 frame；恢复优先同 UUID，缺失则主屏右下角。
- 所有恢复、拖动结束、screen parameter/Dock 变化均通过 `PanelPlacementController` 重新 clamp 到 `visibleFrame`。
- 拖动结束计算当前屏幕最近角并吸附；锁定仅禁止拖动。
- level、Space 和全屏可见性只读取 Settings，不读取 Theme/Profile 视觉 Token。
- 位置算法以 Profile 的外部 presentation bounds 为输入，为未来 Profile 留接口，但首版 registry 只有 standard。

## 10. Timeline、动画与后台暂停

### 10.1 推荐实现

首版推荐 SwiftUI `TimelineView(.animation)` 驱动可见 EARNING 视图，原因是与 SwiftUI 渲染树、Reduce Motion 和可见性控制集成简单。若技术 spike 证明 macOS 13 下刷新/暂停不稳定，再把触发器替换为封装的 DisplayLink provider；二者必须实现同一个 `RenderPulseSource`，不得影响 Domain。

### 10.2 职责

- pulse 只通知 View 重新向 BusinessStore/Calculator 请求一次当前快照；权威 now 来自 NowProvider。
- 只有 panel visible、EARNING、应用可见策略允许且非休眠时启用高频 pulse。
- 数值只有跨越真实 0.001 元边界时触发 odometer 目标变化；帧率不写入业务状态。
- MenuBarExtra 不使用高频 timeline；打开菜单或状态事件时获取最新快照。
- 后台、隐藏、睡眠和 inactive 可暂停 pulse。恢复时直接计算当前值；跨过 scheduledEndAt 直接显示 AWAITING，不补播。
- 主动下班提交成功或到点后立即取消 EARNING 动画任务，最终两位金额重新走 Domain 计算。

## 11. 通知、登录启动与幂等恢复

### 11.1 UNUserNotificationCenter

`NotificationSchedulerActor` 封装权限、pending request、add 和 remove。稳定 request ID 为 `workday-end-<dateKey>`。

安排协议：

1. 仅明确开启通知的用户操作请求权限；普通启动/打卡不弹权限。
2. 从 Today snapshot 得到 trigger；scheduledEnd 已过则不安排。
3. 查询 pending requests；已有稳定 ID 视为幂等成功。
4. 没有则 add 同 ID 请求；add 成功后再次查询确认。
5. 确认成功后原子写 Today 的通知标记；若写标记失败，保留系统请求，恢复时先查询再补写，不能再创建第二个 ID。
6. 主动提前完成后 remove 同 ID，再查询；取消失败记录诊断但不改变完成状态。

通知失败永远不阻止应用内 AWAITING 提醒、计薪停止或下班打卡。实现依据 Apple `UNUserNotificationCenter` 的 pending request 与 identifier API，不承诺准点或必达。

### 11.2 登录启动

- macOS 13+ 使用 `SMAppService.mainApp.register()` / `unregister()`；不创建独立 helper。
- toggle 显示系统实际 status，而不是只读 Settings 布尔值；系统调用成功并复查状态后才写 Settings。
- denied/requiresApproval 时保持原最终状态，提供打开系统“登录项”设置入口和可理解错误。
- DEBUG 与 UITest 可注入 fake LoginItemService，不触碰系统登录项。

## 12. Theme 架构与内置资源

### 12.1 组件

| 组件 | 职责 |
|---|---|
| `ThemeRepository` | 枚举内置/用户皮肤、读取安装清单、原子安装/替换/删除、完整性哈希 |
| `ThemeValidator` | Manifest、能力、路径、Token、媒体、安全和预览质量验证 |
| `ThemeStore` | 当前 Theme/appearance、切换、回退、导入进度和非阻塞错误 |
| `ProfileRegistry` | 注册应用所有 Profile ID，并解析 capability/version；首版只含 standard IDs |
| `ThemeResolver` | 将规范化 Token、系统无障碍设置与安全 fallback 合并为只读 RenderTheme |

ThemeValidator 输出不可变 `ValidatedThemePackage`；未验证 URL/Manifest 不能进入 ThemeStore。ProfileRegistry 不允许皮肤动态注册 Profile 或控件树。

### 12.2 A/B 打包

- A/B 的 Manifest、Token JSON、license/source 和预览放入签名应用资源目录 `BuiltinThemes/<themeId>/`。
- A 的系统颜色/材质默认值仍由内置 Manifest 声明；默认皮肤不依赖外部文件或网络。
- B 的 20 张状态 PNG 导入 Asset Catalog，以 light/dark 与 scale 变体组成五个语义 image set；Manifest 使用内部资源键映射，不暴露任意 bundle 路径。
- 构建期脚本或测试核对 `UI_SPEC.md` 11.5 的文件哈希与 Asset Catalog 输入；哈希不参与业务。
- 内置 Theme ID 属于保留命名空间，ThemeRepository 不提供删除或覆盖命令。

## 13. `.incomeclocktheme` ZIP 方案

### 13.1 选项与结论

| 选项 | 优点 | 风险/限制 | 结论 |
|---|---|---|---|
| ZIPFoundation（Swift Package） | 可枚举 entry、流式读取、进度/取消；Apple 平台无额外传递依赖 | 第三方供应链；历史上出现过 symlink traversal，不能信任默认解压安全 | **推荐**，但只作低层 ZIP reader，精确锁版本并由应用预验证每个 entry |
| 自研 ZIP parser + Compression | 无第三方包 | ZIP 格式边界复杂，首版审计和测试成本高，容易遗漏攻击面 | 不推荐；作为长期替代方案 |
| 调用 `/usr/bin/ditto`/Archive Utility | 无 Swift 包 | 子进程、输出与安全策略不可控，难在落盘前逐 entry 验证 | 拒绝用于不可信导入 |

推荐并决定首版采用 ZIPFoundation `0.9.20`，在 Swift Package 配置与 `Package.resolved` 中精确锁定 revision `22787ff`；禁止 `.upToNextMajor` 自动漂移。0.9.20 修复了 `Archive.makeBackingConfiguration` 的资源泄漏、`Data.readChunk` 的内存泄漏，以及 Debug 模式的内存对齐崩溃；其安全基线同时包含 0.9.18 已加入的路径逃逸修复和符号链接约束。记录 MIT license 和安全复核日期。真正加入依赖前必须复核公开安全问题；若发现未缓解的高风险问题，必须回到本文重新评审版本或切换替代方案，不得静默漂移。本轮不安装依赖。

ZIPFoundation 只作为底层 ZIP entry reader，不是安全边界。禁止直接对不可信皮肤包使用高层整包 `unzipItem`。应用必须自行枚举中央目录和 entry metadata，验证路径、链接、声明容量与实际流式字节，并逐 entry 写入受控 staging；图片、声音和 staging 完整性仍由第 13.2 节的应用验证流水线负责。

### 13.2 安全验证顺序

1. 文件选择/拖放获得 security-scoped URL，只读复制到应用 Staging；复制完成后停止访问原 URL。
2. 检查扩展名、ZIP magic、压缩包 50 MiB、entry 数 256、声明解压总量 100 MiB、单文件 20 MiB 和支持的压缩方法；拒绝加密、多卷和嵌套归档。
3. 对所有 entry 路径执行 UTF-8、NFC、分隔符统一和 case-fold collision 检查；拒绝空路径、NUL、绝对路径、drive/UNC、`..`、staging 根外 canonical URL。
4. 从 ZIP external attributes 与 entry type 拒绝 symlink、hardlink、device、FIFO、socket 和可执行类型；目录与普通文件之外一律拒绝。
5. 在内存中读取且限制 `manifest.json` 256 KiB，执行严格 schema、未知字段、ID、版本、capability/Profile 与 remote URL/代码字段验证。
6. 建立所有引用资源白名单；未知危险扩展或未引用非媒体文件拒绝。允许的 manifest/preview/assets/sounds 之外不执行内容。
7. 为每个普通文件创建 staging 内目标：重新 canonicalize parent，禁止跟随 symlink，以独占创建逐块写入；同时计数实际 bytes，超过单项或累计上限立即取消并清理。
8. 写入后重新遍历 staging，拒绝任何 link、权限异常、路径变化或未预期文件；核对逐文件 SHA-256 和实际大小。
9. 图片先检查真实签名，再用 ImageIO 读取属性并完整解码；限制单边 4096 px、16 MP、格式 PNG/JPEG/HEIC、色彩空间和解码预算。仅扩展名正确不算通过。
10. 声音先检查真实容器，再用 AVFoundation 完整解析时长/轨道；限制 M4A/WAV/AIFF、10 MiB、30 秒，无外部引用或网络媒体。
11. 规范化/钳制 Token，运行对比度、tabular digits、内容边界、焦点和 Reduce Motion 检查；需要 UI 快照的最终预览在 MainActor 上执行。
12. 用户确认安装后，把已验证 staging 目录原子 rename/replace 到 Themes；覆盖失败保留旧版本。失败或取消不得留下半安装目录。

声明 uncompressed size 只用于早拒绝，流式实际计数才是权威，防止伪造 header 与压缩炸弹。任何一步失败都不能降级跳过后续安全机制。

## 14. 错误模型与 UI 映射

统一顶层 `AppError` 保留结构化 category、stable code、用户安全上下文、underlying diagnostic（仅日志）。不得向 UI 暴露包外路径、原始损坏金额或系统敏感详情。

| 错误族 | 示例 | UI_SPEC 映射 |
|---|---|---|
| `ValidationError` | 工资、时间输入 | 字段 inline error；保留输入 |
| `ScheduleTimeError` | 当前日期/时区中的 nonexistent 或 ambiguous 本地时间 | UI Spec 5/14/15/16 的可恢复日程时间错误；无 BusinessViewState/success，原数据保留 |
| `WorkdayTransitionError` | “开始今天”的旧 Today 未完成、非旧日、target date 未严格前进 | 保留旧 Today 与旧 ViewState，命令级 inline error；无目标 ViewState/success |
| `PersistenceError` | read/write/revision/delete | 设置 inline/banner；打卡保持原状态；Today 损坏进入 Recovery |
| `SettingsReadError` | Settings read/decode/schema/field/migration damage | UI Spec 7.3/14/15/16 的独立 Settings 错误表面；无有效 Today 时 BusinessViewState nil，有有效 Today 时非阻塞提示，Today 同时 damaged 时作次级错误；不映射 UNCONFIGURED/READY |
| `RecoveryError` | schema、timestamp、snapshot | UI Spec 第 7 节 `RECOVERY_REQUIRED` |
| `NotificationError` | denied/schedule/query/cancel | 设置对应控件说明或 non-blocking banner，不阻塞业务 |
| `LoginItemError` | denied/requiresApproval/system | 面板与启动设置 inline error，toggle 回到系统真实值 |
| `PanelError` | display missing/placement invalid | 自动约束/主屏回退；必要时 non-blocking banner |
| `ThemeValidationError` | manifest/path/media/capability/quality | UI Spec 15.8 分组诊断，无“仍然安装” |
| `ThemeRepositoryError` | install/switch/delete/fallback | loading 结束后 error；当前 Theme 保持或回退 A |

success 只在外部系统与原子写入完成后发布；取消是独立结果，不显示 error toast。业务 Recovery 与 Theme fallback 始终分开。

Loading/disabled 由正在执行的 Task 和 command-in-flight 派生；success 是提交后的单次事件；empty 是已成功读取但集合为空。四者不是 `AppError`，分别映射 `UI_SPEC.md` 16.1、16.2、16.4、16.5，不能用 error 或虚假默认数据代替。

## 15. 测试与验证分层

### 15.1 单元测试

- EarningsCalculator：提前、准点、迟到、早退、到点、未来/负时长、溢出、实时 milli-yuan 与最终 cents half-up 边界。
- StateDeriver：七状态、自然日、scheduled boundary、损坏字段与同一 now 的确定性。
- Cross-day derivation：未完成旧日 Today 保留为 AWAITING、旧日 COMPLETED 保留、当前日期 clock-in 阻断，以及“开始今天”只接受旧日 COMPLETED。
- Date relationship：同一 command timestamp 在 Today snapshot timezone 中分别得到 `dateKey <`/`=`/`>` record-current date，结果必须是旧日流程/当日流程/future-record Recovery。
- Today validation：次日 clockOut、多日后 clockOut 合法且计薪封顶；clockOut < clockIn 失败；不存在“合理工作日范围”的任意上限。
- LocalScheduleResolver：普通日唯一解析、DST gap、DST fold、start/end 分别失败、round-trip components、end > start 和时区变化；证明不使用默认归一化或 repeated-time 猜测。
- Formatters/Odometer target：三位/两位、千位符、进位链和最大工资适配输入。
- Theme path/token/capability validator：纯输入输出，不接触真实 UI。

### 15.2 Application/集成测试

- FixedClock + in-memory repository 验证 command、persist-before-success、重复点击与 revision 冲突。
- Settings 保存的 DST gap/fold 必须在 Repository 调用前失败，并断言 save count、revision、bytes、BusinessViewState 与 success feedback 均未改变。
- restore/refresh/跨日/时区变化的日程时间错误必须结束 loading、保持 BusinessViewState nil、保留 records，并允许修改时间后重试；测试同时覆盖重试失败与成功。
- `startToday` 用可观察 repository spy 断言 Settings 分类、command context、current workday、schedule/DST、target 构造均在 delete 前完成；每一步失败的 delete/save count 均为 0，old Today bytes/revision/ViewState 不变。只有成功 plan 进入单一 CAS commit，冲突/删除失败仍为零部分写入。
- Settings damaged 分别覆盖无 Today、有效 Today、旧日 COMPLETED 下“开始今天”被拒绝、替换/重置取消、成功与失败；断言不会发布普通 UNCONFIGURED/READY/`¥0.00`，不会自动覆盖原文件或删除旧 Today。
- Settings/Today 同时 damaged 覆盖两种 reset 顺序与 replace Settings 顺序，断言主/次错误、每步保留的 bytes 和最终矩阵状态。
- 临时 Application Support 验证原子写、迁移、损坏文件、重启恢复，以及旧日未完成保留、旧日完成保留、“开始今天”删除成功/失败的跨日协议。
- fake notification center 验证安排/查询/补写/取消/每日去重的补偿协议。
- 恶意 ZIP corpus 覆盖 traversal、Unicode collision、symlink、header 欺骗、压缩炸弹、损坏媒体和原子覆盖失败。
- Theme 切换/删除/回退前后比较同一业务输入的完整 ViewState 与最终金额。

### 15.3 窗口与 UI 测试

- AppKit window harness 验证 panel frame、level、close→hide、key behavior、screen clamp、四角吸附和显示器断开。
- XCUITest 验证 Panel/MenuBar/Settings 共享状态、打卡确认、错误、快捷键、Theme 管理和登录启动 UI adapter。
- Retina/1x/2x、浅/深/跟随系统、120% 字体、Reduce Motion/Transparency/Increase Contrast 截图与几何检查。

### 15.4 无障碍与手动验收

- Accessibility Inspector/VoiceOver 检查焦点顺序、名称/value、announcement 去重和装饰隐藏。
- 手动多显示器、Space、全屏、睡眠唤醒、系统通知抑制与登录重启。
- 按 `SPEC.md` 21–23 和 `UI_SPEC.md` 18 建立发布 checklist；文档勾选不代替实际结果。
- S4R-003 若因没有物理外接显示器而标记 `deferred`，上述真实多显示器/系统行为条目保持未通过并转入 Release Candidate/正式发布硬门槛；自动化 harness、fake screen 或合成通知不能关闭该 finding。

### 15.5 PD2RR follow-up 必测边界矩阵

| 场景 | 冻结输入 | 预期可断言结果 |
|---|---|---|
| 次日 clockOutAt | Today timezone/dateKey + 次日 command timestamp | 写入成功，COMPLETED，clockOut 保留真实次日时间，金额截止 scheduledEnd |
| 多日后 clockOutAt | 同一 Today + 多日后 timestamp | 与次日相同；不触发 timestampOutsideWorkday/Recovery |
| DST gap | startToday target 日的 start 或 end 不存在 | `ScheduleTimeError.nonexistentLocalTime`；delete/save count 0，旧 COMPLETED 不变 |
| DST fold | startToday target 日的 start 或 end 有两个候选 | `ScheduleTimeError.ambiguousLocalTime`；不选早/晚瞬间，旧 Today 不变 |
| 创建 Today 后切换东侧时区 | 同一 instant，command timezone 东移 | Today relation 仍按 snapshot timezone；commandDateKey 提前不触发提前清理 |
| 创建 Today 后切换西侧时区 | 同一 instant，command timezone 西移 | Today 不重解释；commandDateKey <= old dateKey 时 typed transition error 且保留旧结算 |
| dateKey 落后 | Today.dateKey < recordCurrentDateKey | 未完成为旧 AWAITING，已完成为旧 COMPLETED |
| dateKey 相等 | Today.dateKey == recordCurrentDateKey | 当日正常推导 |
| dateKey 超前 | Today.dateKey > recordCurrentDateKey | `RECOVERY_REQUIRED(.futureDatedTodayRecord)` |
| Settings/Today 同时损坏 | 两个 damaged typed result | Today Recovery 主错误 + Settings 次错误；先 reset Today/Settings 的转移严格符合 5.2 |

## 16. DEBUG 时间注入

- Composition Root 在 `#if DEBUG` 或 Test target 才解析 `--debug-now-ms`、`--debug-time-rate` 和预置工作日场景；Release 编译不包含入口和文案。
- `AdvancingClock` 以真实单调时钟乘倍率映射到模拟 wall time；工资仍每次从模拟的权威 now 与 snapshot 重算，不累计 amount。
- 支持暂停、跳到 scheduledStart、跳到 scheduledEnd 前后和完整 9:00–18:00 快速运行，便于动画/恢复手测。
- DEBUG 时间切换必须使用独立 Application Support suite 或内存 repository，禁止污染真实用户 Records、通知和登录项。
- 自动测试直接注入 FixedClock，不依赖 DEBUG UI。任何 debug control 都由编译条件排除，不进入 Release 用户界面。

## 17. 构建、签名、沙盒与分发

### 17.1 首版配置

- Deployment target macOS 13.0；单 universal macOS app（支持构建环境允许的 arm64/x86_64）。
- Release 开启 App Sandbox 与 Hardened Runtime；不申请网络 client/server entitlement。
- 文件访问只使用 user-selected read-only entitlement 导入包；后续只读写应用容器 Application Support。
- 通知通过系统 API 请求用户权限；不使用 Accessibility、屏幕录制、自动化或定位权限。
- 登录启动使用 SMAppService main app，不安装 LaunchDaemon/LaunchAgent 文件。
- 禁止执行下载代码、脚本、插件或皮肤内容；Theme media 作为数据解码。

### 17.2 分发推荐

首版推荐 Developer ID 签名、Hardened Runtime、notarization 与 stapling 后，以本地 DMG/ZIP 分发；保留 App Sandbox。Mac App Store 是后续渠道选择，不是首版技术依赖。Debug/unsigned 构建不得作为对外发布物。

发布门槛包含：签名验证、notarization 验证、Gatekeeper 冷启动、权限首次流程、无网络运行、干净用户账户安装/卸载说明、第三方许可证清单，以及 S4R-003 真实物理系统矩阵全部通过并经独立 Review 关闭。S4R-003 为 `deferred`、`open` 或证据不完整时，禁止生成或对外分发 Release Candidate、正式版、签名发布包或公证发布物。

## 18. 分阶段实现与验证门槛

按最小风险排序，每阶段未过门槛不得把依赖它的行为标记完成：

### 18.1 状态与延期 Contract

- 阶段/文档状态继续使用 `implemented`、`review`、`blocked`、`verified`；不引入阶段级 `conditional`。存在 S4R-003 `deferred` 时 Stage 4 保持 `review`，`last_verified: null`。
- finding 状态 `deferred` 表示受明确外部条件阻塞而延期取证，必须记录原因、风险、完整补验条件和禁止发布条件；它不等于 `closed`、`passed` 或 `verified`。
- `PD-002` 只把 S4R-003 从 Stage 5 开发前 gate 移至 Stage 9 Release QA/正式发布 gate。该变更不自动授权 Stage 5，也不允许删除、模拟或缩减真实物理矩阵。

| 阶段 | 实现范围 | 验证门槛 |
|---|---|---|
| 0. 工程骨架 | 原生 target、LSUIElement、DI、空 MenuBar/Settings/Panel bridge；MenuBarExtra 系统行为 spike | macOS 13 启动、无 Dock、可退出且无业务假数据；完成下述可靠入口 spike |
| 1. Domain | 类型、Calculator、StateDeriver、Clock ports | 确定性/边界/舍入/溢出单测通过 |
| 2. Persistence | 三 records、actor、原子写、迁移/损坏恢复 | persist-before-success、重启、损坏与 revision 测试通过 |
| 3. BusinessStore | commands、七状态、DST v1 严格日程解析与可恢复错误、跨日、共享 ViewState | 面板/菜单双入口并发只提交一次；gap/fold 保存前拒绝且恢复重试证据通过 |
| 4. 标准 Panel | ProfileRegistry、NSPanel、位置、多屏、生命周期 | 代码 findings 关闭、自动化/单显示器证据通过并完成独立 Review；无物理外接显示器时 S4R-003 可按 18.1 登记为 `deferred`，Stage 4 仍保持 `review`，但不再阻断另行授权的 Stage 5 开发 |
| 5. A UI | standard layout、设置、结算、odometer、无障碍 | UI Spec A、金额边界、Reduce Motion、VoiceOver 门槛通过 |
| 6. 通知/登录 | UN scheduler、SMAppService、失败映射 | 权限、幂等、取消、系统状态回读测试通过 |
| 7. Theme core/B | ThemeStore、A/B 内置资源、切换和回退 | 切换不改变业务；B 资源/深浅/安全区验证通过 |
| 8. 导入安全 | ZIP reader、完整验证、preview、原子安装/删除 | 恶意 corpus、容量/媒体/失败清理、安全复审通过 |
| 9. Release QA | 签名、沙盒、公证、全矩阵验收 | Product/UI 首版验收实际记录全部通过；S4R-003 真实物理矩阵全部通过并经独立 Review 关闭，`deferred` 或 `open` 均禁止发布 |

Theme 导入放在核心计薪、持久化和默认 UI 之后，避免不可信输入扩大早期调试面；但不能以延期为由删减首版安全验证。

### 18.2 S4R-003 发布前真实物理矩阵

延期原因固定记录为：当前缺少物理外接显示器，无法取得真实系统证据。未来必须使用真实外接显示器逐项完成并保留可审计证据：

1. 扩展显示模式；
2. 主副屏切换；
3. 外接屏断开与重新连接；
4. Dock 位置变化；
5. 分辨率和缩放变化；
6. Space 与全屏切换；
7. 睡眠及唤醒恢复；
8. 全部过程中 Panel 始终约束在目标屏幕 `visibleFrame` 内。

任何子项缺失、失败、只在单显示器执行或仅有模拟/自动化证据时，S4R-003 必须保持 `deferred` 或转为 `open`，不得标记 `closed`、`passed` 或 `verified`。失败项若需要代码修改，必须另行授权修复并重新执行相关真实矩阵。

阶段 0 的 MenuBarExtra spike 必须在继续阶段 1 前观察并记录：菜单栏项能否被用户或系统移除；移除后应用是否自动终止；重新启动后菜单栏入口、悬浮面板和设置能否恢复。若任一实际系统行为与 `SPEC.md`、`UI_SPEC.md` 规定的可靠主入口 Contract 冲突，立即停止后续实施并返回 Tech Spec Review；不得以私有 API、隐藏辅助入口、临时保活或其他未审查绕过方案继续。该 spike 不替代既有 TimelineView、NSPanel 和 SMAppService 验证门槛。

## 19. 技术选择记录

| 主题 | 选项 | 推荐结论 |
|---|---|---|
| App 架构 | 单 target 分层 / 多 Package | 首版单 target 逻辑分层，保留端口边界；规模证据出现后再拆 |
| Panel | SwiftUI window / AppKit NSPanel host | NSPanel + NSHostingController，满足浮动、Space、focus 和位置控制 |
| 动画 pulse | TimelineView / DisplayLink | 先 TimelineView，封装 RenderPulseSource；macOS 13 spike 不达标才替换 DisplayLink |
| 金额精度 | Double/Decimal/Int64 rational | Int64 rational + 分别整数 half-up，最确定且可测试 |
| Records | UserDefaults / SQLite / Codable files | 三个独立版本化 Codable 文件 + actor 原子替换；首版无需数据库 |
| ZIP | ZIPFoundation / 自研 / 系统子进程 | 精确锁定 ZIPFoundation 0.9.20 / `22787ff`，应用自建完整安全边界；不使用高层盲解压 |
| 登录启动 | helper / SMAppService.mainApp | mainApp，无额外 helper |
| 分发 | Developer ID / Mac App Store | 首版 Developer ID 公证本地分发，沙盒仍开启 |

所有首版技术选择已有推荐结论，没有待产品方决定的问题。阶段 0 必须先完成 MenuBarExtra 系统行为 spike；进入 Theme 导入实施前必须复核已精确锁定的 ZIPFoundation revision。这两项是实施门槛，不改变产品 Contract。

## 20. Technical Review Checklist

审查日期：2026-08-16。审查对象：Technical Design 0.4 完整候选文档及其与 Product 0.8、UI 0.5 的一致性。PD-001 只证明 Technical 0.3 的历史批准事件；旧版内容缺失使增量复核不可行，下一轮必须基于 candidate 快照执行 full-document re-review。此处仅为修复后自查，不代表独立 Review、批准、实现或测试。

- [x] 三份文档的版本、状态、范围和优先级明确。
- [x] macOS 13+、MenuBarExtra、NSPanel、Settings、LSUIElement 与 App 生命周期有单一实现映射。
- [x] Domain/Application/Presentation/Infrastructure/Theme 职责与依赖方向单向。
- [x] 七状态由 records + 单次 now 纯推导，UI transient state 未污染领域枚举。
- [x] 时间、cents、milli-yuan、rational、progress 的具体类型和溢出边界明确。
- [x] Clock、计薪纯函数、状态纯函数与确定性测试边界明确。
- [x] LocalScheduleResolver 对 gap/fold 使用候选数与 round-trip 严格校验，禁止默认归一化或重复时间猜测。
- [x] ScheduleTimeError 不扩展七状态；restore、save-before-persist、success 抑制、原数据保留和设置重试顺序明确。
- [x] BusinessStore 不依赖 ThemeStore；Theme 切换不能生成业务命令。
- [x] 三类 Codable schema、迁移、revision 与原子写入明确。
- [x] Application Support、损坏 Today、Theme 回退、旧日清理和默认资源边界明确。
- [x] 跨日清理只接受用户确认后的旧日 COMPLETED；未完成旧日 Today 保留、阻断新日打卡并可在下班后结算。
- [x] `StartTodayPlan` 将单一 command context、Settings 分类、两日期键、严格日程/DST 解析、目标构造与单一 CAS 提交分开；提交前任一错误都零写入且保留旧 Today。
- [x] Settings missing/damaged 使用互斥 typed result 与完整 Today 组合矩阵；双损坏错误优先级、重置/替换顺序和每步 CAS 失败语义确定。
- [x] 冻结 snapshot timezone 负责 Today 日期关系，command timezone 只负责新工作日；dateKey 三分支、东/西时区切换和次日/多日 clockOut 算法可直接测试。
- [x] NSPanel bridge、位置、显示器身份、visibleFrame、Space 和 focus 职责明确。
- [x] TimelineView/DisplayLink 只触发刷新，后台暂停和恢复不影响权威金额。
- [x] Panel/MenuBar/Settings 共享同一 store 和命令接口。
- [x] 通知安排、取消、pending 查询和本地标记补偿协议满足每日幂等。
- [x] SMAppService 登录启动、系统状态回读和失败 UI 映射明确。
- [x] ThemeRepository、Validator、Store 和首版 Profile registry 明确。
- [x] ZIPFoundation 已固定为 0.9.20 / revision `22787ff`，并记录该版本的资源泄漏、内存泄漏和 Debug 内存对齐崩溃修复。
- [x] ZIP 选项、底层 entry reader 定位、禁止不可信包高层整包 `unzipItem`、应用自有安全边界和无第三方替代方案明确。
- [x] traversal、link、bomb、图片、声音、Token、staging 和原子安装顺序完整，未削弱 Product Spec。
- [x] A/B 内置 Manifest、Asset Catalog 与保留 ID 进入应用包的方式明确。
- [x] MainActor、后台验证、取消、revision 和并发写隔离明确。
- [x] 错误类型可映射到 UI Spec 的 loading/error/recovery/fallback。
- [x] DST v1 单元、Application、持久化前拒绝与恢复重试测试矩阵完整。
- [x] 单元、集成、窗口、UI、无障碍和手动验收分层明确。
- [x] DEBUG 完整工作日模拟不进入 Release UI 或真实数据目录。
- [x] 构建、签名、沙盒、权限、公证和本地分发边界明确。
- [x] 实现阶段按风险排序且每阶段有验证门槛；S4R-003 只从 Stage 5 前 gate 移至 Stage 9/正式发布 gate，不降低真实矩阵内容。
- [x] standard 尺寸、布局和 Token 未进入 BusinessStore；未来 shaped/multi-layout 未进入首版。
- [x] 未声称创建工程、编写代码、运行测试、安装依赖或完成真实验证。
- [x] finding `deferred` 与阶段 `review` 的语义、延期原因、风险、补验条件和禁止发布条件完整，未引入阶段级 conditional。
- [x] Frontmatter 为 0.4、`status: review`、`approved_on: null`、`last_verified: null`，并如实记录 PD-001 历史批准事件、旧版内容证据缺口和 full-document re-review 方法。

## 21. Readiness 与待批准事项

**PD2RR follow-up Contract Repair 自查：Complete；Full-document independent re-review：Pending；Approval：Not granted。**

Technical Design 0.4 follow-up repaired candidate 包含 S4R-003 gate、DST v1、`StartTodayPlan` 失败原子性、Settings/Today typed 恢复矩阵、冻结时区/dateKey 算法和无上限日数的合法跨日 clockOut。PD2RR-001、PD2RR-003、PD2RR-004 与状态同步 finding 当前仅为 `ADDRESSED / AWAITING INDEPENDENT RE-REVIEW`；PD2RR-002 已处理。0.4 尚未通过新 candidate 的独立 full-document re-review 或批准。

Technical Design 0.4 状态为 `review`，`last_verified: null`。S4R-003 继续 `deferred` 并硬阻断 Release Candidate/正式发布；本轮没有代码授权，也没有 Stage 5 授权。

## 22. 技术资料

- Apple：[MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- Apple：[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- Apple：[UNUserNotificationCenter pending requests](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getpendingnotificationrequests(completionhandler:))
- ZIPFoundation：[官方仓库与文档](https://github.com/weichsel/ZIPFoundation)
- Swift Package Manager：[Package Security](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/packagesecurity/)
