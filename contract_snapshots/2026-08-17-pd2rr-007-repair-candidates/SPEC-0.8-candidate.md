---
title: 可视收入打卡机
document_type: product_spec
version: "0.8"
status: review
last_updated: 2026-08-17
last_verified: null
approved_on: null
review_scope: "Product 0.8 PD2RR-007 repair candidate 完整文档 re-review"
historical_approved_version_record: "0.7（PD-001 批准事件仍有效；不可变内容快照缺失）"
proposed_supersedes_version: "0.7"
review_method: "full_document_re_review"
candidate_snapshot_manifest: "contract_snapshots/2026-08-17-pd2rr-007-repair-candidates/SHA256SUMS"
---

# 可视收入打卡机 — Product Spec

> `PD-001` 保留 Product 0.7 曾获批准的历史事实，但项目没有该版本的不可变内容快照或可重放差异，不能对 0.8 相对 0.7 的内容级增量作独立证明。因此 Product 0.8 必须作为完整文档重新审查，不能继续以“只包含 PD-002 增量”为批准依据。本文包含 `PD-002` 的 S4R-003 延期门槛，以及 PD2RR-001/003/004/005/006/007 的候选修补；当前仍为 candidate，状态是 `review`、`approved_on: null`，等待独立全文复审，不授权修改代码、进入 Stage 4D、Stage 5 或发布。

## 1. 产品概述

“可视收入打卡机”是一款 **macOS 桌面悬浮收入打卡工具**。用户设置日工资和固定上下班时间后，通过菜单栏或桌面右下角悬浮面板完成打卡；应用根据权威时间戳持续计算并展示“今日已获得”。达到固定下班时间后，计薪自动停止并提醒用户打卡下班；完成下班打卡后显示结算数据和祝福。

首版核心体验：

1. 金额持续、真实、可视地增长，悬浮在工作环境中但不过度打扰。
2. 提前打卡只记录到岗时间，固定上班时间之前不计薪；迟到从实际打卡时间开始计薪。
3. 面板隐藏、应用退出、Mac 睡眠或重启不会改变权威计算结果；恢复时按时间戳立即校准。
4. 固定下班时间到达后收入不会继续累加，并通过悬浮面板和可选 macOS 本地通知提醒下班打卡。
5. 主动下班或到点后打卡下班，都会进入包含最终收入、计薪时长、打卡时间和祝福语的结算视图。
6. 用户可通过内置或本地导入的安全皮肤改变视觉表现，但皮肤不能改变任何打卡、计薪、结算、通知或恢复行为。

## 2. 首版目标

- 提供原生 macOS 13+ 菜单栏入口和桌面悬浮收入面板。
- 支持设置人民币日工资、固定上班时间和固定下班时间。
- 支持提前、准点或迟到上班打卡，以及主动或到点后下班打卡。
- 使用打卡时间戳、计划工作时段和当前时间计算当天收入。
- 计薪中以三位小数展示“今日已获得”实时估算；停止和完成后以两位小数结算。
- 展示计划工作进度、实际计薪时长，以及距离开始或距离下班的倒计时。
- 到达固定下班时间后自动停止计薪，并持续显示应用内提醒直至完成打卡。
- 下班打卡成功后进入结算视图并显示明确祝福。
- 使用版本化原生本地数据保存设置、当天打卡状态和设置快照。
- 从应用退出、系统睡眠、多显示器变化和 Mac 重启中安全恢复。
- 对持久化异常进入安全、可解释且可重置的恢复状态。
- 支持浏览、预览和切换内置皮肤；支持预览、安装、切换和删除本地导入的用户皮肤，并可随时恢复默认皮肤。

## 3. 非目标

首版不包含：

- Windows、Linux、iOS、iPadOS、watchOS 或其他平台。
- 浏览器、网页应用、浏览器扩展、Electron 或 Tauri。
- 账号、登录、服务端、云同步、远程数据库或多设备同步。
- WidgetKit 桌面组件。
- 月薪、时薪、奖金、提成、加班费、税费或社保计算。
- 弹性工时、跨日班次、排班、加班、请假或调休。
- 午休、临时暂停或一天多段打卡。
- 历史收入报表、月度统计、图表、导出或分析。
- 团队、审批、定位、考勤防作弊或 AI 能力。
- 在线皮肤商店、在线发布、分享、公开上传审核、作者平台、账号、皮肤云同步或付费系统。
- 实际制作二次元、少女、游戏 HUD、赛博或其他未来风格皮肤。
- 实际实现异形窗口 `PanelPresentationProfile` 或多个 `LayoutProfile`。
- 可执行插件、任意代码、任意脚本、由皮肤提供的任意控件树、任意坐标布局或交互逻辑。

“上传皮肤”在首版统一指用户从本机选择或拖入 `.incomeclocktheme` 皮肤包进行导入；不表示上传到网络。在线发布、分享和皮肤商店只作为未来扩展，不进入当前实现范围。

### 3.1 为什么首版不使用 WidgetKit

- WidgetKit 的刷新模型不适合承担持续实时金额滚轮。
- 首版不开发 macOS WidgetKit Extension。
- 实时金额只在应用自身的原生悬浮面板中显示。
- 若未来增加 WidgetKit，只能展示低频摘要或静态结算结果，不能替代实时悬浮面板。

## 4. 产品形态与原生架构

### 4.1 平台与技术栈

- 首版仅支持 macOS 13 及以上版本。
- SwiftUI 负责悬浮面板内容、菜单栏内容、设置窗口和结算视图。
- 使用 AppKit `NSPanel` 或具有同等能力的原生浮动窗口承载桌面悬浮面板。
- 使用 SwiftUI `MenuBarExtra` 提供菜单栏入口。
- 默认不在 Dock 显示常驻图标，使用 `LSUIElement` 或等效原生能力实现菜单栏应用形态。
- 应用不依赖网络即可完成所有首版核心流程。

### 4.2 三个用户界面载体

| 载体 | 核心职责 | 不承担的职责 |
|---|---|---|
| 悬浮面板 | 高频查看今日收入、状态、进度、时长、倒计时和主要打卡操作 | 长期展开设置、大型表单、历史与图表 |
| `MenuBarExtra` | 显示/隐藏面板、状态摘要、快捷打卡、打开设置、常用开关、开机启动和退出 | 独立计薪规则或第二套状态机 |
| 独立设置窗口 | 日工资、工作时间、通知、窗口行为、开机启动、位置恢复、皮肤管理、今日记录重置和隐私说明 | 持续收入动画或日常主操作 |

结算完成可在同一悬浮面板中切换为结算视图，不要求打开大型主窗口。

## 5. 悬浮面板 Contract

### 5.1 尺寸、位置与层级

- 首版唯一的标准 `PanelPresentationProfile` 建议尺寸约 `320 × 190 pt`。
- 首版使用该固定尺寸，不要求用户任意缩放；该数值属于展示层 Profile，不属于计薪或打卡业务模型。
- 首次启动默认显示在主显示器 `visibleFrame` 右下角，距离右侧和底部可用区域各约 `20 pt`。
- 定位必须基于 `NSScreen.visibleFrame` 或同等原生能力，避开 Dock 和菜单栏。
- 面板无传统标题栏，采用紧凑圆角和适度阴影。
- “始终置顶”默认开启；关闭后使用普通窗口层级。
- “全屏应用时隐藏”默认开启。
- 面板默认可见；用户隐藏状态在应用重启后恢复。

### 5.2 拖动、吸附与锁定

- 面板可以拖动，拖动结束后吸附到当前显示器四角中最近的一角。
- 保存上次所在显示器、吸附角、距 `visibleFrame` 边缘偏移和最终约束位置。
- 提供“锁定面板位置”设置，默认关闭。
- 锁定后禁止拖动，但打卡按钮、设置入口和其他控件仍可点击；不得启用整个窗口鼠标穿透。
- 设置窗口提供“恢复默认面板位置”，将面板移回主显示器右下角。

### 5.3 多显示器与系统边界

- 用户将面板拖到副显示器后，应恢复到同一显示器和吸附位置。
- 原显示器断开时，面板重新定位到主显示器右下角。
- 恢复位置必须重新约束到当前 `visibleFrame`，不得位于不可见区域。
- 屏幕分辨率、缩放比例或 Dock 位置改变后，重新约束窗口位置。
- 面板在 Retina 与不同缩放比例下保持清晰。
- 面板默认跨 Space 保持一致可见；若当前 Space 为全屏应用，则按“全屏应用时隐藏”设置决定显示。
- Space 切换后不得随机改变面板位置、层级或可见性。

### 5.4 显示、隐藏、关闭与退出

- 菜单栏和键盘快捷键均可显示或隐藏面板；默认快捷键为 `⌥⌘I`。
- 面板隐藏不等于停止计薪。
- 关闭悬浮面板等同于隐藏，不等于退出应用。
- 退出应用必须通过菜单栏“退出可视收入打卡机”明确执行。
- 退出应用不删除设置或当天记录。
- 程序化显示面板时不得无故抢夺当前应用键盘焦点；只有用户直接与输入或按钮交互时才按需要获得焦点。

## 6. 工资、时间与计算口径

### 6.1 工资与货币

- “日工资”指完成一个完整固定计划工作日可获得的金额。
- 首版货币固定为人民币元（CNY），界面使用 `¥`。
- 用户以“元”输入日工资，范围为 `¥0.01–¥999,999.99`，最多允许两位小数。
- 保存时转换为整数分 `dailyWageCents`；权威设置和当天快照不得保存二进制浮点工资。
- 首版不计算税前/税后差异。

### 6.2 时间与打卡

- 尚未创建 Today 的 proposed schedule 使用所属命令冻结的 `commandTimeZoneIdentifier` 和 24 小时制；已创建 Today 只使用其 `settingsSnapshot.timeZoneIdentifier`，不得读取未冻结的“当前本地时区”重新解释。
- 固定下班时间必须晚于固定上班时间；首版仅支持同一自然日内的班次。
- 将某一自然日的固定上班/下班墙上时间解析为时间戳时，两个时间都必须在该日、该时区内**存在且只能对应一个瞬间**。夏令时或其他时区规则导致本地时间不存在，或同一墙上时间重复出现而无法唯一解析时，当日日程无效。
- 当日日程时间无效时，应用不得向前/向后平移时间、选择较早或较晚的重复时间，也不得使用系统 API 的默认归一化结果猜测用户意图。
- 当日日程时间无效属于可恢复的日程时间错误，不增加第八个业务状态。当它是无旧业务状态的启动/恢复结果时，不得发布 `BusinessViewState`、金额、倒计时、打卡可用性或成功反馈；当它发生在“开始今天”对新目标的 preflight 时，不发布新目标，但必须继续发布未改动的旧 Today `COMPLETED` 和结算金额。两种情况都保留原始 Settings/Today 数据，并引导用户调整上下班时间后重试。
- 已存在且已通过校验的 Today 冻结时间戳继续作为当天权威边界，不因系统时区变化而重新解释；需要从本地墙上时间创建或重建边界时，必须重新执行上述严格唯一解析。
- 未点击上班打卡时不自动开始计薪。
- 允许在固定上班时间之前打卡。提前打卡只记录 `clockInAt`，固定上班时间之前金额保持 `¥0.000`。
- 到达固定上班时间后，已提前打卡记录自动开始计薪。
- 提前时间不计薪，不视为加班，不会使最终收入超过日工资。
- 迟到从实际 `clockInAt` 开始计薪，因此固定下班时最终收入低于日工资。
- 固定下班时间后自动停止计薪；之后的下班操作时间只用于记录，不增加收入。
- 固定下班时间之后不得首次上班打卡。

### 6.2.1 命令时间、日期与时区快照

- 每个用户命令只采样一次 `commandTimestamp`。命令开始时同时冻结 `commandTimeZoneIdentifier`（当时系统时区），并由该时区与同一时间戳生成 `commandDateKey`；一次命令中不得重新读取时间或时区。
- 对已存在的有效 Today，使用同一 `commandTimestamp` 在 Today `settingsSnapshot.timeZoneIdentifier` 中生成 `recordCurrentDateKey`，并且只用它与 Today `dateKey` 判断该 record 是旧日、当日或未来日。
- 系统时区在 Today 创建后切换到东侧或西侧，不得用新时区重新解释 Today 的 `dateKey`、snapshot 墙上时间或已冻结边界。新时区只影响尚未创建的目标工作日。
- 所有日期判断必须明确标注上述两个冻结时区之一；不得使用未冻结的 `Calendar.current`、再次读取的 `TimeZone.current` 或模糊的“当前本地日期”。

### 6.3 权威计薪公式

定义：

- `dailyWageCents`：日工资，整数分。
- `scheduledStartAt`：当天固定上班时间对应的时间戳。
- `scheduledEndAt`：当天固定下班时间对应的时间戳。
- `clockInAt`：实际上班打卡时间戳。
- `clockOutAt`：实际下班操作时间戳；未打卡时为空。
- `now`：当前权威时间。

```text
scheduledDurationMs = scheduledEndAt - scheduledStartAt
effectiveStartAt = max(clockInAt, scheduledStartAt)
effectiveEndAt = min(clockOutAt ?? now, scheduledEndAt)
earnedDurationMs = max(0, effectiveEndAt - effectiveStartAt)
exactEarnedCents = dailyWageCents × earnedDurationMs / scheduledDurationMs
```

`exactEarnedCents` 是精确比例金额，可以包含不足一分的部分。不得通过累计显示金额、动画帧或定时器次数计算收入；每次都从权威时间和当天设置快照重算。

### 6.4 实时与结算舍入

实时三位小数：

```text
exactEarnedMilliYuan =
  dailyWageCents × 10 × earnedDurationMs / scheduledDurationMs

liveEarnedMilliYuan =
  floor(exactEarnedMilliYuan + 0.5)
```

最终两位小数：

```text
roundedEarnedCents =
  floor(exactEarnedCents + 0.5)
```

- `UNCONFIGURED`、`READY` 显示 `¥0.00`。
- `CLOCKED_IN_WAITING` 显示 `¥0.000`。
- `EARNING` 显示三位小数的“今日已获得”，可辅以较小的“实时估算”文字。
- `AWAITING_CLOCK_OUT` 显示两位小数的已停止金额。
- `COMPLETED` 显示两位小数的最终结算金额。
- 主动下班确认、自动停止、结算视图和祝福中的金额统一显示两位小数。
- 第三位小数只表现不足一分钱的实时估算，不是人民币正式结算单位。
- 实时与最终金额分别从权威数据执行普通 half-up 舍入；不得用三位显示值推导最终金额。
- 最终结算必须直接从权威时间戳、`settingsSnapshot` 和 `dailyWageCents` 重算。
- 相同权威输入必须得到确定、可重复的结果，视觉刷新率不得改变金额。

### 6.5 计划工作进度

```text
scheduledProgress = clamp(
  (now - scheduledStartAt) /
  (scheduledEndAt - scheduledStartAt),
  0,
  1
)
```

- 显示为 0%–100%。
- 固定上班时间之前为 0%，固定下班时间达到 100%。
- 迟到不会改变计划工作日进度。
- 不使用“收入 ÷ 日工资”作为进度。

### 6.6 距离开始与距离下班

```text
remainingToStartMs = max(0, scheduledStartAt - now)
remainingToEndMs = max(0, scheduledEndAt - now)
```

- `CLOCKED_IN_WAITING` 可显示“距离开始”，格式 `HH:MM:SS`。
- `EARNING` 必须显示“距离下班”，格式 `HH:MM:SS`。
- 倒计时每次从权威时间计算，不使用每秒递减变量累计。
- 面板重新显示、应用恢复活跃或系统唤醒后立即校准。
- 到达 `00:00:00` 后进入 `AWAITING_CLOCK_OUT`。
- `COMPLETED` 不显示动态倒计时。
- 倒计时仅是辅助信息，不参与工资计算。

## 7. 状态模型

| 状态 | 进入条件 | 金额、进度与倒计时 | 主操作/视图 |
|---|---|---|---|
| `UNCONFIGURED` | Settings 明确 `missing`，且不存在可独立验证的有效 Today | `¥0.00` | 打开设置 |
| `READY` | 设置有效，当天未上班打卡 | `¥0.00`；计划进度按当前时间 | 下班时间前“打卡上班”；之后禁用 |
| `CLOCKED_IN_WAITING` | 已提前打卡，`now < scheduledStartAt`，未下班 | `¥0.000` 且不增长；进度 0%；可显示距离开始 | “打卡下班”，先确认 |
| `EARNING` | 已打卡，`scheduledStartAt <= now < scheduledEndAt`，未下班 | 三位“今日已获得”；计划进度；计薪时长；距离下班 | “打卡下班”，先确认 |
| `AWAITING_CLOCK_OUT` | 已打卡，`now >= scheduledEndAt`，未下班 | 两位已停止金额；进度 100%；倒计时归零 | 应用内提醒；“打卡下班” |
| `COMPLETED` | 有效下班记录已成功持久化 | 两位最终金额；无动态倒计时 | 结算视图与祝福；旧工作日另提供“开始今天” |
| `RECOVERY_REQUIRED` | 当天记录无法安全验证 | 停止计薪，不展示未经验证的收入 | 错误说明；确认后重置今日记录 |

补充规则：

- 一天只允许一次有效上班打卡和一次有效下班打卡。
- `COMPLETED` 不允许再次修改当天打卡时间。
- `RECOVERY_REQUIRED` 重置前不得再次上班打卡。
- 菜单栏与悬浮面板的所有操作调用同一状态 Store、状态机和持久化 Repository。
- 状态转换以持久化成功为提交边界；快速重复操作只能产生一次有效转换。

### 7.1 跨日未完成记录与“开始今天”

对任一有效 Today，按第 6.2.1 节生成 `recordCurrentDateKey`，三种关系的处理固定为：

| 关系 | 规范处理 |
|---|---|
| `Today.dateKey == recordCurrentDateKey` | 当日记录；使用 Today 冻结 snapshot 和边界正常推导。东/西时区切换不会把它变成旧日或未来日。 |
| `Today.dateKey < recordCurrentDateKey` | 旧日记录；不得因跨日自动删除。未完成时显示旧日 `AWAITING_CLOCK_OUT`，完成时显示旧日 `COMPLETED`。 |
| `Today.dateKey > recordCurrentDateKey` | 记录相对自身冻结时区处于未来，进入 `RECOVERY_REQUIRED`；不得删除、重新解释或改用系统时区规避。 |

- 旧日有效 Today 的 `clockOutAt` 为空时，应用继续使用其冻结 `settingsSnapshot`、`scheduledStartAt` 和 `scheduledEndAt`，显示带旧工作日日期的 `AWAITING_CLOCK_OUT`，金额截止于旧 `scheduledEndAt`。
- 旧日 `AWAITING_CLOCK_OUT` 始终阻止新 Today 和新日首次上班打卡。用户可在次自然日或多日后下班；`clockOutAt` 记录真实 command timestamp，可晚于 Today `dateKey` 所属自然日，但必须 `clockOutAt >= clockInAt`。只要 Today 其余权威字段有效，无上限日数，不得因“超出合理范围”进入恢复；计薪仍以 `scheduledEndAt` 封顶。
- 旧日下班写入成功后进入旧工作日 `COMPLETED`。该记录不因日期变化自动删除；只能通过用户确认的“开始今天”清理。
- “开始今天”确认命令只采样一个 command timestamp，并在任何删除、替换或持久化之前完成全部 preflight：(1) 分类并验证 Settings 为 `missing`/`valid`/`damaged`；(2) 冻结 command timestamp、command timezone 与两个日期键；(3) 确认旧 Today 为有效、已完成且 `dateKey < recordCurrentDateKey`；(4) 确认 `commandDateKey > Today.dateKey`；(5) Settings `valid` 时解析 `commandDateKey` 的当前工作日和上/下班墙上时间，并完成 DST gap/fold 唯一性检查；(6) 完整构造目标 `READY` 或 `UNCONFIGURED`、待发布数据和全部写入/删除意图。
- Settings `missing` 的 preflight 仍必须解析 `commandDateKey` 所指当前工作日，但日程/DST 步骤以明确 `notApplicable(settingsMissing)` 结果完成，目标只能是 `UNCONFIGURED`；Settings `valid` 才可解析日程并构造 `READY`；Settings `damaged` 立即返回 `SettingsReadError` 并保留旧 Today。任一日期、时区、日程、DST、Settings 或目标构造失败，返回明确 typed error（例如 `ScheduleTimeError` 或 `WorkdayTransitionError`），不得删除/修改 Today、产生部分写入或发布目标状态；UI 继续显示可恢复的旧结算。
- 只有 preflight 全部成功后，才能用单一原子提交检查预期 Today revision 与 Settings 分类/revision token，删除旧的已完成 Today，并以对观察者不可插入的单一状态切换发布已预计算的当天状态。不得暴露“旧 Today 已删除但新目标尚未构造”的中间态。任一 token 变化或删除失败都是零提交：旧 Today、旧结算和重试入口保持不变。
- 向东切换时区可使 `commandDateKey` 提前进入下一日，但只要 `recordCurrentDateKey == Today.dateKey` 就不能提前清理；向西切换可使旧 record 已跨日而 `commandDateKey <= Today.dateKey`，此时返回 `WorkdayTransitionError.targetDateNotAfterPreviousDate`、保留旧结算，直到两个严格大于条件均成立。
- 损坏、日期无法验证、未完成或内容不一致的 Today 不得进入“开始今天”提交；它们分别保持旧日 `AWAITING_CLOCK_OUT` 或 `RECOVERY_REQUIRED`。

### 7.2 Settings missing/damaged 与 Today 组合矩阵

| Settings 结果 | Today 结果 | 业务状态与金额 | 错误表面与允许操作 |
|---|---|---|---|
| `missing` | 不存在 | `UNCONFIGURED`，正常显示 `¥0.00` | 无恢复错误；打开设置 |
| `missing` | 有效 | 完全从 Today snapshot 推导 `CLOCKED_IN_WAITING`/`EARNING`/`AWAITING_CLOCK_OUT`/`COMPLETED` 及其权威金额 | 可完成旧 Today；没有设置时不能创建新 Today |
| `damaged` | 不存在 | 不发布业务状态或金额 | 阻断式 Settings recovery；可明确替换为有效 Settings 或重置为 `missing` |
| `damaged` | 有效 | 保留 Today，从 Today snapshot 推导业务状态、计薪和金额 | 非阻断 Settings 错误；依赖当前 Settings 的新日/“开始今天”操作 disabled；Today 本身的下班仍可用 |
| 任意 | `damaged` | `RECOVERY_REQUIRED`，不显示 Today 金额 | Today recovery 是主错误；Settings `damaged` 时同时保留次级 Settings 诊断和单独恢复入口 |

- 只有 Settings `missing` + 无有效 Today 允许普通 `UNCONFIGURED`/`¥0.00`。`damaged` 绝不得转成 `UNCONFIGURED`、`READY` 或虚假零金额。
- Settings 与 Today 同时 damaged 时，Today `RECOVERY_REQUIRED` 是主错误，Settings 损坏是次级错误，两个原文件均保留。先重置 Today：若 Settings 仍 damaged，转入 Settings recovery，不得进入 `READY`/`UNCONFIGURED`；先重置或替换 Settings：Today 仍 damaged 则继续 `RECOVERY_REQUIRED`，直到 Today 单独重置成功。
- “重置 Settings”指用户二次确认后将 damaged Settings 原子隔离/删除为 `missing`，绝不触碰 Today。重置成功后：有效 Today 仍存在时按其 snapshot 恢复对应业务状态；无有效 Today 时才进入 `UNCONFIGURED`。
- “替换 Settings”指用户输入通过全部校验并原子写入新记录。有效 Today 存在时仍使用 Today snapshot，新 Settings 只供后续工作日；无 Today 时使用新 Settings 和该命令的冻结日期/时区严格解析，只有成功才可进入 `READY`，否则显示 typed 日程错误而不伪装成 `READY`。

## 8. 核心用户流程

### 8.1 首次设置

1. 用户首次启动应用，悬浮面板显示 `UNCONFIGURED`。
2. 用户从面板齿轮或菜单栏打开独立设置窗口。
3. 用户填写合法日工资和固定上下班时间。
4. 用户触发保存时，Application 只采样一次 `BusinessCommandContext.timestampMs` 和 `commandTimeZoneIdentifier`，并由两者生成该命令唯一的 `commandDateKey`；UI、Product 流程和 Technical 实现不得在同一保存命令中再次读取 `Calendar.current`、`TimeZone.current` 或新的 now。
5. 在任何 Repository CAS、临时文件或持久化写入之前，Application 必须基于该 context 完成 Settings typed load/expected revision 或 damage token、输入与 record 校验、proposed schedule 的 DST gap/fold 唯一性、Today typed load、目标业务状态、完整目标 `BusinessViewState`、非抛出的 success event 和全部提交意图构造。该不可变结果称为 `SaveSettingsPlan`（或语义等价结构）。
6. 只有 `SaveSettingsPlan` 完整构造成功后，Repository 才能在单一原子 CAS 线性化点提交 Settings。commit 成功后 Application 只能发布 plan 中已构造的目标状态、ViewState、committed revision 与 success；不得再首次调用可能失败的日期、日程、计薪或业务状态 resolver/deriver。
7. preflight、目标构造、revision/damage-token conflict 或线性化点之前的 I/O failure 都必须保持该命令开始时的 Settings bytes/revision、内存 Settings、业务状态和 `BusinessViewState`，不显示 success。相对于 CAS 期间出现的外部提交，本命令不得再写任何 bytes；UI 继续显示本命令前最后已验证状态。
8. Repository 一旦越过持久化线性化点就必须返回 committed result；其后不得把通知、ViewState 发布或 housekeeping 问题描述成“设置保存失败”。若进程在 commit 后、UI 发布前终止，下次恢复以 committed bytes/revision 为真实状态；不得用旧 revision 幂等重写或展示失败。正常进程内的 committed target 发布必须为非抛出操作。
9. 用户重试必须创建新的保存命令和新的 `BusinessCommandContext`。每个 plan/result 带 command ID 与 expected token；陈旧异步 validation、conflict、failure、committed revision 或 success 均不得覆盖更新命令的内存状态、`BusinessViewState` 或 UI。

### 8.2 上班打卡

1. `READY` 显示“打卡上班”，菜单栏提供同一快捷操作。
2. 应用构造 `clockInAt` 和当前 `settingsSnapshot`。
3. 只有今日记录成功持久化后才显示打卡成功。
4. 提前打卡进入 `CLOCKED_IN_WAITING`；准点或迟到打卡进入 `EARNING`。
5. 固定下班时间后禁止首次上班打卡。

### 8.3 主动下班确认

1. 用户在 `CLOCKED_IN_WAITING` 或 `EARNING` 点击“打卡下班”。
2. 应用显示确认界面，展示按当前权威时间计算的预计两位结算金额和实际计薪时长；确认界面打开期间可继续按权威时间刷新估算，不冻结或累计显示值。
3. 文案示例：`确定现在下班吗？本次预计结算 ¥126.35。`
4. 用户取消后关闭确认界面并继续原状态，计薪不受影响。
5. 用户确认后，以确认动作发生时的权威时间记录 `clockOutAt` 并重新计算最终金额；确认界面中的上一帧预计值不作为结算输入。
6. 只有今日记录成功持久化后才进入 `COMPLETED`；写入失败保持原状态，不显示结算成功或祝福。

### 8.4 到点自动停止

1. 当前时间达到 `scheduledEndAt`。
2. 应用立即停止金额滚轮，以 `scheduledEndAt` 为计薪截止重新计算两位金额，并进入 `AWAITING_CLOCK_OUT`。
3. 悬浮面板显示“今日计薪已自动停止”和“请打卡下班”，主按钮变为“打卡下班”。
4. 到点后的下班打卡记录真实操作时间 `clockOutAt`，但计薪截止仍是 `scheduledEndAt`。
5. 今日记录成功写入后进入 `COMPLETED`。

### 8.5 完成结算

`COMPLETED` 在悬浮面板中显示：

- 最终收入，两位小数。
- 实际计薪时长，即 `earnedDurationMs` 的格式化结果。
- 实际上班打卡时间 `clockInAt`。
- 实际下班操作时间 `clockOutAt`。
- 默认祝福：`今日辛苦啦，喜提 ¥{earnedAmount}，今天的努力已经成功变现。`

`{earnedAmount}` 始终替换为两位小数金额。到点后打卡时，不得用计划下班时间冒充实际操作时间。

## 9. 原生金额动画 Contract

- 悬浮面板可见且状态为 `EARNING` 时，使用 SwiftUI `TimelineView(.animation)`、DisplayLink 或同等原生刷新机制驱动视觉更新。
- 具体刷新技术可由技术设计选择，但不得改变业务计算。
- 每次视觉刷新都读取当前权威 `Date` 或时间戳，并从 `dailyWageCents`、`settingsSnapshot`、`clockInAt`、`scheduledStartAt` 和 `scheduledEndAt` 重算。
- 不允许 `amount += delta`，不允许通过累计动画帧、`Timer` 次数、循环尾数或显示值推算工资。
- 动画刷新机制只负责触发重算，不是权威计时来源。
- 第三位小数只在真实收入跨越 `¥0.001` 时变化，不使用随机数或虚假 `000–999` 循环。
- 金额标签固定为“今日已获得”，不展示工资速度。
- 金额使用 odometer、机械里程表或垂直数字滚轮效果。
- 整数位和小数位必须正确进位，包括 `¥12.009 → ¥12.010`、`¥12.099 → ¥12.100` 和 `¥99.999 → ¥100.000`。
- 快速变化或系统降低刷新率时可合并中间视觉帧，但当前显示值最终必须与当前权威计算一致。
- 金额区域使用 tabular numbers、等宽数字或同等能力；位数增加不得造成明显布局跳动。
- 动画不得阻止下班按钮、菜单栏操作或状态转换。
- 面板隐藏、应用不活跃或动画刷新率降低时，最终工资不受影响。
- 面板重新显示或应用恢复活跃时立即依据当前时间校准，不播放后台期间的追赶动画。
- 若恢复时已到下班时间，直接进入 `AWAITING_CLOCK_OUT` 并显示两位停止金额。
- 主动下班成功或自动停止后，滚轮立即停止；最终金额直接从权威数据重算，不使用最后一个动画帧。

## 10. 应用生命周期与开机启动

- 用户可开启或关闭“登录时启动”，默认关闭。
- 使用 `SMAppService` 或 macOS 13+ 同等原生能力管理登录启动。
- 登录启动失败时，在设置窗口显示可理解的错误，不虚假显示已开启。
- 应用启动后恢复面板可见性、约束后的位置和所有有效设置。
- 当天正在计薪时，启动后直接计算当前金额；若已到下班时间，直接进入 `AWAITING_CLOCK_OUT`。
- 当天已完成时，恢复同一结算结果。
- 应用完全退出期间没有可见动画；重新启动后按权威时间戳恢复，不补播动画。
- 系统睡眠期间不累计动画状态；唤醒后立即按当前时间校准金额、倒计时和状态。
- 面板隐藏或应用不活跃不停止计薪。
- 退出应用不删除当天记录，也不取消已经安排且仍有效的下班通知。

## 11. 设置窗口

设置窗口由悬浮面板齿轮或 `MenuBarExtra` 打开，至少包含：

- 日工资输入。
- 固定上班时间。
- 固定下班时间。
- 下班通知开关。
- 始终置顶。
- 锁定面板位置。
- 全屏应用时隐藏。
- 登录时启动。
- 恢复默认面板位置。
- 重置今日记录。
- 本地数据和隐私说明。
- 皮肤浏览、导入、切换、删除、恢复默认和皮肤提示音开关。

规则：

- 日工资输入单位为元，最多两位小数，范围为 `¥0.01–¥999,999.99`。
- 保存时无误转换为整数分。
- 当天已经打卡后，工资或工作时间修改只对下一自然日生效；设置窗口明确显示“修改将于明日生效”。
- 当天计算与已安排通知继续使用 `settingsSnapshot`，不得被次日设置追溯改变。
- 设置持久化成功后才显示成功；失败时保留原值和错误说明。
- 关闭设置窗口不影响悬浮计薪、倒计时或通知安排。
- “重置今日记录”是破坏性操作，必须二次确认；成功后只删除今日记录。

## 12. 原生本地存储 Contract

### 12.1 数据职责

- 设置和今日打卡记录保存为带版本号的 `Codable` 数据，职责分离。
- 简单设置可使用 `UserDefaults`/`AppStorage`；今日记录建议保存为独立 `Codable Data` 或 Application Support 下的版本化本地文件。
- 时间点使用 Unix 毫秒时间戳或 `Date` 的稳定持久化表示。
- 工资使用整数分。
- 数据只保存在本机，不上传服务器。

建议逻辑结构：

```text
SettingsRecord(version: 1)
  dailyWageCents
  workStart
  workEnd
  notificationsEnabled
  alwaysOnTop
  lockPanelPosition
  hideInFullScreen
  launchAtLogin
  panelVisible
  panelPlacement

ThemePreferencesRecord(version: 1)
  selectedThemeId
  preferredThemeAppearance
  themeSoundsEnabled

TodayRecord(version: 1)
  dateKey
  clockInAt
  clockOutAt
  settingsSnapshot
  notificationScheduledDateKey
  notificationRequestIdentifier
```

`settingsSnapshot` 至少包含 `dailyWageCents`、`workStart`、`workEnd` 和 `currency: CNY`。

### 12.2 写入与恢复

- 设置、上班打卡、下班打卡和通知调度标记均采用完整下一状态的单次提交语义。
- Settings 保存必须在任何持久化调用之前完成第 8.1 节 `SaveSettingsPlan` 的全部构造：同一 command context 下的 typed load/token、输入与 record 校验、当前工作日严格日程解析、DST gap/fold、目标业务状态、完整 `BusinessViewState`、success event 和提交意图。任一部分不能构造时不得写入 Settings、不得增加 revision、不得改变内存/ViewState 或发布成功反馈。
- Settings Repository commit 是单一 CAS/原子写线性化点：失败结果只允许表示本命令没有提交，且 bytes/revision 不被本命令改变；成功结果携带 committed revision 和 plan target。commit 后不再执行可能首次失败的 resolver/deriver，非抛出发布 committed target；已提交的写入不得被描述为保存失败。
- 今日文件使用临时文件加原子替换或同等机制，避免部分写入。
- 上下班打卡必须先成功写入，再显示成功状态。
- 写入失败保持原业务状态，不显示虚假打卡成功、结算完成、通知已安排或设置成功。
- 快速重复操作只能产生一次有效转换。
- 应用退出或 Mac 重启后重新打开，必须从持久化时间戳恢复。
- 启动、唤醒、跨日或时区变化后，用一个恢复 timestamp 按第 6.2.1 节冻结时区与日期键，再按第 7.1/7.2 节选择权威来源：有效 Today 总是优先使用自身 snapshot，不受当前 Settings missing/damaged 或系统时区改变的追溯影响；只有不存在有效 Today 时才用当前 Settings 和冻结 command timezone 推导新工作日。Today/Settings 任一损坏必须按矩阵显示确定恢复表面；日程无法唯一解析时必须保留原始数据、退出 loading 并返回 typed error，不得用 `¥0.00`、旧 ViewState 或命令失败冒充恢复结果。
- 本地数据损坏不得导致应用崩溃。
- 损坏的今日记录进入 `RECOVERY_REQUIRED`；不得自动覆盖原始损坏数据。
- 重置今日记录必须二次确认，只删除 `TodayRecord`，不删除有效设置。
- 卸载应用或手动删除 Application Support、偏好设置等应用数据可能导致记录丢失，隐私说明必须明确这一限制。
- 皮肤偏好使用独立 `ThemePreferencesRecord`，只保存稳定 `themeId`、外观选择和提示音开关；皮肤文件、业务设置与今日记录分别存储。皮肤安装、切换、删除或回退不得改写 `SettingsRecord` 或 `TodayRecord`。

## 13. macOS 本地通知

- 使用 `UNUserNotificationCenter` 或同等原生通知能力。
- 只有用户明确开启“下班通知”时才请求权限；默认关闭。
- 权限被拒绝、通知被系统抑制或调度失败不得影响计薪。
- 上班打卡成功后，若通知已开启且 `scheduledEndAt` 尚未到达，可根据当天 `settingsSnapshot` 安排本地下班通知。
- 若用户在上班打卡后才开启通知，可为仍未结束的当天安排一次通知。
- 主动提前下班成功后，取消尚未触发的当日通知。
- 修改次日设置不得追溯改变当天已安排通知。
- 使用按本地日期确定的稳定请求标识符（例如 `workday-end-YYYY-MM-DD`）和 `notificationScheduledDateKey` 保证同一自然日最多安排或触发一条下班通知；对相同标识符重复调用必须表现为替换或幂等操作，不得生成第二条请求。
- 通知调度成功后才保存去重标记，并通过 `UNUserNotificationCenter` 待处理请求或同等接口确认；若本地标记写入失败，后续恢复先按稳定标识符查询系统待处理请求，再决定是否补写标记，不得盲目重复调度。调度失败不得虚假记录为成功。
- 到点时无论系统通知是否展示，领域状态都按权威时间进入 `AWAITING_CLOCK_OUT`，悬浮面板恢复可见时显示应用内提醒。
- 通知文案：`今日计薪已自动停止，别忘了打卡下班。`
- 系统可能因用户设置、勿扰模式或系统策略不显示通知，应用不得承诺必达。
- 应用下次启动时仍必须从时间戳恢复正确状态。

## 14. 菜单栏入口

`MenuBarExtra` 至少包含：

- 显示/隐藏收入面板。
- 当前状态摘要。
- 与当前状态匹配的“打卡上班”或“打卡下班”快捷操作。
- 打开设置。
- 始终置顶开关。
- 全屏应用时隐藏开关。
- 登录时启动开关。
- 退出应用。

菜单栏打卡操作与悬浮面板共享同一确认流程、状态 Store、计薪纯函数、持久化 Repository 和幂等保护，不形成第二套业务逻辑或重复记录。

存在旧日未完成 Today 时，菜单栏只提供旧工作日“打卡下班”，不得提供当前日期“打卡上班”；旧日完成后提供“开始今天…”，并复用第 7.1 节的确认、原子删除与失败保护。

## 15. UI 信息架构

### 15.1 悬浮面板

至少包含：

- 当前状态标签。
- 固定标签“今日已获得”。
- 当前收入金额。
- 计划工作进度。
- 实际计薪时长。
- 距离开始或距离下班倒计时。
- 一个与当前状态匹配的主要打卡按钮。
- 设置入口。
- 收起或隐藏操作。

不得展示：

- 工资速度或收入速率。
- 历史报表、月度统计或大型图表。
- 长期展开的大型表单。
- 大量说明文字或与核心任务无关的装饰。

### 15.2 结算视图

- 在同一悬浮面板内替换日常视图。
- 明确区分最终金额、实际计薪时长、上班时间和下班操作时间。
- 显示默认祝福，不继续运行金额滚轮或动态倒计时。

## 16. 视觉与无障碍 Contract

- 悬浮面板在浅色和深色系统外观下均可读。
- 可采用暖黑、深灰或系统材质，但不得牺牲文本和控件对比度。
- 金额是绝对视觉中心。
- 不使用紫色 AI 渐变、廉价后台卡片堆叠或无功能装饰。
- 状态不能只通过颜色表达。
- 核心操作支持键盘访问和 VoiceOver。
- VoiceOver 不按动画帧或每 `¥0.001` 变化高频播报金额。
- 可访问文本只在打卡、状态变化、自动停止和结算完成时更新。
- macOS“减弱动态效果”开启时禁用滚轮位移动画；金额仍按权威时间正确更新。
- 字体放大后，核心按钮和金额不得被裁切。
- 下班按钮不能因动画而无法点击。
- 悬浮面板不得无故抢夺当前应用的键盘焦点。

## 17. 校验与异常恢复

### 17.1 设置校验

- 日工资为空、非数字、低于 `¥0.01`、高于 `¥999,999.99` 或超过两位小数时不允许保存。
- 上下班时间缺失，或下班时间不晚于上班时间时不允许保存。
- 保存命令入口必须只采样一次 `BusinessCommandContext.timestampMs` 与 `commandTimeZoneIdentifier`，并由其生成 `commandDateKey`。拟保存的上下班墙上时间必须在该 `commandDateKey`/`commandTimeZoneIdentifier` 下严格解析；任一时间不存在或对应多个瞬间时，在持久化前拒绝保存。
- 同一保存命令的 UI 校验请求、Product 校验、DST gap/fold 结果、typed Settings/Today load、expected revision/damage token、目标业务状态、完整目标 `BusinessViewState`、Repository 写入和 success/error 事件必须绑定同一 `BusinessCommandContext`；任何层都不得再次读取 `Calendar.current`、`TimeZone.current` 或重新采样时间。
- preflight 与 target construction 任一失败都在 Repository 调用前结束；revision conflict 或 I/O failure 必须证明本命令零提交。以上失败均保持旧 Settings bytes/revision、内存状态和最后已验证 `BusinessViewState`，不显示 success。commit 后只允许非抛出发布已构造 target，不得首次推导日期、日程或业务状态。
- 失败后重试必须创建新的 context；旧命令的异步 validation、error、revision、committed result 或 success 不得覆盖新命令。若 Repository 已返回 committed，则该结果不得再归类为保存失败；进程恢复读取 committed revision，并禁止以旧 expected revision 自动重试。
- 日程时间错误必须指出发生了什么、确认原有设置/记录未被改写，并说明用户可调整上下班时间后重试；不得静默校正或自动选择重复时间。
- 错误显示在对应字段附近，并保留用户输入。

### 17.2 可恢复的日程时间错误

- 此错误用于当前工作日的本地上下班时间不存在或无法唯一解析；它不是 `UNCONFIGURED`、`RECOVERY_REQUIRED` 或任何新的业务状态。
- 错误存在期间不发布待解析的新工作日 ViewState、金额、进度、倒计时、打卡按钮可用性或 success 事件。若错误来自“开始今天” preflight，必须保留并继续发布旧 Today 已验证的 `COMPLETED` ViewState/结算，而不是发布目标新日数据。
- 原始 Settings 和 Today 数据保持原样；应用不得自动删除、覆盖、迁移或改写它们。
- 设置窗口仍可打开并显示原始值；用户修改上下班时间后可重新执行保存前校验和恢复/推导。
- 若用户尚未提交新设置，重试不得产生持久化写入。只有新设置通过严格校验并成功原子写入后，才允许重新推导并发布业务 ViewState。

### 17.3 `RECOVERY_REQUIRED`

出现以下任一条件时进入 `RECOVERY_REQUIRED`：

- `settingsSnapshot` 缺失或无效。
- 今日数据无法解码、版本不支持或字段类型错误。
- `clockInAt` 在 Today 冻结时区中不属于 `dateKey` 所在自然日，或晚于 `scheduledEndAt`。
- 已冻结 `scheduledStartAt`/`scheduledEndAt` 不能回转到 snapshot 的 `dateKey` 与墙上分钟，或 `scheduledEndAt <= scheduledStartAt`。已存在 Today 不因新系统时区或时区数据库变化重新枚举 gap/fold 候选，只验证持久化的冻结瞬间及其 round-trip 一致性。
- `clockOutAt < clockInAt`。`clockOutAt` 晚于 Today 自然日、次日或多日之后本身始终合法，不得设置任意最大日数或“合理范围”。
- `Today.dateKey > recordCurrentDateKey`，即记录相对自身冻结时区处于未来。`Today.dateKey < recordCurrentDateKey` 本身不是损坏，必须走正常跨日流程。

该状态必须：

- 停止计薪和自动状态推进。
- 不展示未经验证的收入、结算结果或祝福。
- 不自动覆盖、修复或删除原始损坏数据。
- 显示明确错误说明。
- 提供“重置今日记录”操作并要求二次确认。
- 重置成功前禁止再次上班打卡。
- 重置只删除今日记录，不删除有效设置。
- 删除失败时保留原始数据和恢复状态。

### 17.4 Settings 读取错误

- Settings 读取结果必须是互斥 typed result：`missing`、`valid(record, revision)` 或 `damaged(error, revision/fingerprint token)`。“文件不存在”才是 `missing`；解码、schema、字段、迁移或读取完整性失败都是 `damaged`，不得合并成“无有效设置”。
- Settings `damaged` 必须发布独立、可恢复的 Settings 读取错误；它不是 `UNCONFIGURED`、`RECOVERY_REQUIRED` 或第八个业务状态。
- 若存在可独立验证的有效 Today，当前工作日继续使用其冻结 snapshot 推导，Settings 错误以非阻塞方式显示，但不得用损坏 Settings 创建后续工作日或覆盖 Today。
- 若不存在有效 Today，业务 ViewState 保持未发布；悬浮面板和菜单栏隐藏金额、进度、倒计时与打卡操作，显示“设置数据无法读取”及“打开设置”。不得展示普通 `UNCONFIGURED` 外观或 `¥0.00`。
- 原始 Settings 文件必须保留，应用不得自动删除、迁移、猜测默认值或静默覆盖。设置窗口显示读取错误和原文件未改写说明，允许用户重新输入合法工资与时间。
- 替换或重置 Settings 必须使用第 7.2 节的组合矩阵和原子提交：操作不得删除/改写 Today；有效 Today 存在时恢复其 snapshot 状态，无 Today 且 Settings 被重置为 missing 时才进入 `UNCONFIGURED`，无 Today 且替换为 valid 时须再通过当前工作日严格日程解析才能进入 `READY`。任一失败保留原文件或原状态并不显示 success。

## 18. Implementation Boundaries

- 计薪公式实现为独立纯函数。
- 状态推导实现为独立纯函数。
- UI、动画、通知、窗口和存储层不得各自重新实现计薪规则。
- 注入 `Clock`/`NowProvider`，支持确定性时间测试。
- 注入 `PersistenceRepository`，支持写入失败、损坏数据和恢复测试。
- 注入 `NotificationScheduler`，支持安排、取消、权限、失败和每日去重测试。
- 窗口位置管理与计薪领域逻辑隔离。
- 动画显示值不属于权威业务数据。
- `MenuBarExtra` 与悬浮面板消费同一状态 Store。
- 所有入口共享同一打卡命令和幂等键，不引入第二套计薪或打卡状态。
- 显示器、Space、全屏策略和窗口层级由独立 `PanelPlacementController` 或等效组件管理。
- 面板尺寸、安全区、视觉遮罩、命中区域和语义组件排列由展示层 Profile Registry/Resolver 或等效组件管理；业务层不得持有标准面板尺寸、形状或布局常量。
- 悬浮面板、菜单栏和设置窗口共享同一个 `ThemeStore`；打卡与计薪业务 Store 不得依赖或读取 `ThemeStore`。
- UI 只通过稳定语义组件、Theme Tokens 和只读业务 View State 组合显示；Theme Tokens 不得参与状态推导、持久化命令或系统权限决策。
- 皮肤导入、验证、安装和兼容性由独立 `ThemeRepository`/`ThemeValidator` 或同等组件负责，与 `PersistenceRepository` 的工资设置和今日记录职责隔离。

## 19. 可扩展皮肤系统 Contract

### 19.1 首版产品范围

- 应用随包提供不可删除的内置皮肤，其中默认皮肤必须始终可用。
- 用户可浏览内置与已安装皮肤，从本地文件选择器或拖放导入皮肤包。
- 用户可在安装前预览，安装后切换、删除用户皮肤，并随时恢复默认皮肤。
- 首版所有“上传皮肤”操作都表示本地导入，不执行网络上传。
- 首版不提供在线商店、在线发布、分享、公开审核、作者后台、账号、云同步或付费能力。

### 19.2 业务隔离与依赖方向

- 打卡 Store、计薪纯函数、权威时间、金额舍入、最终结算、通知、工资设置、今日记录持久化和恢复逻辑不得读取皮肤配置来决定业务行为。
- 皮肤系统只能消费只读业务状态以选择对应语义资源，不能向业务 Store 注入状态或命令。
- 悬浮面板、`MenuBarExtra` 和设置窗口共享同一个 `ThemeStore`；业务 Store 不依赖 `ThemeStore`。
- 切换、覆盖、删除、损坏或回退皮肤不得修改工资配置、`settingsSnapshot`、通知调度或 `TodayRecord`。
- UI 使用由应用实现的稳定语义组件和 Theme Tokens。皮肤只能改变视觉资源和应用明确允许的表现参数。
- 皮肤不得改变信息架构、核心语义组件集合、核心按钮文案与含义、打卡流程、工资计算、金额精度、结算内容、通知规则、持久化数据内容或系统权限。
- 首版 `standard-theme` 不得新增、删除、移动或替换核心交互，也不得控制窗口层级、位置、尺寸、多显示器恢复、键盘快捷键或焦点策略。未来具备已协商能力的皮肤也只能引用应用实现并审核的展示 Profile，不能自行控制这些行为。

### 19.3 固定语义组件与插槽

首版标准布局中的皮肤只能作用于应用预定义的语义组件和插槽：

- `panel.background`：悬浮面板背景。
- `panel.decoration.leading`、`panel.decoration.trailing`：非交互装饰。
- `status.badge`：状态标签视觉。
- `income.label`：固定“今日已获得”标签视觉。
- `income.amount`：金额数字视觉。
- `progress.track`、`progress.fill`：计划工作进度视觉。
- `countdown`、`earnedDuration`：倒计时与计薪时长视觉。
- `primaryAction`、`secondaryAction`：应用定义的按钮视觉。
- `error.message`、`focus.ring`：错误与焦点视觉。
- `stateDecoration.<state>`：七个产品状态各自可选的非交互装饰资源。
- `settlement.decoration`：结算视图装饰。
- `settings.preview`：设置窗口中的安全预览区域。

皮肤不能提供任意布局、控件坐标、任意控件树、点击区域、交互逻辑或自定义 SwiftUI 视图。首版只能使用标准布局；未来皮肤最多引用应用已支持的 `LayoutProfile` ID，由应用决定层级、坐标、命中测试和语义。装饰插槽始终位于核心内容之后、裁切在应用指定区域内且不参与命中测试，不得遮挡“今日已获得”、主要打卡按钮、错误信息、焦点环或系统控制。

### 19.4 Theme Token Contract

每个皮肤可为声明支持的外观模式提供下列 Token：

| Token 组 | 允许配置 | 强制约束 |
|---|---|---|
| 背景 | 背景色、应用预实现的系统材质枚举、背景图、装饰图 | 不得自定义着色器或访问窗口外内容；透明度受安全范围约束 |
| 文字 | 主文字、次级文字、错误、成功、警告和各状态颜色 | 核心文字与背景必须通过对比度检查；状态不能只靠颜色 |
| 强调 | 强调色、焦点环颜色 | 不得隐藏焦点或使主操作不可辨认 |
| 金额字体 | 应用允许列表中的系统/内置字体、字重、字号 | 必须支持 tabular numbers 或应用强制启用等宽数字；字号和字重被限制在可布局范围 |
| 形状 | 标准 Profile 内的圆角、边框宽度/颜色、阴影预设、背景透明度 | 数值由 schema 限制并在运行时钳制；首版不能改变面板尺寸、视觉遮罩或点击区域 |
| 按钮 | 应用预实现的填充、描边、胶囊或系统样式预设 | 禁用、按下、焦点和危险状态由应用保证，皮肤不能移除 |
| 进度 | 应用预实现的线形、分段或紧凑环形预设 | 仍表达同一 0%–100% 计划进度，不得改变计算或语义 |
| 图片 | 背景图、固定装饰插槽、状态装饰和结算装饰 | 仅本地已验证资源；裁切、层级和命中测试由应用控制 |
| 动画 | 应用预实现的 `none`、`odometer`、`verticalRoll`、`softFade` 等预设及受限时长/强度 | 不得提供代码或任意关键帧；不能影响业务状态或领先权威金额 |
| Reduce Motion | 无位移即时更新或应用预实现的低动态淡入预设 | 系统“减弱动态效果”优先级最高，皮肤不能覆盖 |
| 声音 | 打卡成功、结算完成或自动停止的可选本地提示声音映射 | 只在离散事件播放；受全局“皮肤提示音”开关控制，默认关闭 |
| 外观 | `light`、`dark`，以及同时支持两者时的 `system` | 每个声明模式必须提供完整必需 Token；未支持模式不得伪装为已支持 |

具体颜色、字号、间距、圆角范围和动画参数值由后续 `UI_SPEC.md` 定义；本 Spec 只固定语义、隔离、安全和兼容边界。

### 19.5 皮肤包格式

`.incomeclocktheme` 是 ZIP 兼容的只读导入容器，使用自定义扩展名。示例：

```text
猫猫打工.incomeclocktheme
├── manifest.json
├── preview.png
├── assets/
│   ├── background.png
│   └── earning-cat.png
└── sounds/
    └── clock-out.m4a
```

`manifest.json` 使用 UTF-8 JSON，至少包含：

```text
schemaVersion
themeId
name
author
themeVersion
minimumAppVersion
description
preview
appearance.supportedModes
tokens
resources
animationPresets
sounds (optional)
licenseOrSource
requiredCapabilities (0.6 reserved, optional)
optionalCapabilities (0.6 reserved, optional)
panelProfile (0.6 reserved, optional)
layoutProfile (0.6 reserved, optional)
visualMask (0.6 reserved, optional)
```

规则：

- `schemaVersion` 定义包结构版本；未知主版本拒绝导入。
- `themeId` 是稳定身份，不依赖文件名；采用小写反向域名式 ASCII 标识，例如 `com.example.cat-worker`，必须匹配 `^[a-z0-9]+(?:[.-][a-z0-9]+)*$`。
- `themeVersion` 使用语义化版本；`minimumAppVersion` 声明最低兼容应用版本。
- 0.5 皮肤不包含新增能力字段时，按 `standard-theme@1`、首版标准面板、首版标准布局且无视觉遮罩解释，无需改包即可继续兼容。
- 新增能力字段的语义、协商与降级遵循第 20 节；字段存在不等于当前应用支持对应能力，应用不得据此假装支持未实现能力。
- 所有资源路径必须为皮肤包根目录内的规范化相对路径。
- `preview` 必须指向包内已验证图片。
- `licenseOrSource` 必须存在，可记录版权、授权、原创声明或来源说明；应用不替用户验证版权真实性，但必须在安装前展示。
- 字体 Token 只能引用应用允许的系统/内置字体名称；首版不接收用户字体二进制。

### 19.6 ID、重复安装与版本兼容

- 内置皮肤使用保留 `themeId`，用户包不得覆盖。
- 同一 `themeId` 与同一 `themeVersion` 再次导入时，显示“已安装”并允许用户选择取消或原子重新安装；不得静默创建副本。
- 同一 `themeId` 的更高 `themeVersion` 视为升级。安装前展示版本变化，验证成功后原子替换；若当前正在使用该皮肤，替换成功后保持选中并重新加载。
- 低于已安装版本的包默认拒绝降级；用户若确需旧版，须先删除现有用户皮肤再重新导入。
- 同一 `themeId` 但 `author` 不一致时拒绝覆盖，用户必须先明确删除旧皮肤，以降低意外身份冲突风险。
- `minimumAppVersion` 高于当前应用版本、`schemaVersion` 不受支持或皮肤声明模式无法满足当前兼容要求时，拒绝安装并显示原因。
- 覆盖安装失败时保留原已安装版本和当前选择。

### 19.7 声明式安全边界

首版皮肤包只允许声明式 JSON 和白名单媒体资源。明确禁止：

- Swift、Objective-C 或其他原生代码。
- JavaScript、HTML、Shell 脚本或其他脚本。
- 可执行文件、动态链接库、插件代码、宏或字节码。
- 用户字体二进制、自定义着色器或任意可执行动画描述。
- 任意网络请求、远程资源 URL 或导入后自动执行内容。
- 绝对路径、目录穿越、符号链接、硬链接或包外文件引用。

皮肤渲染层无网络能力；Manifest 中出现 URL 资源、命令、代码入口或未知行为字段时必须拒绝安装。

### 19.8 导入验证与安全阈值

导入必须在应用创建的隔离临时目录中完成，验证通过后才原子安装。验证顺序至少包括：

1. 校验扩展名、ZIP 结构、条目数量、压缩后与解压后总量，防止压缩炸弹。
2. 规范化所有路径；拒绝绝对路径、`..`、路径逃逸、符号链接、硬链接，以及经 Unicode/大小写规范化后冲突的重复路径。
3. 校验严格 Manifest schema、字段类型、ID、版本和兼容性。
4. 校验所有引用资源存在，且没有未引用的危险文件。
5. 按真实文件签名和解码结果校验类型，不只信任扩展名或 MIME 声明。
6. 完整解码图片并校验尺寸、像素数、色彩与内存预算。
7. 完整解析声音并校验格式、时长和容量。
8. 在受限预览渲染器中检查 Token、对比度、内容边界、核心按钮、焦点和 Reduce Motion 降级。
9. 验证成功后，以临时目录到目标目录的原子移动/替换完成安装；失败时清理临时数据，不留下半安装目录。

首版初始安全阈值：

| 项目 | 默认上限/策略 |
|---|---|
| 包内条目数 | 256 |
| 压缩包大小 | 50 MiB |
| 解压后总容量 | 100 MiB |
| 单个文件 | 20 MiB |
| `manifest.json` | 256 KiB |
| 图片 | 单边不超过 4096 px，总像素不超过 16 MP；允许 PNG、JPEG、HEIC |
| 声音 | 单文件不超过 10 MiB、时长不超过 30 秒；允许 M4A、WAV、AIFF |

这些阈值是实现安全上限，可根据真实性能测试在发布前收紧；放宽上限需要安全和性能复审。不得省略验证机制。

未知字段处理：

- 当前 schema 规定字段之外的未知字段默认拒绝，防止旧版本误解新行为；第 20 节预留字段属于 0.6 已知字段，但仍必须通过能力协商后才能生效。
- 可选顶层 `extensions` 对象允许使用命名空间键保存未来声明；当前应用忽略其内容且不得据此产生行为。
- 缺失必需 Token、必需资源或 Manifest 已引用资源时拒绝安装。
- 缺失未引用的可选插槽资源不阻塞安装，使用系统默认 Token/空装饰并在预览中提示。
- 损坏图片或声音拒绝安装；不得在运行时延迟执行首次解码。

### 19.9 存储、选择与生命周期

- 内置皮肤随应用发布，位于只读应用资源中，不可被用户删除。
- 默认皮肤属于内置皮肤，不依赖 Application Support、外部文件或网络。
- 用户皮肤保存在 Application Support 下独立的 `Themes` 目录，与设置和 `TodayRecord` 分离。
- 安装目录以稳定 `themeId` 组织；文件名和本地显示名称不作为身份。
- 当前选择在独立 `ThemePreferencesRecord` 中保存为稳定 `selectedThemeId`。
- 切换主题只提交 `selectedThemeId` 和 Theme Store 状态，不改写业务 Store、工资设置或今日记录。
- 删除非当前用户皮肤前显示确认，确认后删除；业务数据保持不变。
- 删除当前用户皮肤前明确提示将切换为默认皮肤；先成功切换并持久化默认 `themeId`，再删除目标皮肤。任一步失败均不得留下无有效当前皮肤的状态。
- “恢复默认皮肤”只切换 `selectedThemeId`，不删除其他皮肤。
- 当前皮肤缺失、损坏、模式不支持或与新版应用不兼容时，禁止加载其资源，自动切换到默认皮肤，显示非阻塞说明，并允许查看具体原因。
- 失效用户皮肤保留为禁用状态供用户查看原因、删除或重新导入；不得阻止应用启动。
- 每次应用升级后的首次启动重新验证所有已安装用户皮肤的 schema、兼容性和资源完整性。
- `ThemePreferencesRecord` 缺失或损坏时使用默认皮肤与安全默认偏好，不进入业务 `RECOVERY_REQUIRED`；皮肤错误只由 Theme Store 处理并安全回退，今日计薪继续按业务状态恢复。

### 19.10 用户流程

#### 浏览与预览

1. 用户在设置窗口打开“皮肤”。
2. 应用列出内置、已安装、禁用和当前皮肤，并标明来源、作者、版本、外观支持和兼容状态。
3. 用户选择皮肤后在固定语义组件的预览环境查看，不直接改变当前皮肤。
4. 预览必须覆盖至少 `READY`、`EARNING`、`AWAITING_CLOCK_OUT`、`COMPLETED`、错误、键盘焦点、浅色、深色和 Reduce Motion 表现。

#### 本地导入与拖放

1. 用户点击“导入皮肤”选择本地 `.incomeclocktheme`，或将包拖入设置窗口指定区域。
2. 应用复制到隔离临时目录并运行完整验证，不直接从原路径执行或长期引用资源。
3. 验证成功后展示安装前预览、作者、版本、权限边界、来源说明和可能的安全 Token 修正。
4. 用户确认后原子安装；成功后可选择立即切换。
5. 验证失败时显示具体可操作原因，不安装、不切换、不留下半安装文件，也不影响当前皮肤和业务数据。

#### 切换、删除与恢复

- 切换皮肤即时作用于所有可渲染载体；系统原生菜单项仍遵循 macOS 外观限制。切换时当前金额继续由业务 Store 重算，不能暂停或重置。
- 删除非当前皮肤：确认后删除，当前皮肤不变。
- 删除当前皮肤：确认后先切换默认皮肤，再删除；取消则不变。
- 恢复默认皮肤：无需删除其他皮肤，成功持久化后统一更新悬浮面板、菜单栏可渲染内容和设置窗口。
- 重复 ID、相同版本、更高版本、作者冲突、降级和不兼容包分别按 19.6 处理。
- 启动时当前皮肤损坏或应用升级后失效：自动默认回退，业务恢复继续，非阻塞提示原因。

### 19.11 质量底线与处置策略

皮肤不能降低 0.4 已确认的可用性和无障碍基线。应用采用以下分层策略：

| 问题类别 | 处置 |
|---|---|
| 代码、远程资源、路径逃逸、链接、非法类型、损坏媒体、版本不兼容、必需资源缺失 | 拒绝安装 |
| 字号、字重、圆角、边框、阴影、透明度、动画时长或强度超出 schema 安全范围 | 预览时钳制到安全范围并明确提示；安装保存原声明但运行时始终使用规范化 Token |
| 主/次文字、金额、按钮、错误、状态或焦点对比度不足 | 使用系统安全 Token 替换违规 Token并在预览标记；若替换后仍无法满足核心可读性则拒绝安装 |
| 不支持 tabular numbers、金额可能裁切、按钮状态不可辨认 | 强制应用的等宽数字、字号上限和系统按钮状态；若核心布局仍失败则拒绝安装 |
| 装饰可能遮挡、溢出或截获点击 | 强制裁切、置于内容后、禁用命中测试；无法安全约束则拒绝对应资源或整个安装 |
| 缺失未引用的可选 Token/装饰 | 使用系统默认 Token或空装饰，显示非阻塞预览提示 |
| Reduce Motion 未声明降级 | 强制无位移即时更新；皮肤不得覆盖系统设置 |
| 当前外观模式不受支持 | 整体回退到默认皮肤对应模式并提示，不混用可能冲突的核心 Token |
| 可选提示声音不可用 | 安装阶段若已声明并损坏则拒绝；运行时播放失败则静默跳过并记录诊断，不影响业务 |

无论皮肤如何配置，都必须保证：

- “今日已获得”和当前金额清晰可读，金额数字适合持续变化且精度规则不变。
- 文字对比度满足基本无障碍要求，键盘焦点可见，打卡按钮状态可辨认。
- 状态不只通过颜色表达，VoiceOver 语义由应用提供。
- Reduce Motion 生效，关闭滚轮位移动画后金额仍按权威时间更新。
- 装饰不造成内容溢出、裁切核心内容、改变点击区域或阻止打卡。
- 皮肤提示声音关闭或播放失败不影响任何业务行为。

### 19.12 与后续 UI Design 的衔接

- 后续 `UI_SPEC.md` 必须同时定义默认皮肤和皮肤系统共用的语义组件。
- `UI_SPEC.md` 负责具体尺寸、字体、颜色、间距、状态布局、动效、Token 数值范围和皮肤插槽视觉规则。
- 本 `SPEC.md` 只定义产品、架构、安全、兼容、生命周期和质量 Contract，不制作具体视觉稿。
- 首版开发至少提供默认皮肤和一个差异明显的测试皮肤，用于验证换肤架构；面向用户提供的具体内置皮肤数量由后续 UI Design 决定。

## 20. 未来 Profile 与能力协商 Contract

本节定义兼容方向和展示层抽象，不代表首版承诺实现全部能力。首版仍只交付约 `320 × 190 pt` 的标准面板，以及已批准的 A「暖屿」默认皮肤和 B「窗边搭子」架构验证皮肤；本节不得被用于扩大首版完成定义。

### 20.1 能力分级与首版承诺

能力标识采用稳定名称和显式版本，例如 `standard-theme@1`。应用只能对实际实现、验证并公开支持的能力进行宣告。

| 能力 | 定义 | 首版承诺 |
|---|---|---|
| `standard-theme` | 在首版固定标准面板和标准布局内使用 Theme Tokens、语义插槽及受限媒体资源 | 支持 `standard-theme@1` |
| `shaped-panel` | 引用应用提供的不规则视觉外壳、遮罩、安全区和命中测试 Profile | 仅定义未来 Contract，不实现 |
| `layout-profile` | 引用应用实现并审核的语义组件排列模板 | 仅定义未来 Contract，不实现多个模板 |
| `animated-decoration` | 使用应用允许的高级装饰动画能力 | 仅定义未来扩展；首版仍只有 0.5 已允许的受限动画预设 |
| `sound-pack` | 使用受限事件声音集合及其版本化约束 | 仅定义未来扩展；首版仍只有 0.5 已允许、默认关闭的可选提示声音 |

首版的受限装饰资源、动画预设和提示声音属于 `standard-theme@1` 已有 Contract，不表示应用已实现或宣告未来的 `animated-decoration`、`sound-pack` 能力。当前 schema 不得通过接受字段、忽略错误或降级渲染来伪装支持未来能力。

### 20.2 Manifest 能力声明与协商

未来 Manifest 可使用以下 0.6 预留字段：

| 字段 | 含义 |
|---|---|
| `requiredCapabilities` | 皮肤正确、安全呈现不可缺少的版本化能力列表 |
| `optionalCapabilities` | 可被不支持的应用忽略，且不影响标准降级的版本化能力列表 |
| `panelProfile` | 皮肤希望引用的应用所有 `PanelPresentationProfile` ID 及标准回退 ID |
| `layoutProfile` | 皮肤希望引用的应用所有 `LayoutProfile` ID 及标准回退 ID |
| `visualMask` | 供已支持 `shaped-panel` 的 Profile 使用的声明式包内遮罩资源映射及标准回退说明 |

能力协商规则：

- 每个皮肤仍必须声明 `minimumAppVersion`；应用版本不足时先拒绝安装并显示所需最低版本。
- 未知或版本不受支持的 required capability 必须拒绝安装，并明确显示能力名称、请求版本、当前应用能力和最低应用版本信息；没有降级时不得静默安装。
- 未知或版本不受支持的 optional capability 可以忽略，但皮肤必须包含能通过完整验证的 `standard-theme@1` 标准降级资源；依赖被忽略能力的字段、资源和效果不得参与渲染。
- 如果 optional capability 被忽略后无法形成完整、安全、可访问的标准皮肤，则拒绝安装，而不是部分渲染。
- `panelProfile`、`layoutProfile` 或 `visualMask` 引用了未知 ID 时：若关联能力是 required，则拒绝；若是 optional，则使用声明且受支持的标准回退；没有有效回退则拒绝。
- `visualMask` 只有在应用支持对应 `shaped-panel` 能力和 `PanelPresentationProfile` 时才可生效；否则按上一条处理。
- 新能力通过新的 `schemaVersion` 主/次版本或独立 capability version 引入。改变安全解释或 required 语义的变更必须提升不兼容版本，不能让旧应用误读。
- 0.5 包缺少以上字段时，等价于仅要求 `standard-theme@1` 并引用首版标准面板与标准布局；应用不得要求作者重新打包。
- 0.6 继续沿用 0.5 的严格 schema、媒体白名单、路径验证、容量限制、临时验证和原子安装规则。能力字段不能绕过任何既有验证。

### 20.3 应用所有的展示层抽象

展示层分为三个相互配合、但均不拥有业务规则的抽象：

| 抽象 | 应用所有职责 | 皮肤权限 |
|---|---|---|
| `Theme` | 解析并提供颜色、字体、图片、受限声音、动画预设和其他 Theme Tokens | 在 schema 和质量底线内声明 Token 与白名单资源 |
| `PanelPresentationProfile` | 定义面板尺寸类别、视觉遮罩、`contentSafeArea`、可发现拖动区域、透明点击穿透区域、阴影和吸附计算边界 | 只能引用应用支持的 Profile ID，并提供该 Profile 允许的资源和标准回退 |
| `LayoutProfile` | 由应用实现、审核并测试语义组件的排列、层级、适配和焦点顺序 | 只能引用应用支持的 Profile ID，不能提供任意坐标、任意控件树或 SwiftUI |

`ThemeStore` 可以组合上述已验证展示数据；打卡 Store、状态机、计薪纯函数、权威时间、最终金额、通知、持久化、恢复和权限层不得依赖、读取或分支判断任何 Theme/Profile 数据。皮肤切换、删除、损坏或 Profile 回退不得修改用户设置、工资快照或今日记录。

### 20.4 异形面板边界

未来 `shaped-panel` 可由透明 `NSPanel`、视觉 Alpha Mask 或同等 macOS 原生能力呈现圆形、胶囊、云朵、角色轮廓等非标准视觉外形，但操作系统窗口边界、视觉边界和可交互边界必须由应用分别验证：

- 视觉外形之外的完全透明区域不得截获鼠标点击；命中测试和点击穿透由应用实现，皮肤不能提供代码。
- 状态、“今日已获得”、权威金额、进度、倒计时、计薪时长、主要打卡按钮、错误信息和恢复入口必须位于经验证的 `contentSafeArea`，不得被遮罩裁切或装饰遮挡。
- 必须保留可发现且可命中的拖动区域；拖动区域不得覆盖主要操作，也不能由图片 Alpha 临时改变。
- `MenuBarExtra` 必须持续提供显示/隐藏面板、打开设置和恢复默认皮肤等可靠入口；异形面板本身也必须保留符合 Profile 的必要入口。
- 窗口整体仍受 `visibleFrame`、多显示器归属、四角或 Profile 定义的安全吸附、位置约束和位置恢复规则管理。
- 视觉形状不得改变“始终置顶”、Space、全屏隐藏、关闭即隐藏、应用退出、计薪或通知生命周期。
- VoiceOver 语义、键盘焦点、焦点顺序、点击目标底线和 Reduce Motion 降级继续由应用保证，遮罩不得覆盖或裁切焦点环。

### 20.5 布局模板边界

未来应用可内置并审核横向卡片、竖向挂件、紧凑胶囊、角色陪伴和游戏 HUD 等 `LayoutProfile`。无论排列方式如何，每个 Profile 都必须包含同一组核心语义组件：

- 状态；
- “今日已获得”标签；
- 当前权威金额；
- 计划工作进度；
- 距离开始或距离下班的倒计时；
- 实际计薪时长；
- 当前主要打卡操作；
- 错误说明与恢复入口。

Profile 可以重新排列应用允许的语义组件，但不能删除、重命名、伪装或改变其语义、数据来源、精度、状态行为和可访问名称。用户皮肤不能声明任意坐标、约束、层级或焦点顺序，只能选择当前应用已支持的 Profile ID。结算视图仍须保留第 15.2 节全部信息与祝福，不得因模板不同而缺项。

### 20.6 降级、升级与失效处理

- 应用不支持 `shaped-panel` 时，只能使用皮肤已提供且验证通过的 standard fallback；不得近似执行遮罩。
- 应用不支持请求的 `layout-profile` 时，回退首版标准布局；该皮肤的标准 Token 和资源仍须完整有效。
- required capability 没有安全降级方案时拒绝安装。required 不因包内存在 fallback 自动变成 optional。
- 应用更新后重新验证已安装皮肤的 schema、能力版本、Profile ID、资源和质量底线；当前皮肤失效时按 19.9 安全回退默认皮肤并提供非阻塞原因。
- 默认皮肤和标准 Profile 必须随应用始终可用，不依赖用户文件、网络或未来能力。
- 未来能力不得削弱 `.incomeclocktheme` 的声明式安全边界、路径与媒体验证、临时目录隔离、原子安装、启动韧性或 Theme/Business 隔离。

### 20.7 实现预留与首版边界

- `320 × 190 pt`、标准圆角矩形、标准安全区和单一组件排列必须集中归属于 `PanelPresentationProfile`、`LayoutProfile` 或同等展示层配置，不得散落硬编码在计薪 Store、打卡状态机、权威数据模型、通知层或持久化模型中。
- 首版可以只实现一个 standard panel profile 和一个 standard layout profile；Profile 注册与解析边界须允许未来新增受审核 Profile，而无需修改计薪 Store、打卡状态机或权威数据模型。
- A「暖屿」和 B「窗边搭子」在首版使用同一标准面板尺寸、标准布局和点击区域，仅通过 `standard-theme@1` 的 Theme Tokens 与安全装饰插槽形成视觉差异。
- 实际制作二次元、少女、游戏 HUD、赛博皮肤，实际实现异形窗口 Profile、多个 LayoutProfile、在线皮肤商店、公开上传审核平台或任意代码插件系统，均不属于首版。

### 20.8 未来能力验收占位边界

以下是未来相应能力进入实现范围后必须展开的验证主题，不是当前 standard panel 首版的实现验收项，也不得把尚未授权的未来能力当作当前首版完成条件。本节只排除未来能力本身，不能替代或削弱第 21～23 节中 S4R-003 对 standard Panel 的 Release Candidate/正式发布前真实物理验收硬门槛：

- `[未来：shaped-panel]` Alpha Mask 视觉、透明区域鼠标穿透、`contentSafeArea`、拖动区域、焦点环、不同缩放和 Retina 边界测试。
- `[未来：shaped-panel]` 主副显示器、显示器断开、Dock/菜单栏变化、Space、全屏、吸附与位置恢复矩阵。
- `[未来：layout-profile]` 每个模板的核心语义组件完整性、金额精度、状态映射、键盘焦点顺序、VoiceOver 和字体放大测试。
- `[未来：animated-decoration]` 资源预算、帧率降级、Reduce Motion、业务隔离和装饰命中测试。
- `[未来：sound-pack]` 白名单格式、事件映射、时长容量、全局关闭、播放失败和无业务副作用测试。
- `[未来：兼容]` 支持能力协商 schema 的较旧应用拒绝未知 required、忽略可降级 optional；新应用无修改加载 0.5 包；应用升级导致 Profile 失效时默认回退。

## 21. 验收标准

以下均为待实现、待验证标准，勾选框不代表已经通过。

### 验收记录状态 Contract

- 项目/阶段继续只使用既有合法状态：`implemented`、`review`、`blocked`、`verified`。本次不新增阶段级 `conditional` 或 `conditionally_verified`。
- finding 级状态允许 `open`、`closed`、`deferred`：`deferred` 仅表示由于明确的外部条件暂时无法取得真实验收证据；必须同时记录延期原因、风险、补验条件和禁止发布条件。
- `deferred` 不等于 `closed`、`passed`、`verified` 或风险接受，不得据此勾选验收项、填写 `last_verified`、宣称测试通过或降低预期行为。
- 存在 `deferred` finding 时，所属阶段保持 `review` 且 `last_verified: null`。经独立 Contract Review 后，产品决策可以只调整该 finding 的门槛归属；这不自动授权任何后续阶段。
- `PD-002` 将 S4R-003 从 Stage 5 开发前门槛移至发布候选版/正式发布前硬门槛。未来进入 Stage 5 仍须单独授权；在 S4R-003 取得全部真实物理证据并经独立 Review 关闭前，禁止生成或对外分发发布候选版、正式版、签名发布包或公证发布物。
- Product 0.8/UI 0.5/Technical 0.4 改变了已完成 Stage 1～3 的 Domain、Persistence 和 BusinessStore Contract。Stage 1～3 的 `verified` 只证明旧 approved Contract 下的历史实现，不是本 candidate 的实现证据。若本 candidate 未来获批，必须先另行授权、实施并独立验证 Technical 18.1 定义的 `Stage 4D — Contract Delta Implementation & Re-verification`；Stage 4D 达到 `verified` 后，才允许另行申请 Stage 5 A UI。本文不授权或实施 Stage 4D。

### A. 产品形态

- [ ] 应用是支持 macOS 13+ 的原生菜单栏工具。
- [ ] 应用不依赖浏览器、网页运行时、Electron 或 Tauri。
- [ ] 默认不显示 Dock 常驻图标。
- [ ] 不使用 WidgetKit 承担实时金额。

### B. 悬浮窗口与多显示器

S4R-003 当前为 `deferred`：原因是当前缺少物理外接显示器，无法取得真实系统证据。以下条目保持未勾选，延期不代表通过；自动化、fake screen、合成 notification、属性断言或单显示器观察均不能替代补验。

- [ ] 面板首次默认显示在主显示器 `visibleFrame` 右下角，距右侧和底部约 20 pt。
- [ ] 面板不遮挡 Dock、菜单栏或超出可见区域。
- [ ] 面板支持拖动、四角吸附、位置锁定和位置恢复。
- [ ] 位置锁定后控件仍可点击，不启用窗口鼠标穿透。
- [ ] 用户拖到副显示器后可恢复到该显示器。
- [ ] 副显示器断开后面板回到主显示器右下角。
- [ ] 分辨率、缩放或 Dock 位置变化后面板仍保持可见。
- [ ] 面板隐藏不停止计薪，关闭面板不退出应用。
- [ ] “始终置顶”和“全屏应用时隐藏”遵循用户设置。
- [ ] Space 切换后的可见性和位置行为一致且可测试。
- [ ] 面板显示时不无故抢夺键盘焦点。
- [ ] 菜单栏操作和默认快捷键均可显示/隐藏面板。

### C. 设置

- [ ] 可设置日工资、固定上班时间和固定下班时间。
- [ ] 日工资范围严格为 `¥0.01–¥999,999.99`，权威数据保存整数分。
- [ ] 当前工作日不存在或重复的本地上下班时间在 Settings 持久化前被拒绝，不增加 revision、不显示成功，且输入保持可编辑。
- [ ] 当天打卡后的工资或时间修改只对下一自然日生效，并显示“修改将于明日生效”。
- [ ] 设置窗口独立于悬浮面板，关闭后不影响计薪。
- [ ] Settings 的 validation、DST、目标业务状态、目标 `BusinessViewState`、success event 与提交意图在 Repository 调用前形成完整 `SaveSettingsPlan`；任一 preflight/target failure 零写入。
- [ ] Settings revision/damage-token conflict 或 I/O failure 不由本命令改变 bytes/revision、内存状态或 `BusinessViewState`，不显示 success；commit 后没有首次可失败推导，也不把已提交写入描述为失败。
- [ ] 登录时启动默认关闭，切换失败显示可理解错误。

### D. 今日收入与动画

- [ ] UI 不展示工资速度或收入速率。
- [ ] `UNCONFIGURED`、`READY` 显示 `¥0.00`。
- [ ] `CLOCKED_IN_WAITING` 显示 `¥0.000` 且不增长。
- [ ] `EARNING` 只突出“今日已获得”三位实时金额，可标注“实时估算”。
- [ ] 三位金额由原生动画刷新机制按当前权威时间重算。
- [ ] 第三位只在真实收入跨越 `¥0.001` 时变化，不使用虚假循环。
- [ ] 30 FPS、60 FPS、降频或跳帧不改变相同时间戳下的金额。
- [ ] odometer 正确处理整数和小数进位，位数增加不造成明显布局跳动。
- [ ] `AWAITING_CLOCK_OUT` 和 `COMPLETED` 显示两位金额且无循环滚轮。
- [ ] 主动下班和自动停止使用同一最终结算规则。
- [ ] 最终金额直接从权威数据计算，不依赖最后一个动画帧。
- [ ] 最终祝福金额始终显示两位小数。

### E. 进度与倒计时

- [ ] 计划工作进度独立于收入比例，显示 0%–100%。
- [ ] `EARNING` 显示距离下班 `HH:MM:SS`。
- [ ] `CLOCKED_IN_WAITING` 可显示距离开始。
- [ ] 倒计时按时间戳计算，不通过递减变量累计。
- [ ] 面板重新显示或系统唤醒后倒计时立即校准。
- [ ] 到点归零并进入 `AWAITING_CLOCK_OUT`。
- [ ] `COMPLETED` 不显示动态倒计时。

### F. 状态、打卡与恢复

- [ ] 上班打卡写入成功后才显示成功，并正确进入等待或计薪状态。
- [ ] 下班时间后禁止首次上班打卡。
- [ ] 计薪中或等待开工时下班，先显示预计金额与时长的确认界面。
- [ ] 取消下班确认后继续原状态；确认并写入成功后才进入 `COMPLETED`。
- [ ] 到点自动停止，真实下班操作时间与计薪截止时间分别记录。
- [ ] 有效未完成 Today 跨日或次日启动时仍恢复为带旧工作日日期的 `AWAITING_CLOCK_OUT`，不会被静默删除，也不会允许新日打卡。
- [ ] 旧日下班成功后先显示旧工作日 `COMPLETED`；只有用户确认“开始今天”且旧 Today 删除成功后才进入当前日期状态，删除失败保持旧结算。
- [ ] “开始今天”在任何删除前用单一 command timestamp 完成 Settings 分类、两时区/日期冻结、当前日程与 DST gap/fold 解析、目标状态/写入构造；任一 typed failure 都保留旧 Today 与旧结算。
- [ ] 只有 preflight 成功才用同一原子提交删除已完成旧 Today；revision/token 冲突和删除失败均不产生部分写入。
- [ ] Settings damaged 时旧日结算仍保留且“开始今天”不可用；替换或重置 Settings 必须按 Today 是否有效进入矩阵中的确定状态，不得无条件进入 `READY`。
- [ ] Settings `missing` 与 `damaged` 在 Panel、MenuBar、Settings、持久化和恢复流程中严格分离；只有 missing + 无 Today 显示 `UNCONFIGURED`/`¥0.00`。
- [ ] Settings/Today 同时 damaged 时 Today Recovery 为主错误、Settings 诊断为次级；两种重置顺序的状态转移符合第 7.2 节。
- [ ] 次日或多日后下班只要 `clockOutAt >= clockInAt` 即保留有效，计薪严格截止于冻结 `scheduledEndAt`；不使用模糊最大日数。
- [ ] 东/西时区切换不重新解释 Today；`dateKey <`/`=`/`>` 冻结 record-current date 分别进入旧日流程/当日流程/`RECOVERY_REQUIRED`。
- [ ] 应用退出和重新启动后恢复正确状态与金额。
- [ ] Mac 睡眠和唤醒后金额、倒计时和状态立即校准。
- [ ] 面板隐藏或应用不活跃期间不补播动画。
- [ ] 写入失败、损坏数据和重复操作均 fail closed。
- [ ] 当前日程时间不存在或无法唯一解析时退出 loading，但不发布七状态中的任何业务 ViewState、金额或成功反馈；原始数据保持不变，并可从设置窗口调整时间后重试。
- [ ] 保存 Settings 的 DST 校验、typed load/token、目标状态/ViewState/success 构造、revision、持久化与 success/error 全部使用一次冻结的 `BusinessCommandContext.timestampMs`、`commandTimeZoneIdentifier`、`commandDateKey`；同一命令不再次读取系统 Calendar/TimeZone。
- [ ] Settings 保存重试使用新 command context；陈旧结果不能覆盖新命令。commit 成功后只非抛出发布 plan target，进程中断后的恢复以 committed revision 为准。
- [ ] `RECOVERY_REQUIRED` 不展示未经验证金额，只允许确认后重置今日记录。
- [ ] Settings 损坏不映射为普通 `UNCONFIGURED` 或 `¥0.00`；无有效 Today 时业务 ViewState 未发布，并可从设置窗口明确修复。
- [ ] 重置今日记录保留有效设置；重置失败保留恢复状态。

### G. 通知

- [ ] 只有用户明确开启下班通知才请求系统权限。
- [ ] 上班打卡后按当天设置快照安排通知，同一自然日最多一条。
- [ ] 主动提前下班成功后取消尚未触发的当日通知。
- [ ] 通知权限拒绝、调度失败或系统未展示不影响计薪停止和应用内提醒。
- [ ] 修改次日设置不追溯改变当天已安排通知。

### H. 菜单栏

- [ ] 菜单栏可显示/隐藏面板、查看状态摘要、打开设置和退出应用。
- [ ] 菜单栏可执行当前可用的快捷打卡。
- [ ] 始终置顶、全屏隐藏和登录启动开关可用且状态一致。
- [ ] 菜单栏与悬浮面板共享同一状态机和持久化逻辑。
- [ ] 两个入口快速重复点击不会产生第二套状态或重复记录。

### I. 无障碍与外观

- [ ] macOS“减弱动态效果”下禁用滚轮位移动画，但金额仍正确更新。
- [ ] VoiceOver 不按动画帧高频播报金额。
- [ ] 核心操作支持键盘，状态不只通过颜色表达。
- [ ] 浅色和深色模式均可读。
- [ ] 字体放大后核心按钮和金额不被裁切。
- [ ] Retina 与不同缩放比例下显示清晰。
- [ ] 动画不阻止下班操作。

### J. 可扩展皮肤系统

- [ ] 应用至少包含始终可用且不可删除的默认皮肤，并支持另一个差异明显的测试皮肤验证架构。
- [ ] 用户可浏览内置和已安装皮肤，并通过文件选择或拖放导入本地 `.incomeclocktheme`。
- [ ] 合法皮肤必须先通过完整验证和安装前预览，再原子安装；失败不留下半安装文件。
- [ ] 非法 Manifest、未知主 schema、路径穿越、绝对路径、符号链接、硬链接、代码、脚本、可执行文件、远程 URL 或不兼容版本被拒绝。
- [ ] 超出条目、包容量、单文件、图片尺寸/像素或声音时长/容量上限的包被拒绝。
- [ ] 损坏图片、损坏声音、缺失必需资源或引用路径无效时拒绝安装。
- [ ] 同 ID 同版本不会静默复制；更高版本可原子升级；作者冲突和降级按 Contract 处理。
- [ ] 切换皮肤同时更新悬浮面板、菜单栏可渲染内容和设置窗口，且不重置或暂停业务状态。
- [ ] 删除非当前皮肤不影响当前皮肤；删除当前皮肤先成功回退默认皮肤。
- [ ] 默认回退、恢复默认、应用重启和应用升级后，`selectedThemeId` 与实际有效皮肤一致。
- [ ] 当前皮肤缺失、损坏或不兼容不会阻止应用启动、打卡恢复或计薪继续。
- [ ] 皮肤切换、删除、覆盖和回退不修改工资设置、`settingsSnapshot`、`TodayRecord`、通知或权威计薪结果。
- [ ] 浅色、深色、跟随系统和不受支持模式回退行为符合 Contract。
- [ ] Reduce Motion、VoiceOver、键盘焦点、状态非纯色表达和对比度底线不被皮肤覆盖。
- [ ] 金额仍使用正确等宽数字和既定三位/两位精度，装饰不遮挡金额、主要按钮、错误或系统控制。
- [ ] 多显示器切换和面板位置恢复不受皮肤切换影响，皮肤资源在 Retina 与不同缩放下清晰。
- [ ] 皮肤提示声音默认关闭，关闭或播放失败不影响业务。
- [ ] 皮肤包不执行网络请求、包内代码或导入后自动内容。

### K. 版本化能力与 Profile 预留

- [ ] 未包含 0.6 能力字段的合法 0.5 皮肤无需修改即可作为 `standard-theme@1` 安装、选择和恢复。
- [ ] 首版只宣告实际支持的 `standard-theme@1`，不会因 Manifest 出现未来字段而宣告或执行 `shaped-panel`、`layout-profile`、`animated-decoration` 或 `sound-pack`。
- [ ] 未知或版本不受支持的 required capability 被拒绝，并显示能力、版本和最低应用版本等可理解原因。
- [ ] 未知 optional capability 仅在完整标准降级通过验证时被安全忽略；没有有效标准降级时拒绝安装。
- [ ] 未知 `panelProfile`、`layoutProfile` 或不适用的 `visualMask` 严格按 required/optional 与回退规则处理。
- [ ] 0.6 能力声明不能绕过 0.5 的代码禁令、资源白名单、路径安全、容量限制、临时验证或原子安装。
- [ ] 首版的面板尺寸、标准安全区和标准组件排列归属于展示层 Profile；计薪 Store、打卡状态机和权威数据模型不读取这些值。
- [ ] A「暖屿」与 B「窗边搭子」使用相同标准面板 Profile、布局 Profile、核心语义组件和点击区域，换肤不改变权威业务结果。
- [ ] 应用升级使当前皮肤能力或 Profile 失效时，默认皮肤回退不阻塞启动、恢复或计薪。
- [ ] 第 20.8 节标记的未来能力测试不计入首版完成条件。

## 22. 测试矩阵

以下均为预期测试，不表示已经执行。

| 类别 | 场景 | 预期 |
|---|---|---|
| 计薪 | 准点、提前、迟到、早退 | 符合有效开始/结束时间公式 |
| 精度 | 计薪中与停止/完成 | 前者三位实时估算，后者两位结算 |
| 进位 | `12.009→12.010`、`12.099→12.100`、`99.999→100.000` | odometer 数字与布局正确 |
| 刷新率 | 30 FPS、60 FPS、降频和跳帧使用相同 `now` | 金额完全一致 |
| 面板隐藏 | 计薪中隐藏一段时间再显示 | 直接校准当前金额，不补播动画 |
| 应用退出 | 计薪中退出后重新启动 | 从时间戳恢复正确金额或到点状态 |
| 睡眠唤醒 | 睡眠跨越普通时段或下班边界 | 唤醒后立即校准；到点则等待下班 |
| 自动停止 | 最后一帧为三位金额后到达下班时间 | 重新计算两位停止金额并停止滚轮 |
| 下班确认 | 分别取消和确认 | 取消继续原状态；确认写入成功后完成 |
| 写入失败 | 设置、上班、下班分别失败 | 均不显示虚假成功，保持安全状态 |
| Settings preflight 零写入 | 输入/record 校验、DST、Today typed load、目标业务状态、目标 ViewState、success event 或编码/提交意图构造分别失败 | Repository save count 0；旧 Settings bytes/revision、内存状态、BusinessViewState 与 feedback 不变 |
| Settings commit 边界 | revision/damage-token conflict、原子写 I/O failure、commit success | 前两者本命令零写入且无 success；成功携带 committed revision/预构造 target，之后不再调用首次可失败 resolver/deriver |
| Settings 陈旧结果与重试 | 首命令悬挂后启动新命令，分别返回 validation/conflict/failure/committed result | 新命令使用新 context；旧结果不能覆盖新 revision、BusinessViewState 或 success；已 committed 结果不标记失败 |
| DST gap | 当前时区的上班或下班墙上时间不存在 | 保存前拒绝；恢复时显示可恢复日程时间错误；不发布业务 ViewState，不改写原始数据 |
| DST fold | 当前时区的上班或下班墙上时间对应两个瞬间 | 不选择较早/较晚实例；处理结果与 DST gap 相同 |
| 日程时间重试 | 从日程时间错误调整上下班时间并再次保存 | 新值通过严格解析后才持久化并重新推导；失败尝试不改变原 revision/bytes |
| 数据损坏 | 今日记录无法解码或字段无效 | 进入 `RECOVERY_REQUIRED`，不显示收入 |
| 未完成记录跨日 | 旧日 Today 有效且 `clockOutAt` 为空，午夜、次日启动或唤醒 | 保留记录并恢复旧日 `AWAITING_CLOCK_OUT`；新日打卡不可用；下班金额仍截止旧日计划结束 |
| 旧日结算转入今天 | 取消/确认“开始今天”；Settings valid/missing/damaged；DST gap/fold；target date 不前进；revision 冲突；删除成功/失败 | 只有全部 preflight 成功才原子删除；任一预计算、token 或提交失败都保留旧 Today/结算且零部分写入 |
| 次日 clockOutAt | 旧日未完成 Today 在下一自然日下班 | 允许写入，真实时间可晚于 dateKey，金额截止 scheduledEnd |
| 多日后 clockOutAt | 同一未完成 Today 在多日后下班 | 与次日一致；无任意最大日数，仅要求 clockOutAt >= clockInAt |
| 时区东移 | Today 创建后系统切换到东侧时区 | Today 仍用 snapshot timezone 判断；commandDateKey 提前不得提前清理 |
| 时区西移 | Today 创建后系统切换到西侧时区 | Today 不重新解释；target commandDateKey 未严格前进时保留旧结算并返回 typed transition error |
| dateKey 落后/相等/超前 | 分别构造 Today.dateKey < / = / > recordCurrentDateKey | 旧日流程 / 当日流程 / `RECOVERY_REQUIRED` |
| Settings 损坏 | 无 Today、有效 Today、重置为 missing、替换为 valid | 严格按 7.2 矩阵；不进入伪 `UNCONFIGURED`/`READY`，不伪显示 `¥0.00` |
| Settings/Today 同时损坏 | 先重置 Today 与先重置/替换 Settings | Today Recovery 主错误优先；每一步仅改变目标 record，转移结果确定 |
| 重置确认 | 取消、确认成功、删除失败 | 分别保持、只删今日、保持恢复状态 |
| 双入口并发 | 菜单栏和面板快速重复打卡 | 只产生一次有效记录 |
| 通知 | 安排、取消、权限拒绝、调度失败、每日去重 | 符合通知 Contract，不影响计薪 |
| 主显示器 | 首次启动与恢复默认位置 | 位于主显示器右下角且不遮挡 Dock |
| 副显示器 | 拖动到副屏后重启 | 恢复到副屏可见区域 |
| 显示器断开 | 面板原位于被断开的副屏 | 回到主显示器右下角 |
| 系统布局 | Dock 位置、分辨率或缩放变化 | 面板重新约束且保持可见 |
| Space/全屏 | 切换 Space 与全屏应用 | 可见性严格遵循设置 |
| Reduce Motion | 开启系统减弱动态效果 | 数值正确更新，无滚轮位移动画 |
| VoiceOver | 计薪动画持续运行 | 不高频播报；状态事件可访问 |
| 文案审计 | 检查所有首版用户可见字符串 | 不出现工资速度或收入速率文案 |
| 合法皮肤导入 | 文件选择与拖放分别导入通过验证的包 | 显示安装前预览，确认后原子安装 |
| Manifest | 缺失必需字段、类型错误、未知主 schema、未知行为字段 | 拒绝并显示具体原因 |
| 路径安全 | 绝对路径、`..`、路径穿越、符号链接和硬链接 | 全部拒绝，不写入 Themes 目录 |
| 文件安全 | Swift、脚本、可执行文件、动态库、远程 URL | 全部拒绝且不执行内容 |
| 容量限制 | 超大包、超多条目、超大单文件、超大图片 | 在安装前拒绝并清理临时数据 |
| 媒体损坏 | 图片或声音扩展名合法但无法完整解码 | 拒绝，不延迟到运行时首次解码 |
| 声音限制 | 不支持格式、超出容量或超过 30 秒 | 拒绝并标明资源 |
| 重复安装 | 同 ID 同版本再次导入 | 提示已安装；取消不变，确认则原子重装 |
| 版本升级 | 同 ID 更高版本、升级失败 | 成功原子替换；失败保留旧版本和选择 |
| 身份冲突 | 同 ID 不同作者或低版本包 | 拒绝覆盖，给出删除后重装指引 |
| 皮肤删除 | 删除非当前、当前、内置皮肤 | 非当前正常删除；当前先回退；内置不可删除 |
| 默认回退 | 当前皮肤缺失、损坏、模式不支持或不兼容 | 应用启动并用默认皮肤，业务状态不变，显示原因 |
| 重启恢复 | 选择用户皮肤后退出并重启应用 | 恢复有效 `themeId`；无效则默认回退 |
| 应用升级 | 模拟新版本提高兼容要求 | 重验所有用户皮肤，失效项禁用但不阻塞启动 |
| 外观模式 | 浅色、深色、跟随系统和不支持模式 | 支持模式正确；不支持时整体默认回退 |
| Reduce Motion | 每种动画预设下启用系统减弱动态效果 | 无位移动画，金额仍按权威时间更新 |
| 无障碍 | 低对比、无焦点、纯颜色状态、字体溢出配置 | 按拒绝、钳制或安全 Token 策略处理 |
| 多显示器换肤 | 面板位于副屏时切换和删除皮肤 | 面板位置、屏幕归属与可见性不变 |
| 计薪中换肤 | `EARNING` 持续切换、升级、删除皮肤 | 金额连续正确增长，时间戳与最终结果不变 |
| Theme/Business 隔离 | 换肤前后使用相同业务输入 | 权威状态、通知、持久化和金额完全一致 |
| 启动韧性 | 当前皮肤目录被破坏后启动 | 默认皮肤可用，业务记录正常恢复 |
| 0.5 包兼容 | 导入不含 0.6 能力字段的合法 0.5 皮肤 | 无需改包，按 `standard-theme@1` 与标准 Profile 正常使用 |
| 能力宣告 | 检查首版能力注册表 | 只宣告真实实现的 `standard-theme@1`，不伪装支持未来能力 |
| Required capability | 未知名称、未知版本或未知 required Profile ID | 拒绝安装并显示能力、版本与兼容原因，不写入 Themes 目录 |
| Optional capability | 未知 optional 能力分别搭配有效和无效 standard fallback | 有效时忽略并标准降级；无效时拒绝，不进行部分渲染 |
| 视觉遮罩协商 | 首版包声明 optional `visualMask` 与标准 fallback | 不执行遮罩，只验证并使用标准降级；业务和命中区域不变 |
| Profile/Business 隔离 | 改变展示层标准 Profile 配置并使用相同业务输入 | 业务 Store、状态、时间戳、通知、持久化和金额结果完全一致 |
| 升级后能力失效 | 当前用户皮肤的能力版本或 Profile ID 在新应用中不再兼容 | 启动时重验并回退默认皮肤，今日记录与计薪继续恢复 |

金额测试还必须覆盖实时千分之一元与最终分各自的 half-up 边界，并证明相同设置快照与时间输入结果可重复。

S4R-003 的发布前补验必须在真实外接显示器上完整执行并记录：扩展显示模式、主副屏切换、外接屏断开与重新连接、Dock 位置变化、分辨率和缩放变化、Space 与全屏切换、睡眠及唤醒恢复，以及所有过程中面板始终约束在当前显示器 `visibleFrame` 内。任一项缺失、失败或只有模拟证据时，S4R-003 继续 `deferred` 或转为 `open`，不得标记通过。

## 23. 首版完成与发布硬门槛

满足以下条件时，才可认为首版达到发布候选版/正式发布完成条件：

- 第 21 节全部验收标准经实际测试通过。
- 第 22 节测试矩阵中属于首版的项目已执行并记录结果；第 20.8 节未来能力占位不在其中。
- 计薪和状态纯函数具备确定性单元测试。
- 悬浮面板、菜单栏、设置窗口和结算视图在 macOS 13+ 可用。
- 主显示器、副显示器、显示器断开、Space、全屏、睡眠和唤醒均完成验证。
- 浅色、深色、Reduce Motion、VoiceOver 和字体放大完成验证。
- 损坏本地数据不会导致崩溃、白屏或未经验证的金额展示。
- 项目文档明确说明本地数据、设备时钟和 macOS 通知不保证必达等限制。
- 默认皮肤和至少一个差异明显的测试皮肤已验证 Theme Store、语义插槽、安全导入和业务隔离；具体用户皮肤数量仍由后续 UI Design 决定。

S4R-003 的延期只解除 Stage 5 开发前阻断，不删除或降低上述发布完成定义。缺少真实外接显示器证据时可以继续保持内部开发状态，但不得称为首版完成，不得进入 Release Candidate，也不得正式发布。

## 24. Decisions

以下首版决策已确定：

| 日期 | 决策 | 结论 |
|---|---|---|
| 2026-08-07 | 提前打卡 | 允许提前打卡，但固定上班时间前不计薪；到点自动开始 |
| 2026-08-07 | 设置生效 | 当天打卡后修改工资或时间从下一自然日生效 |
| 2026-08-07 | 历史记录 | 首版不保留历史 |
| 2026-08-07 | 货币与存储 | 固定 CNY；用户输入元，权威工资保存整数分 |
| 2026-08-07 | 金额精度 | 计薪中三位实时估算；停止、完成和祝福为两位结算金额 |
| 2026-08-11 | 产品形态 | 原生 macOS 菜单栏 + 桌面悬浮面板 |
| 2026-08-11 | 平台 | 首版仅支持 macOS 13+ |
| 2026-08-11 | 实时载体 | 原生 `NSPanel` 或同等能力，不使用 WidgetKit |
| 2026-08-11 | 技术栈 | SwiftUI + 必要的 AppKit 窗口能力 |
| 2026-08-11 | 主显示 | 只突出“今日已获得”，不展示工资速度或收入速率 |
| 2026-08-11 | 默认位置 | 主显示器 `visibleFrame` 右下角，边距约 20 pt |
| 2026-08-11 | 菜单栏 | 提供面板显示、状态摘要、快捷打卡、设置、常用开关和退出 |
| 2026-08-11 | 存储 | 原生、职责分离、带版本号的本地数据 |
| 2026-08-11 | 通知 | macOS 本地通知，可选增强，默认关闭 |
| 2026-08-11 | 登录启动 | 可选，默认关闭 |
| 2026-08-11 | 窗口默认 | 始终置顶开启；全屏应用时隐藏开启；位置锁定关闭 |
| 2026-08-11 | 0.4 基线 | 打卡、计薪、金额、NSPanel、MenuBarExtra、设置、通知、存储、恢复、多显示器和无障碍 Contract 已批准；皮肤系统不得改变 |
| 2026-08-11 | 皮肤范围 | 内置皮肤 + 本地选择或拖放导入；无在线商店、账号、云同步或付费 |
| 2026-08-11 | 皮肤边界 | 声明式 Theme Tokens 与固定核心语义组件；首版只用标准布局，未来只能引用应用所有的受审核 Profile，不得提供任意布局或改变交互语义 |
| 2026-08-11 | 皮肤包 | ZIP 兼容 `.incomeclocktheme`，严格 schema、媒体白名单和原子安装 |
| 2026-08-11 | 皮肤存储 | 用户皮肤位于 Application Support/Themes，当前选择保存稳定 `themeId` |
| 2026-08-11 | 安全回退 | 皮肤缺失、损坏或不兼容时自动使用不可删除的内置默认皮肤 |
| 2026-08-11 | 提示声音 | 仅离散事件、全局可关闭，默认关闭，不参与业务 |
| 2026-08-11 | 0.6 首版范围 | 仍只实现约 320 × 190 pt 标准面板、A「暖屿」与 B「窗边搭子」；异形面板和多个布局模板不进入首版 |
| 2026-08-11 | 能力分级 | 使用版本化 `standard-theme`、`shaped-panel`、`layout-profile`、`animated-decoration`、`sound-pack`；首版只宣告 `standard-theme@1` |
| 2026-08-11 | 能力协商 | 未知 required 拒绝；未知 optional 仅在完整标准降级有效时忽略；0.5 包缺字段时保持标准皮肤兼容 |
| 2026-08-11 | Profile 所有权 | Theme、PanelPresentationProfile 与 LayoutProfile 由应用解释或实现；皮肤只能声明 Token、白名单资源并引用受支持 ID |
| 2026-08-11 | 异形安全 | 未来形状由透明原生面板与受审核遮罩/Profile 实现，应用保证安全区、命中测试、拖动、窗口约束和无障碍 |
| 2026-08-11 | 展示层预留 | 固定尺寸、圆角外壳和组件排列归展示层 Profile，不进入计薪 Store、状态机或权威数据模型 |
| 2026-08-11 | 0.6 批准 | 产品方批准 0.6 作为产品与原生架构基线；版本保持 0.6，进入技术设计阶段 |
| 2026-08-15 | DST v1 安全策略 | 当前工作日的本地时间必须存在且唯一；不静默校正或猜测；错误时不发布业务 ViewState/success，保留数据并允许用户调整后重试；Settings 保存前必须拒绝无效日程 |
| 2026-08-16 | S4R-003 延期 | 因缺少物理外接显示器，将真实多显示器矩阵标记为 `deferred` 并移至发布候选版/正式发布前硬门槛；不代表验收通过，不授权 Stage 5 或发布 |

DST v1 产品决策已经通过 `PD-001` 批准；S4R-003 延期边界由 `PD-002` 记录。由于 Product 0.7 的不可变内容快照和可重放差异缺失，Spec 0.8 必须接受完整文档 re-review，不能据 PD-001 或当前文件名推定其余内容已完成增量证明。Spec 0.8 尚未标记 approved；任何 Contract 或决策记录都不自动授权实现阶段。

## 25. Spec Review Checklist

审查日期：2026-08-16。审查对象：Spec 0.8 完整候选文档。PD-001 只证明 Product 0.7 的历史批准事件；因旧版内容快照缺失，本候选不能按增量方式复核，须以 candidate 快照和 SHA-256 manifest 为固定输入执行完整文档 re-review。此处仅为修复后自查，不代表独立 Review、批准或实现验证。

- [x] 产品形态统一为原生 macOS 13+ 菜单栏与桌面悬浮应用。
- [x] 浏览器、网页运行时、Web 存储、Web 通知和 Web 动画规则已移除。
- [x] WidgetKit 被明确排除为实时金额载体。
- [x] 悬浮面板、菜单栏和设置窗口职责清晰且不重复业务逻辑。
- [x] 首版标准面板尺寸、默认位置、拖动、吸附、锁定、置顶、全屏、Space 和多显示器恢复规则明确。
- [x] 工资整数分、权威时间戳、实时三位与结算两位的独立舍入规则一致。
- [x] DST gap/fold 均要求本地时间存在且唯一，禁止系统默认归一化、静默平移或任意选择重复实例。
- [x] 日程时间错误不增加第八个业务状态，不发布 BusinessViewState/success，保留原始数据并允许用户修改后重试。
- [x] Settings 保存的 `SaveSettingsPlan` 在持久化前完整构造；preflight/target/conflict/I/O 零提交、commit 后非抛出发布和 revision 恢复语义一致。
- [x] UI 只突出“今日已获得”，无面向用户的工资速度或收入速率要求。
- [x] 原生动画只触发权威重算，不累计工资或参与最终结算。
- [x] 倒计时按时间戳计算且不参与工资计算。
- [x] 七个状态在流程、信息架构、恢复和验收标准中一致。
- [x] 主动下班确认、到点停止、完成结算和祝福行为明确。
- [x] 原生本地存储、写入失败、损坏恢复和破坏性重置边界明确。
- [x] 有效未完成 Today 跨日时保留并阻止新日打卡；旧日完成后只有用户确认“开始今天”才删除，失败不丢记录。
- [x] “开始今天”的单一 command timestamp、全量无写入 preflight、DST/target 构造、revision token 与单一原子提交顺序已固定；任一失败保留旧 Today。
- [x] Today 日期关系使用 snapshot timezone 与冻结 command timestamp；东/西时区切换、dateKey 三分支、次日/多日 clockOut 边界已精确化。
- [x] Settings 保存流程在 Product/UI/Technical 中统一绑定单一 BusinessCommandContext；目标状态/ViewState/success 在 commit 前构造，错误、重试、revision 和 success 不跨命令上下文。
- [x] Settings `missing`/`damaged` 与 Today 有效/损坏的组合矩阵、错误优先级、重置/替换转移已固定；只有 missing + 无 Today 发布 `UNCONFIGURED`/`¥0.00`。
- [x] macOS 通知的权限、安排、取消、去重、失败和恢复规则一致。
- [x] 开机启动默认关闭，应用退出、重启、睡眠与唤醒规则明确。
- [x] MenuBarExtra 与悬浮面板共享同一 Store、纯函数和 Repository。
- [x] Implementation Boundaries 支持确定性时间、存储、通知与窗口测试。
- [x] Theme Store 与业务 Store 依赖方向单向且隔离；换肤不能改变计薪、打卡、通知、持久化或恢复。
- [x] 首版皮肤只使用固定标准布局、核心语义组件、受限 Theme Tokens、媒体资源和应用预实现动画预设。
- [x] 皮肤包 schema、ID、版本、覆盖、降级、作者冲突与应用兼容规则明确。
- [x] 声明式安全边界禁止代码、脚本、可执行文件、远程资源和导入后自动执行。
- [x] 路径、链接、文件类型、容量、图片、声音、未知字段、临时验证与原子安装规则明确。
- [x] 内置默认皮肤、Application Support/Themes、稳定 themeId、删除与损坏回退规则一致。
- [x] 浏览、预览、导入、拖放、切换、删除、恢复、重复安装、升级与失效流程完整。
- [x] 无障碍质量底线对拒绝、钳制、安全 Token 和默认回退分别规定了处置策略。
- [x] 五类版本化能力的含义、首版支持状态和“不得伪装支持”规则明确。
- [x] `requiredCapabilities`、`optionalCapabilities`、`panelProfile`、`layoutProfile`、`visualMask` 的协商、拒绝与回退语义明确。
- [x] 缺少 0.6 能力字段的 0.5 皮肤继续按 `standard-theme@1` 解释，不要求重新打包。
- [x] Theme、PanelPresentationProfile、LayoutProfile 的应用所有权和业务隔离边界明确。
- [x] 异形窗口的透明区域点击穿透、安全区、拖动入口、可靠恢复入口、显示器约束和无障碍底线明确。
- [x] 未来布局可重排但不能缺失或改变核心语义组件，用户皮肤不能提供任意坐标或控件树。
- [x] 320 × 190、标准外壳和组件排列被归入展示层抽象，不进入计薪 Store、状态机或权威数据模型。
- [x] 0.5 的严格 schema、安全验证、原子安装、启动回退和业务隔离没有被未来能力削弱。
- [x] A「暖屿」与 B「窗边搭子」继续共享相同标准面板、布局、语义组件和点击区域。
- [x] `UI_SPEC.md` 0.5 当前文本包含 S4R-003 延期和发布硬门槛；其完整视觉与 Theme Contract 仍须在 full-document re-review 中复核。
- [x] 验收标准覆盖产品形态、窗口、设置、收入、倒计时、状态、通知、菜单栏、无障碍、皮肤系统和当前兼容架构。
- [x] 测试矩阵覆盖多显示器、系统边界、并发操作、恢复、通知、皮肤安全、能力协商、旧包兼容、Profile 隔离与文案审计。
- [x] 未来 shaped panel、多个 LayoutProfile、高级动画和声音测试已明确标为占位，不属于首版完成条件。
- [x] 测试均标记为预期，未声称代码、UI 或测试已经完成。
- [x] finding 级 `deferred` 与阶段级合法状态已区分；延期原因、风险、补验清单和禁止发布条件完整。
- [x] S4R-003 已从 Stage 5 开发前门槛移至发布候选版/正式发布前硬门槛，但未被标记 closed、passed 或 verified。
- [x] Stage 1～3 verified 已明确限定为旧 approved Contract 的历史证据；candidate 获批后必须先完成并独立验证 Stage 4D Contract Delta，才能另行申请 Stage 5。
- [x] YAML frontmatter 为 0.8，`status` 为 `review`，`approved_on` 与 `last_verified` 为 `null`，并如实记录 PD-001 历史批准事件、旧版内容证据缺口和 full-document re-review 方法。

自查结论：Product 0.8 PD2RR-007 repaired candidate 保留七业务状态、金额公式、窗口预期、S4R-003 发布硬门槛和 Stage 4D 门禁，并将 Settings 保存收口为 commit 前完整 `SaveSettingsPlan`、失败零提交、commit 后无首次可失败推导。PD2RR-007 仅为 `ADDRESSED / AWAITING INDEPENDENT RE-REVIEW`；PD2RR-001/003/004/005/006 未由本修补任务关闭，PD2RR-002 的既有关闭结论不变。新 candidate 必须按完整文档重新审查。Stage 4D 与 Stage 5 均未获实施授权，Contract 未标记 approved。
