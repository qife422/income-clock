---
title: 可视收入打卡机 UI Contract
document_type: ui_spec
version: "0.5"
status: review
last_updated: 2026-08-17
last_verified: null
approved_on: null
review_scope: "UI 0.5 PD2RR-007 recovery transaction repair candidate 完整文档 re-review"
historical_approved_version_record: "0.4（PD-001 批准事件仍有效；不可变内容快照缺失）"
proposed_supersedes_version: "0.4"
source_spec_version: "0.8"
review_method: "full_document_re_review"
candidate_snapshot_manifest: "contract_snapshots/2026-08-17-pd2rr-007-recovery-transaction-repair-candidates/SHA256SUMS"
selected_direction: "A 暖屿"
first_validation_theme: "B 窗边搭子"
future_direction: "C 刻度间"
---

# 可视收入打卡机 — UI Contract

> `PD-001` 保留 UI Spec 0.4 曾获批准的历史事实，但项目没有该版本的不可变内容快照或可重放差异，不能证明 UI 0.5 只包含 `PD-002` 增量。因此 UI 0.5 必须作为完整文档重新审查；当前 PD2RR-007 recovery transaction repaired candidate 包含 S4R-003 发布硬门槛、旧工作日结算 UI、准确 Product 0.8 来源、Settings 单 command context 与普通保存/损坏替换共用的 commit 前完整 plan UI 规则，以及 Stage 4D 在 Stage 5 A UI 前的实施门禁。状态仍为 `review`、`approved_on: null`，等待独立全文复审，不授权修改代码、进入 Stage 4D、Stage 5 或发布。

## 1. 文档范围与已确认决策

### 1.1 首版范围

- 首版仅设计并实现 `standard-theme@1`。
- 首版只有一个标准 `PanelPresentationProfile`：`standard.panel.320x190.v1`。
- 首版只有一个标准 `LayoutProfile`：`standard.layout.income-card.v1`。
- A「暖屿」是不可删除的内置默认皮肤。
- B「窗边搭子」是首版换肤架构验证皮肤。
- A、B 使用完全相同的面板尺寸、安全区、语义组件、组件坐标、焦点顺序和点击区域；差异仅来自允许的 Theme Tokens、声明式资源和应用预实现动画预设。
- C「刻度间」只保留为未来专业皮肤方向记录，不进入首版设计、实现、UI 验收或完成定义。
- UI 不展示每秒收入、工资速度、`+¥x/秒` 或其他收入速率。

### 1.2 继承与优先级

本文以 `SPEC.md` 0.8 候选稿为当前产品来源。由于旧批准版本缺少不可变内容快照，不能声称已用增量差异证明全部历史 UI 约束原样保留；full-document re-review 必须直接检查本文件全部内容。发生冲突时：

1. `SPEC.md` 的产品、业务、安全和生命周期 Contract 优先。
2. 本文负责首版 standard profile 的尺寸、布局、文案、视觉、动效和 UI 验收。
3. 概念板只提供已确认的视觉方向，不是逐像素实现稿；其中的生成式文字、近似尺寸和示意图标不覆盖本 Contract。

### 1.3 已保存的视觉依据

- [A「暖屿」原始概念板](design/references/a-warm-island-concept.png) — 1448 × 1086 PNG，SHA-256 `e002cb797f65ad02a42f07c3265f65c76bfe5edc88646d9c81487d289ce5c48f`。
- [B「窗边搭子」原始概念板](design/references/b-window-companion-concept.png) — 1448 × 1086 PNG，SHA-256 `f084fd0cdebd419ed2eb1cee199803212152bb070ba552bd516c1e7363a6dbb6`。

两张文件均为原始概念图，不包含 Codex/ChatGPT 界面、浏览器边框或桌面截图。

## 2. Profile 边界与未来兼容

### 2.1 首版 Profile

| Profile | 首版值 | 所有者 |
|---|---|---|
| `standard.panel.320x190.v1` | 固定 `320 × 190 pt`、标准圆角矩形、标准安全区与命中区域 | 应用展示层 |
| `standard.layout.income-card.v1` | 本文第 3–7 节定义的语义组件排列与焦点顺序 | 应用展示层 |
| `standard-theme@1` | 本文第 10–12 节定义的 Token、资源与预设范围 | Theme 系统 |

`320 × 190 pt`、本文安全区和当前组件排列只属于上述 standard profiles，不是所有未来皮肤永远不可改变的全局限制。

### 2.2 隔离规则

- 业务 Store、计薪函数、打卡状态机、权威时间、最终金额、通知、存储、恢复和权限逻辑不得读取尺寸、布局、遮罩、装饰或 Theme Token。
- 展示层只消费只读业务 View State；皮肤切换不能生成业务命令。
- 面板尺寸、布局和命中区域由 Profile Resolver 提供，不能散落在业务代码或权威数据模型中。
- A、B 切换期间，相同权威输入必须得到完全相同的状态、金额、进度、倒计时和结算结果。

### 2.3 未来 Profile

未来的异形、竖向、胶囊、角色轮廓、游戏 HUD 或其他排列只能通过应用新增、审核并版本化的 `PanelPresentationProfile`/`LayoutProfile` 实现。皮肤只能引用受支持的 Profile ID，不能提供任意 SwiftUI、控件树、坐标或交互逻辑。

本 UI Contract 不设计 `shaped-panel`、多个 `LayoutProfile`、Alpha Mask 或透明点击穿透细节。相关接口仅继承当前 Product Contract `SPEC.md` 0.8 第 20 节，不进入首版 UI 验收与完成条件。

## 3. 标准悬浮面板几何 Contract

### 3.1 坐标系统与窗口

- 坐标原点为面板内容区域左上角，单位为 point。
- 面板内容尺寸固定为 `320 × 190 pt`，首版不可缩放。
- 外轮廓圆角由 Theme Token 提供，但限制在 `14–18 pt`；应用默认和安全回退为 `16 pt`。
- 面板必须裁切所有背景和装饰资源；阴影绘制在窗口视觉外缘，但不扩大业务内容或点击区域。
- `contentSafeArea = (x: 12, y: 8, width: 296, height: 172)`。

### 3.2 固定区域

| 区域 | Frame `(x, y, w, h)` | 内容 |
|---|---|---|
| 顶部状态区 | `(12, 8, 232, 28)` | 状态图标、状态文案；同时作为主要拖动区域 |
| 设置按钮 | `(252, 8, 28, 28)` | 打开设置 |
| 隐藏按钮 | `(280, 8, 28, 28)` | 隐藏面板，不退出应用 |
| 金额区 | `(12, 38, 296, 60)` | “今日已获得”、金额、精度语义 |
| 进度与辅助信息区 | `(12, 100, 228, 42)` | 计划进度、倒计时、计薪时长 |
| 安全装饰插槽 | `(248, 92, 60, 50)` | 非交互状态装饰；A 可留空，B 使用角色资源 |
| 主要操作区 | `(12, 148, 296, 32)` | 当前主操作或确认操作组 |

固定间距：水平内容边距 `12 pt`；主区块垂直间距 `4–8 pt`；并列内容间距 `8 pt`；图标与文字间距 `5 pt`。

### 3.3 拖动与命中区域

- 主要拖动区域为 `(12, 8, 232, 28)`；状态文本保持可访问，但不接受点击。
- 除明确控件外的面板背景可以辅助拖动；设置、隐藏、主按钮、确认按钮和任何链接区域必须从拖动命中中排除。
- 设置和隐藏按钮的固定点击区域均为 `28 × 28 pt`，图标视觉尺寸 `13–14 pt`。
- 主要按钮点击区域固定为 `296 × 32 pt`。
- 确认界面中“取消”为 `(12, 148, 92, 32)`，“确认下班”为 `(112, 148, 196, 32)`。
- 装饰插槽始终 `allowsHitTesting(false)` 或使用等效原生命中隔离，不得包含可访问操作或改变鼠标形状。
- 锁定面板位置时只关闭拖动；所有控件命中区域保持不变。

### 3.4 层级

从后到前固定为：面板材质/背景 → 背景纹理 → 安全装饰插槽 → 语义内容 → 控件 → 焦点环/系统提示。皮肤不得改变层级。

## 4. 标准 LayoutProfile

### 4.1 顶部状态区

- 左对齐状态图标和状态文案，最大内容宽度 `220 pt`。
- 状态图标视觉框 `12 × 12 pt`，使用 SF Symbols 或应用内置等效资源。
- 状态文案为单行；应用文案不会超过 12 个中文字符，不截断。
- 设置图标使用 `gearshape`，隐藏图标使用 `eye.slash` 或语义等效的系统图标。
- 控件 hover 显示 `4 pt` 内边距的圆角底色；pressed 透明度降低至 `0.82`；键盘焦点使用应用强制焦点环。

### 4.2 金额区

- “今日已获得”位于金额上方，水平居中，固定文案，不允许皮肤替换。
- 金额标签 Frame 为 `(12, 38, 296, 13)`，金额 Frame 为 `(12, 50, 296, 36)`，精度副标题 Frame 为 `(12, 86, 296, 12)`。
- 金额基线位于 `y = 80 pt`；整数和货币符号右对齐到全局 `x = 178 pt` 的小数点锚位，小数点与小数部分向右展开。
- 小数点锚位在两位与三位金额之间保持不变，避免计薪停止时整体横跳。
- `EARNING` 下方显示“实时收入估算”；`AWAITING_CLOCK_OUT` 显示“已停止计薪”；其他状态不显示精度副标题，除非状态表明确要求。
- 金额容器宽度固定 `280 pt`，不得滚动、截断、省略或换行。

### 4.3 进度区

- 进度标题行高度 `12 pt`：左侧“计划工作进度”，右侧整数百分比 `0%–100%`。
- 默认线性轨道 Frame 为 `(12, 114, 228, 4)`；圆角为轨道高度的一半。
- 辅助信息行 Frame 为 `(12, 122, 228, 20)`。
- 辅助信息左侧为距离开始/距离下班/停止提示，右侧为“已计薪 HH:MM:SS”。
- 左右字段之间至少 `8 pt`；空间不足时优先完整显示计时值，标签可使用短文案，但不得只剩数字而失去语义。
- 进度是计划工作日进度，不使用收入比例。

### 4.4 操作区

- 主要按钮高 `32 pt`，水平填满操作区，文字居中。
- 可选 leading SF Symbol 视觉尺寸 `12 pt`，但按钮必须保留完整文字。
- 按钮状态包括 normal、hover、pressed、keyboardFocus、disabled、loading、destructive。
- loading 时保留原按钮宽度，使用系统小型进度指示与“正在保存…”；不得先显示成功状态。

## 5. 七个产品状态 UI 映射

| 状态 | 状态图标与文案 | 金额区 | 进度/辅助区 | 主操作 |
|---|---|---|---|---|
| `UNCONFIGURED` | `gearshape`；“待完成设置” | `¥0.00`；不显示实时估算 | 进度显示 `—`；“设置工资与工作时间” / “尚未计薪” | “打开设置” |
| `READY` | `circle`；“今日未打卡” | `¥0.00` | 显示当前计划进度；开始前“距离开始 HH:MM:SS”，计划中“计划进行中”，结束后“今日计划已结束”；右侧“已计薪 00:00:00” | 下班时间前“打卡上班”；下班时间后 disabled“今日无法打卡” |
| `CLOCKED_IN_WAITING` | `clock`；“已打卡 · 等待开工” | `¥0.000`，静止；不显示实时估算 | `0%`；“距离开始 HH:MM:SS” / “已计薪 00:00:00” | “打卡下班” |
| `EARNING` | `circle.fill`；“计薪中” | 三位实时金额；“实时收入估算” | 计划进度；“距离下班 HH:MM:SS” / “已计薪 HH:MM:SS” | “打卡下班” |
| `AWAITING_CLOCK_OUT` | `exclamationmark.circle.fill`；“计薪已停止” | 两位停止金额；“已停止计薪” | `100%`；“请打卡下班” / 实际计薪时长 | “打卡下班” |
| `COMPLETED` | `checkmark.circle.fill`；“今日已完成” | 两位最终金额；不运行动画 | 替换为结算数据布局 | 同日无主按钮；旧工作日显示完整祝福与“开始今天” |
| `RECOVERY_REQUIRED` | `exclamationmark.triangle.fill`；“记录需要恢复” | 不显示金额标签或金额 | 替换为错误说明；不展示未经验证数据 | destructive“重置今日记录” |

状态不能只依靠颜色；图标和文案始终同时变化。

`UNCONFIGURED` 仅对应 Product 0.8 第 7.2 节的 Settings `missing` + 无有效 Today。Settings `damaged` 永远不渲染上表的 `UNCONFIGURED`/`READY` 或 `¥0.00`；它使用第 7.3 节的独立 Settings recovery 表面。

旧日有效 Today 不增加新业务状态：未完成时仍使用 `AWAITING_CLOCK_OUT`，但顶部明确显示“上一个工作日未完成 · {date}”，辅助区显示“计薪已于 {scheduledEnd} 停止”，主要操作仍为“打卡下班”；当前日期的上班操作隐藏或 disabled。次日或多日后成功下班都仍使用 `COMPLETED`，结算信息同时标明旧工作日日期和真实下班日期/时间；金额仍截止于旧日 `scheduledEndAt`，并按第 6.3 节提供进入当前日期的明确动作。

DST v1 日程时间错误不是第八个业务状态。普通启动/恢复无已验证旧 ViewState 时，面板替换业务主体：隐藏金额、进度、倒计时、角色和打卡操作；显示 `exclamationmark.triangle.fill`、标题“今日工作时间无法确定”、说明“当前时区下，设置的上班或下班时间不存在或会出现两次。请调整时间后重试。”以及主操作“打开设置”。若错误来自“开始今天” preflight，不展示这个替换主体，而是按第 6.3 节保留旧 `COMPLETED` 结算与金额、附命令错误和打开设置入口。两种路径都必须明示原始数据未改变。

### 5.1 READY 的时间分支

- `now < scheduledStartAt`：进度 0%，显示距离开始。
- `scheduledStartAt ≤ now < scheduledEndAt`：显示计划进度和“计划进行中”；仍可打卡上班，迟到规则由业务层决定。
- `now ≥ scheduledEndAt`：显示 100% 和“今日计划已结束”；主按钮禁用，辅助说明“下班时间后不能首次打卡”。

### 5.2 状态转换反馈

- 上班写入成功：状态立即切换为等待或计薪态；顶部状态区可显示一次 `1.5 s` 的“上班打卡成功”，随后恢复状态文案。
- 下班写入成功：直接进入 `COMPLETED`，不显示中间虚假成功页。
- 自动停止：下一次可见渲染直接进入 `AWAITING_CLOCK_OUT`，不播放追赶动画或数字庆祝。
- 状态成功反馈只在持久化成功后出现，并通过单次 VoiceOver announcement 播报。

## 6. 主动下班确认与结算

### 6.1 主动下班确认

确认视图在同一 `320 × 190 pt` 面板内替换金额、进度和辅助内容，顶部状态区保留原状态：

- 标题 Frame `(20, 46, 280, 22)`：“确定现在下班吗？”
- 预计金额 Frame `(20, 72, 280, 36)`：两位小数，例如 `预计结算 ¥126.35`。
- 预计时长 Frame `(20, 112, 280, 18)`：`预计计薪 03:47:18`。
- 次要说明 Frame `(20, 132, 280, 12)`：“确认时将按最新时间重新结算”。
- 底部按钮使用第 3.3 节固定 Frame：“取消”与“确认下班”。

确认页打开期间，预计金额和时长按权威时间更新，但不触发 VoiceOver 高频播报。取消返回原状态；确认按钮进入 loading 后禁止重复点击。写入失败时保留确认页，在按钮上方显示“下班记录保存失败，请重试”，并恢复按钮可用。

`AWAITING_CLOCK_OUT` 已完成权威结算，因此点击“打卡下班”不再展示预计金额确认页；按钮直接进入“正在保存…”，记录真实 `clockOutAt`。写入成功进入 `COMPLETED`，写入失败留在 `AWAITING_CLOCK_OUT` 并显示“下班记录保存失败，请重试”，两位停止金额保持不变。

### 6.2 COMPLETED 结算布局

- 金额区 Frame 保持 `(12, 38, 296, 48)`，显示两位最终金额。
- 结算信息区使用 `(12, 91, 228, 48)`：
  - 第一行：`计薪时长 HH:MM:SS`。
  - 第二行左侧：`上班 HH:MM:SS`。
  - 第二行右侧：`下班 HH:MM:SS`。
- B 的结算装饰仍限制在 `(248, 92, 60, 50)`。
- 祝福区 Frame `(12, 145, 296, 33)`，最多两行，文案固定为：`今日辛苦啦，喜提 ¥{earnedAmount}，今天的努力已经成功变现。`
- `{earnedAmount}` 始终为两位小数。
- 结算页不显示动态倒计时、进度条、滚轮或循环庆祝动画。

### 6.3 旧工作日结算与“开始今天”

- 旧/当日/未来关系必须由业务层使用单一 command timestamp 在 Today snapshot timezone 中计算，UI 不得使用当前系统时区重新比较。`dateKey < recordCurrentDateKey` 显示旧日视图，`=` 显示当日视图，`>` 显示 `RECOVERY_REQUIRED`。
- 当 `COMPLETED.dateKey` 被业务层判定为旧日时，结算视图必须显示旧工作日日期，并保留最终金额、计薪时长、上下班时间和祝福。
- 旧工作日结算使用金额区 `(12, 38, 296, 42)`、结算信息区 `(12, 82, 296, 42)`、祝福区 `(12, 126, 296, 20)` 和操作区 `(12, 148, 296, 32)`；隐藏 B 装饰，避免遮挡日期、结算或按钮。
- 底部增加“开始今天”操作；操作前确认文案为：“开始今天将清除上一工作日结算。首版不保留历史记录。”，按钮为“取消”与 destructive“清除并开始今天”。
- Settings damaged 时“开始今天” disabled，辅助说明“请先修复设置，再开始今天”，并提供“打开设置”；不得先删除旧结算。Settings missing 允许执行，但成功目标只能是 `UNCONFIGURED`。
- 取消后继续显示旧工作日结算。用户点击确认时，业务层采样唯一 command timestamp；UI 进入“正在检查今日设置…”，但旧结算数据仍作为可恢复的底层内容，不得先切换到 `¥0.00`。
- 业务层必须先完成 Settings 分类/验证、command date/timezone 冻结、旧日关系检查、当前工作日解析及目标 ViewState/写入构造；Settings valid 时还必须先完成日程解析与 DST gap/fold 检查，Settings missing 时该步骤必须以明确 `notApplicable(settingsMissing)` 完成。只有全部成功后才切换为“正在开始今天…”并发起单一原子提交。
- 任一 preflight typed error（Settings 损坏、`ScheduleTimeError`、target date 未前进等）、revision/token 冲突或删除失败，都必须退出 loading，保留旧 `COMPLETED`、全部结算数据和可重试入口。日程错误显示“无法开始今天，今日工作时间无法唯一确定，上一工作日记录已保留”；提交错误显示“无法开始今天，上一工作日记录未被删除”。
- 原子提交成功后才发布预计算的目标：Settings valid 是 `READY`，Settings missing 是 `UNCONFIGURED`。UI 不允许在提交后再首次解析日程或以二次读取的时区重新推导。
- 旧日 `AWAITING_CLOCK_OUT` 不显示“开始今天”，不能绕过下班打卡直接删除有效未完成记录。

## 7. RECOVERY_REQUIRED 与破坏性确认

### 7.1 恢复视图

- 安全装饰插槽隐藏，角色不得出现。
- 错误图标 Frame `(148, 43, 24, 24)`。
- 标题 Frame `(20, 72, 280, 20)`：“今日记录无法安全恢复”。
- 说明 Frame `(20, 96, 280, 38)`，最多两行：“记录不完整或校验失败，暂时无法确定今日收入。”
- 原因摘要使用一行可读错误类别，不展示损坏记录中的未经验证金额。
- 操作区显示 destructive“重置今日记录”。

### 7.2 重置确认

重置确认替换面板主体：

- 标题：“重置今日记录？”
- 说明：“这会删除今天的打卡记录，但保留工资与工作时间设置。此操作无法撤销。”
- 次要按钮：“取消”。
- destructive 主按钮：“确认重置”。
- Today 删除成功后必须按 Settings typed result 转移：valid 且当前日程严格解析成功才进入 `READY`；missing 进入 `UNCONFIGURED`；damaged 进入第 7.3 节 Settings recovery；日程解析失败显示 typed 日程错误。Today 删除失败时返回恢复视图并显示“重置失败，原记录未被删除”。

### 7.3 Settings damaged 恢复表面与动作

- 无有效 Today 时，面板替换业务主体：标题“设置数据无法读取”，说明“原设置文件未被改写”，隐藏金额、进度、倒计时、角色与打卡。提供“打开设置”和 destructive“重置设置…”；不显示 `UNCONFIGURED`、`READY` 或 `¥0.00`。
- 有效 Today 时，面板继续完整显示 Today snapshot 推导的状态和金额，顶部附非阻断 banner“设置数据需要修复”及“打开设置”。Today 的下班仍可执行；“开始今天”和新日打卡 disabled。
- Settings 与 Today 同时 damaged 时，第 7.1 节 Today `RECOVERY_REQUIRED` 占据主体，并附次级“设置数据也无法读取”说明及单独设置恢复入口；不得只显示其中一个导致另一个原文件被忽略。
- “重置设置”需二次确认：“这会将无法读取的设置重置为未配置，不会删除今日记录。”成功后，有效 Today 仍按 snapshot 显示，无 Today 才进入 `UNCONFIGURED`；不得无条件进入 `READY`。
- 用户也可通过“确认替换设置”提交新输入；该动作与普通保存共用第 15.3 节同一个 `SaveSettingsPlan`/commit 协议和单一 command context。UI 先显示“正在检查…”，并保留 damaged banner、输入及命令前最后已验证的 Panel/MenuBar/ViewState；Application 必须在 Repository 前完成 Settings validation、schedule parsing、DST gap/fold、Today typed load、目标业务状态/完整 ViewState、success event 与 commit intent 构造，plan 完整后 UI 才显示“正在保存…”。任一 preflight/target/conflict/I/O failure 都零 Settings 写入、零 revision 推进，恢复上述旧表面且不显示 success。commit 成功后只一次、非抛出地发布 plan 的 target/committed revision/success：有效 Today target 仍按 snapshot，无 Today target 已预构造为 `READY`，Today damaged target 仍为 `RECOVERY_REQUIRED`；commit 后不得首次解析日程、推导状态或 reconcile。
- 处理双损坏时：先重置 Today 但 Settings 仍 damaged，主体转为 Settings recovery；先重置/替换 Settings 但 Today 仍 damaged，继续 Today `RECOVERY_REQUIRED`。每次失败只显示对应 record 的错误，不伪报另一 record 已恢复。

## 8. 金额排版与宽度边界

### 8.1 字体与格式

- A 金额字体：系统 `SF Pro Display`，启用 tabular/monospaced digits，默认 `34 pt / Medium`。
- B 金额字体：系统 rounded design，启用 tabular/monospaced digits，默认 `34 pt / Semibold`。
- 货币符号、整数、千位分隔符、小数点和小数位使用同一基线。
- 使用本地化千位分隔符，但首版 CNY 示例固定为 `¥1,000.000`；不使用科学计数法。
- 三位实时金额和两位结算金额必须有“实时收入估算”或停止/结算语义，不让第三位被误认为正式人民币结算精度。

### 8.2 确定性字号适配

应用按以下候选字号从大到小选择第一个能在 `280 pt` 容器内保留左右各 `4 pt` 空白的字号：`34, 32, 30, 28, 26 pt`。不得使用任意连续缩放或小于 `26 pt`。

- 典型 `¥0.000`、`¥123.456`、`¥999.999` 和 `¥1,000.000` 应使用 `34 pt`。
- 接近上限的 `¥999,999.990` 可降至 `32 pt` 或更小的第一个适配档位。
- 字号只在整数位数或辅助功能文字比例改变时切换；同一位数范围内不得随每帧抖动。
- 若安全字体替换后仍无法适配，使用应用默认金额字体重新测量；不得裁切或缩写金额。

### 8.3 进位边界

- `¥999.999 → ¥1,000.000` 时，小数点锚位保持 `x = 178 pt`。
- 新增千位分隔符与整数位作为一次原子数字组变更；不得先显示错误中间字符串。
- 容器、标签、进度和按钮位置不移动。
- `¥99,999.999 → ¥100,000.000` 采用同一规则，并触发确定性字号档位复测。

## 9. Odometer 与状态动效 Contract

### 9.1 权威刷新

- 仅 `EARNING` 且面板可见时使用原生 animation timeline/display link 触发重算。
- 每次渲染从当前权威时间重新获得目标 `liveEarnedMilliYuan`；动画不累计工资。
- 数值未跨越 `¥0.001` 时，不滚动数字；刷新帧率本身不制造变化。

### 9.2 数字滚动参数

| 参数 | A 暖屿 | B 窗边搭子 | 允许范围 | 安全回退 |
|---|---:|---:|---:|---:|
| 单次位移时长 | `160 ms` | `180 ms` | `120–220 ms` | `160 ms` |
| 相邻位最大错峰 | `8 ms` | `10 ms` | `0–12 ms` | `0 ms` |
| 位移距离 | `0.72 em` | `0.68 em` | `0.5–0.8 em` | `0.65 em` |
| 缓动 | cubic `(0.22, 1, 0.36, 1)` | cubic `(0.22, 1, 0.36, 1)` | 应用白名单 | 同 A |

- 收入增加时数字向上滚入；权威时间校准导致金额降低时向下滚入，不能倒放或伪装上涨。
- 进位链作为同一个 transaction 提交；`12.009→12.010`、`12.099→12.100`、`99.999→100.000` 不得错位。
- 新目标在前一动画结束前到达时，取消未完成目标并从当前视觉位置过渡到最新目标；允许省略中间视觉值，最长不得落后最新目标 `220 ms`。
- 30 FPS、60 FPS、降频和跳帧只影响视觉采样，不改变相同 `now` 的目标值。
- 面板恢复可见或重新聚焦时直接显示当前目标；不逐帧补播后台变化。
- 到达 `scheduledEndAt` 或主动下班持久化成功时，立即取消滚动，在下一次可见渲染显示直接从权威数据得到的两位金额。
- `AWAITING_CLOCK_OUT` 与 `COMPLETED` 不运行动画循环。

### 9.3 Reduce Motion

- 开启 Reduce Motion 时，所有数字 transform、角色位移、呼吸、弹性和滚轮动画禁用。
- 三位实时金额仍在真实值变化时原位更新；允许 `80 ms` 以内、无位移的 opacity crossfade，用户开启“降低透明度”时连该淡化也关闭。
- 状态转换使用即时替换或 `100 ms` 以内无位移淡入。
- VoiceOver 不按帧或每 `¥0.001` 播报。

## 10. A「暖屿」默认皮肤 Token

### 10.1 字体

| 用途 | 字体 | 字号/行高 | 字重 |
|---|---|---|---|
| 状态 | SF Pro Text | `12/16 pt` | Semibold |
| 金额标签 | SF Pro Text | `11/14 pt` | Regular |
| 金额 | SF Pro Display + tabular digits | `34/36 pt` | Medium |
| 精度副标题 | SF Pro Text | `10/12 pt` | Regular |
| 进度与辅助 | SF Pro Text + tabular digits | `10/14 pt` | Medium/Regular |
| 主要按钮 | SF Pro Text | `13/16 pt` | Semibold |
| 结算祝福 | SF Pro Text | `11/15 pt` | Medium |

### 10.2 浅色 Token

| Token | 值 |
|---|---|
| `panel.material` | `hudWindow` 等效系统材质，暖色 tint |
| `panel.background` | `#F6F1E7`，不透明度 `0.96` |
| `surface.raised` | `#FFFDF8` |
| `text.primary` | `#292823` |
| `text.secondary` | `#66635B` |
| `text.tertiary` | `#716E66` |
| `accent.primary` | `#748962` |
| `accent.hover` | `#687C58` |
| `accent.pressed` | `#5E714F` |
| `action.start` | `#A85D43` |
| `action.stop` | `#5F754C` |
| `action.text` | `#FFFFFF` |
| `progress.track` | `#2928231F` |
| `progress.fill` | `#748962` |
| `border.subtle` | `#29282324` |
| `status.ready` | `#73736D` |
| `status.waiting` | `#B68135` |
| `status.earning` | `#5F8A58` |
| `status.awaiting` | `#B97822` |
| `status.completed` | `#5F8A58` |
| `status.error` | `#B84234` |
| `focus.ring` | `#3978D4` |

状态文案始终使用 `text.primary`；`status.*` 只用于状态图标、圆点和非文字强调，因此不能降低小字号文字对比度。

### 10.3 深色 Token

| Token | 值 |
|---|---|
| `panel.material` | `hudWindow` 等效系统材质，暖黑 tint |
| `panel.background` | `#262824`，不透明度 `0.97` |
| `surface.raised` | `#33352F` |
| `text.primary` | `#F5F1E8` |
| `text.secondary` | `#C2BDB2` |
| `text.tertiary` | `#A6A197` |
| `accent.primary` | `#A5B98C` |
| `accent.hover` | `#B3C69B` |
| `accent.pressed` | `#94A97D` |
| `action.start` | `#D68567` |
| `action.stop` | `#94AA7D` |
| `action.text` | `#171914` |
| `progress.track` | `#FFFFFF24` |
| `progress.fill` | `#A5B98C` |
| `border.subtle` | `#FFFFFF29` |
| `status.ready` | `#B9B8B1` |
| `status.waiting` | `#E0AE5B` |
| `status.earning` | `#9DC894` |
| `status.awaiting` | `#E5AB53` |
| `status.completed` | `#9DC894` |
| `status.error` | `#F27B69` |
| `focus.ring` | `#74A8F5` |

深色模式同样由 `text.primary` 绘制状态文案，状态色只用于图形强调。

### 10.4 形状与层次

- 面板圆角 `16 pt`。
- 边框 `1 pt`，使用 `border.subtle`。
- 按钮圆角 `8 pt`。
- 进度轨道高 `4 pt`，圆角 `2 pt`。
- 阴影：浅色 `y: 6, blur: 20, spread: 0, #000000 18%`；深色 `y: 6, blur: 22, spread: 0, #000000 28%`。
- 背景不使用渐变；允许不超过 `4%` 不透明度的静态纸感纹理，但默认皮肤首版使用纯材质，不依赖纹理资源。

## 11. B「窗边搭子」验证皮肤 Token 与资源

B 只替换本节列出的 Token 与资源；第 3–9 节全部保持不变。

### 11.1 字体与形状差异

- 正文继续使用 SF Pro Text，字号和行高与 A 完全一致。
- 金额使用系统 rounded design + tabular digits，`34/36 pt`、Semibold。
- 面板圆角 `18 pt`，按钮圆角 `10 pt`，进度轨道 `5 pt`。
- 阴影：浅色 `y: 7, blur: 22, #4C3825 18%`；深色 `y: 7, blur: 24, #000000 32%`。

### 11.2 浅色差异 Token

| Token | 值 |
|---|---|
| `panel.background` | `#F3E8D6`，不透明度 `0.97` |
| `surface.raised` | `#FFF8EC` |
| `text.primary` | `#302B25` |
| `text.secondary` | `#6F655A` |
| `text.tertiary` | `#71675C` |
| `accent.primary` | `#71875A` |
| `accent.hover` | `#667A51` |
| `accent.pressed` | `#5C6F48` |
| `action.start` | `#A95F45` |
| `action.stop` | `#60764D` |
| `action.text` | `#FFFFFF` |
| `progress.track` | `#5C4A3521` |
| `progress.fill` | `#71875A` |
| `border.subtle` | `#6B56352B` |
| `focus.ring` | `#3978D4` |

状态色沿用 A 的应用安全语义色；B 不以角色姿态替代错误、警告或完成颜色。

### 11.3 深色差异 Token

| Token | 值 |
|---|---|
| `panel.background` | `#20262A`，不透明度 `0.98` |
| `surface.raised` | `#2C3337` |
| `text.primary` | `#F6EFE4` |
| `text.secondary` | `#C8BEB1` |
| `text.tertiary` | `#AAA094` |
| `accent.primary` | `#A6B985` |
| `accent.hover` | `#B5C695` |
| `accent.pressed` | `#95A974` |
| `action.start` | `#DE9270` |
| `action.stop` | `#A0B57F` |
| `action.text` | `#171B17` |
| `progress.track` | `#FFFFFF24` |
| `progress.fill` | `#A6B985` |
| `border.subtle` | `#FFFFFF26` |
| `focus.ring` | `#74A8F5` |

### 11.4 角色装饰安全区

- 角色始终裁切在 `(248, 92, 60, 50)`；可见像素必须再内缩 `3 pt`，实际内容不超过 `54 × 44 pt`。
- 资源采用透明 PNG；每个资源至少提供 `120 × 100 px` 的 2x 版本，推荐同时提供 `180 × 150 px` 的 3x 版本。
- 使用 aspect-fit，不拉伸、不自动镜像，不允许像素超出插槽。
- 角色不参与命中测试、VoiceOver、焦点、拖动或业务状态决定。
- 角色与文字/进度最小视觉间隔 `8 pt`；资源经 Alpha 和对比度检查后仍造成干扰时，应用降低至最高 `0.72` opacity；仍不安全则使用空装饰。
- `RECOVERY_REQUIRED`、确认对话和 loading 状态强制隐藏角色。

### 11.5 首版 B 状态资源清单与静态验证

| 插槽 | 浅色 | 深色 | 表现 |
|---|---|---|---|
| `stateDecoration.READY` | 必需 | 必需 | 安静等待，静态 |
| `stateDecoration.CLOCKED_IN_WAITING` | 必需 | 必需 | 已就位，静态 |
| `stateDecoration.EARNING` | 必需 | 必需 | 专注姿态，可用低频预设 |
| `stateDecoration.AWAITING_CLOCK_OUT` | 必需 | 必需 | 提醒姿态，静态，不闪烁 |
| `stateDecoration.COMPLETED` | 必需 | 必需 | 收工姿态，静态 |
| `stateDecoration.UNCONFIGURED` | 可选 | 可选 | 中性静态；缺失则空装饰 |
| `stateDecoration.RECOVERY_REQUIRED` | 禁止 | 禁止 | 使用应用固定错误 UI |

资源必须具有一致角色比例、视角、光源和轮廓密度。文件中不得包含文字、按钮、数字、状态图标或可被误认为可点击的控件。

以下资源已依据 [B「窗边搭子」原始概念板](design/references/b-window-companion-concept.png) 生成并保存。`@2x` 是首版必需资源，`@3x` 是同时交付的高分辨率资源。

| 外观 | 状态 | 相对路径 | 画布 | SHA-256 |
|---|---|---|---:|---|
| 浅色 | READY | `design/assets/b-window-companion/light/ready@2x.png` | 120 × 100 px | `6f189f201614540116278ac72877410acb9513eda29f8d195904cda6c4c32bce` |
| 浅色 | READY | `design/assets/b-window-companion/light/ready@3x.png` | 180 × 150 px | `c0a788674ef0139c34d866d9df3e76df41906db549a94cea992141106669d1d2` |
| 浅色 | CLOCKED_IN_WAITING | `design/assets/b-window-companion/light/waiting@2x.png` | 120 × 100 px | `bbd4d97a7a6de9fffe0cb2fc156e403267c94672544ebd95a242d10556d1b85a` |
| 浅色 | CLOCKED_IN_WAITING | `design/assets/b-window-companion/light/waiting@3x.png` | 180 × 150 px | `62f6b58060e43015f7a1cd8dedbaafe935f8e2421071d42b53f5af076458a5c9` |
| 浅色 | EARNING | `design/assets/b-window-companion/light/earning@2x.png` | 120 × 100 px | `8038c6ccf1a9a7113fc218fdc63a82a17f44b319d4bdfe5bacc9cbea021b268f` |
| 浅色 | EARNING | `design/assets/b-window-companion/light/earning@3x.png` | 180 × 150 px | `e0974718054ae02fda60ed09bada5b1590cd07346b6c596e6ea110195c65cb04` |
| 浅色 | AWAITING_CLOCK_OUT | `design/assets/b-window-companion/light/awaiting-clock-out@2x.png` | 120 × 100 px | `d53c456ebf8d3d837376b99bd56430013e58f0ce9c46343403925be793afbc74` |
| 浅色 | AWAITING_CLOCK_OUT | `design/assets/b-window-companion/light/awaiting-clock-out@3x.png` | 180 × 150 px | `19cde2f14c4ea659706efbcb352931d16942e47cda9e5a9fe6a98ffb44397e58` |
| 浅色 | COMPLETED | `design/assets/b-window-companion/light/completed@2x.png` | 120 × 100 px | `70b708ced93a3b47a3fc8c5dd07673759ff781fec4affc96694960a00cd11a51` |
| 浅色 | COMPLETED | `design/assets/b-window-companion/light/completed@3x.png` | 180 × 150 px | `d3fdbe8172535a4e0e882299a1dd378cdc219d1f25d7d041b8b2c9935fce4eec` |
| 深色 | READY | `design/assets/b-window-companion/dark/ready@2x.png` | 120 × 100 px | `6a7cc58f28c48e4c5a59f65e2350fed7fea7734fba4159aee51caf43cb10bdd1` |
| 深色 | READY | `design/assets/b-window-companion/dark/ready@3x.png` | 180 × 150 px | `cb0f2b74f27ee2e83eaed3af676656cf3dcac89f1a6d945f2246817b660d7e84` |
| 深色 | CLOCKED_IN_WAITING | `design/assets/b-window-companion/dark/waiting@2x.png` | 120 × 100 px | `5b08f4fd769493ab766320fa94981856f2fa2d85e83caa50ce5a4dda466691ff` |
| 深色 | CLOCKED_IN_WAITING | `design/assets/b-window-companion/dark/waiting@3x.png` | 180 × 150 px | `01e69bb6986b4b39fe029177cc0d1eb4df767c16f9a106b50641d03567c63776` |
| 深色 | EARNING | `design/assets/b-window-companion/dark/earning@2x.png` | 120 × 100 px | `2bda9f66d9dda2d0133da917ca2c0d6a1208f8f556b88ac0b7a4bd78359a9fdc` |
| 深色 | EARNING | `design/assets/b-window-companion/dark/earning@3x.png` | 180 × 150 px | `7fbdc790e9733529197b22d64e14a52210ebe2e63332c3eb9500016844b118ce` |
| 深色 | AWAITING_CLOCK_OUT | `design/assets/b-window-companion/dark/awaiting-clock-out@2x.png` | 120 × 100 px | `8fddcce59cd5b24889abff87a0a2e32589c4d47aeb12dc42fc2eee6b87d2a486` |
| 深色 | AWAITING_CLOCK_OUT | `design/assets/b-window-companion/dark/awaiting-clock-out@3x.png` | 180 × 150 px | `3f039d0522634abd0ab44f3c59c91166a402369f45f614fa073805f3d6d74c93` |
| 深色 | COMPLETED | `design/assets/b-window-companion/dark/completed@2x.png` | 120 × 100 px | `145c7b95d20ecebec503852d0c762ba9659b65ce4136c6f46e677127e2e74022` |
| 深色 | COMPLETED | `design/assets/b-window-companion/dark/completed@3x.png` | 180 × 150 px | `54aa6b29461c6dedde445f2ca115f38cefe227f515ef98a0e17c1fe61d79a900` |

静态资源验证（2026-08-11）：

- [x] 10 个必需 `@2x` 文件与 10 个 `@3x` 文件均实际存在，文件名与状态映射一致。
- [x] 全部文件为带 Alpha 通道的透明 PNG；画布四角透明。
- [x] `@2x` 画布均为 `120 × 100 px`，`@3x` 画布均为 `180 × 150 px`。
- [x] 非透明像素边界均位于居中的 `108 × 88 px`（2x）或 `162 × 132 px`（3x）范围内，对应 `54 × 44 pt` 内容安全区；放入 `60 × 50 pt` 插槽时不裁切。
- [x] 视觉检查未发现文字、按钮、数字、状态图标、货币符号或可误认为控件的图形。
- [x] 浅色与深色的五个状态姿态可辨认；角色设计、比例、视角、线条和光源保持一致，深色版本具有独立的轮廓与高光适配。
- [x] 资源仅占固定装饰插槽且不参与命中测试；依据已验证的插槽几何，不会遮挡金额、进度、辅助信息或主要按钮。
- [x] 全部资源可在 Reduce Motion 下直接静态显示，不依赖动画表达状态。

以上为文件、像素边界与人工视觉静态检查，不等同于 SwiftUI 实机渲染或无障碍工具验证；因此 `last_verified` 仍为 `null`，第 18 节实现验收项仍保持未勾选。

### 11.6 B 装饰动画与声音

- 只有 `EARNING` 可启用应用预设 `companionFocus`：垂直位移 `1 pt`、opacity `0.96→1.0`、单程 `1.8 s`、往返后暂停 `2.4 s`，无限重复。
- 该动画不与金额帧同步，不表达工资速度；面板不活跃时暂停。
- Reduce Motion 开启时使用完全静态资源。
- 可选声音映射只允许 `clockInSuccess`、`autoStop`、`settlementComplete`；每个建议 `0.25–1.2 s`，受 `SPEC.md` 容量/格式限制和全局默认关闭开关控制。
- 声音缺失或播放失败不改变视觉、计薪或状态。

## 12. Theme Token 允许范围、钳制与回退

### 12.1 数值范围

| Token | 允许范围/枚举 | 超界处置 | 安全回退 |
|---|---|---|---|
| 面板背景 opacity | `0.88–1.00` | 钳制并在预览提示 | A 对应外观背景 |
| 面板圆角 | `14–18 pt` | 钳制 | `16 pt` |
| 边框宽度 | `0–1.5 pt` | 钳制 | `1 pt` |
| 阴影 y | `4–10 pt` | 钳制 | `6 pt` |
| 阴影 blur | `12–28 pt` | 钳制 | `20 pt` |
| 阴影 opacity | `0.12–0.32` | 钳制 | 浅色 `0.18` / 深色 `0.28` |
| 金额字号 | 离散 `26, 28, 30, 32, 34 pt` | 使用适配算法 | A 字体与档位 |
| 金额字重 | Medium、Semibold、Bold | 未知值拒绝 | Medium |
| 按钮圆角 | `7–12 pt` | 钳制 | `8 pt` |
| 进度高度 | `3–6 pt` | 钳制 | `4 pt` |
| 进度预设 | `linear`、`segmented12`、`compactRing` | 未知值回退并提示 | `linear` |
| 数字动效 | `none`、`odometer`、`verticalRoll` | 未知值回退 | `odometer` |
| 数字时长 | `120–220 ms` | 钳制 | `160 ms` |
| 状态淡入 | `0–160 ms` | 钳制 | `100 ms` |
| 装饰 opacity | `0–0.90`；通过安全检查可到 `1.0` | 钳制/降至安全值 | `0` |
| 装饰插槽 | 应用固定 ID 与 Frame | 未知 ID 忽略；必需资源缺失则拒绝 | 空装饰 |

`compactRing` 只能在进度槽右端使用 `14 × 14 pt` 应用预设，百分比文字仍保留；不能改变其他组件位置。`segmented12` 使用相同轨道 Frame 和 12 个等宽片段。

### 12.2 对比度与安全回退

- 正常文字对背景对比度至少 `4.5:1`。
- `18 pt` 以上或 `14 pt Bold` 以上的大文字至少 `3:1`。
- 按钮边界、焦点环、进度和状态图形等非文字 UI 至少 `3:1`。
- primary action 文字至少 `4.5:1`；不满足时先在黑/白安全文字中选择对比更高者。
- `RECOVERY_REQUIRED` 的错误色、destructive 按钮与焦点环使用应用安全 Token，皮肤不能覆盖为低对比值。
- 对比不足时使用对应外观的 A 安全 Token 替换；替换后仍不满足、核心内容仍溢出或装饰仍遮挡时拒绝安装。
- Increased Contrast 开启时，背景 opacity 至少 `0.96`，边框至少 `1 pt`，次级文字使用 primary/secondary 中对比更高者，阴影不作为唯一边界。
- Reduce Transparency 开启时禁用系统半透明材质，使用本节对应的实色 `panel.background`。

### 12.3 字体与资源回退

- 字体只能从应用允许的系统/内置列表选择；缺失或不支持 tabular digits 时强制使用 A 金额字体。
- 背景或可选装饰缺失时使用对应外观安全背景与空装饰。
- 必需状态资源损坏时，用户导入皮肤拒绝安装；内置 B 构建时视为发布阻塞。
- 不允许资源改变点击区域、焦点顺序、VoiceOver 文本、状态文案或金额精度。

## 13. 浅色、深色与跟随系统

- 外观选择提供“跟随系统”“浅色”“深色”，默认“跟随系统”。
- 跟随系统时监听 macOS 外观变化，并在单个渲染 transaction 中切换完整 Token 组；不得混用两套主题的核心 Token。
- 外观切换使用 `120 ms` 无位移 crossfade；Reduce Motion 开启时即时切换，Reduce Transparency 开启时只在实色之间切换。
- 切换外观不重置 odometer、进度、焦点、面板位置或业务状态。
- 当前皮肤不支持目标外观时整体回退 A 默认皮肤对应外观，并在设置窗口显示非阻塞说明。

## 14. MenuBarExtra Contract

### 14.1 菜单结构

菜单使用 macOS 原生菜单宽度、字体、separator、toggle 和键盘焦点，不由皮肤重绘。顺序固定为：

1. 非交互状态摘要：状态文案；下一行显示当前金额和辅助摘要。
2. separator。
3. “显示收入面板”或“隐藏收入面板”，快捷键 `⌥⌘I`。
4. 动态业务操作：“打卡上班”“打卡下班”或旧工作日完成后的“开始今天…”；不可用时 disabled 并提供原因 tooltip/accessibility help。
5. “打开设置…”，快捷键 `⌘,`。
6. separator。
7. toggle“始终置顶”。
8. toggle“全屏应用时隐藏”。
9. toggle“登录时启动”。
10. separator。
11. “退出可视收入打卡机”，快捷键 `⌘Q`。

### 14.2 状态摘要

| 状态 | 第一行 | 第二行 |
|---|---|---|
| `UNCONFIGURED` | “待完成设置” | “请先设置工资与工作时间” |
| `READY` | “今日未打卡” | `今日已获得 ¥0.00` |
| `CLOCKED_IN_WAITING` | “已打卡 · 等待开工” | `今日已获得 ¥0.000 · 距离开始 HH:MM:SS` |
| `EARNING` | “计薪中” | `今日已获得 ¥123.456 · 距离下班 HH:MM:SS` |
| `AWAITING_CLOCK_OUT` | “计薪已停止” | `今日已获得 ¥123.46 · 请打卡下班` |
| `COMPLETED` | “今日已完成” | `最终收入 ¥123.46` |
| `RECOVERY_REQUIRED` | “记录需要恢复” | “无法安全显示今日收入” |

MenuBarExtra 不运行动画，不展示角色，不展示进度图，不增加皮肤专属菜单项。皮肤最多影响菜单栏状态小图标的允许色彩；状态文字始终存在。

旧日有效 Today 未完成时，摘要显示“上一个工作日未完成 · {date}”与“计薪已停止 · 请打卡下班”；完成后显示“上一工作日已结算 · {date}”与最终金额，并提供“开始今天…”。当前日期的打卡上班操作在旧日记录清理成功前不可用。

DST v1 日程时间错误期间，MenuBarExtra 的非交互摘要显示“今日工作时间无法确定”与“请在设置中调整上下班时间”，金额与快捷打卡操作隐藏或 disabled；“打开设置…”保持可用。该摘要不伪装成 `UNCONFIGURED` 或 `RECOVERY_REQUIRED`。

Settings 无法读取且没有可独立验证的有效 Today 时，MenuBarExtra 显示“设置数据无法读取”与“请打开设置重新填写”，隐藏金额和快捷打卡操作；“打开设置…”保持可用。该表面不伪装成 `UNCONFIGURED`。若有效 Today 可独立恢复，菜单继续显示该 Today 的业务摘要，并附非阻塞的“设置需要修复”。

Settings 与 Today 同时 damaged 时，MenuBarExtra 第一行显示 Today 主错误“今日记录需要恢复”，第二行显示“设置数据也无法读取”；金额与打卡操作隐藏，同时保留“打开设置…”和面板中的 Today 重置入口。两个文件的恢复结果必须分别反映，不得合并成普通未配置。

## 15. 设置窗口 Contract

### 15.1 窗口与导航

- 默认尺寸 `760 × 540 pt`，可调整；最小尺寸 `680 × 500 pt`。
- 左侧 sidebar 固定基础宽度 `176 pt`，可在 `168–196 pt` 内随本地化适配。
- 内容区域最小宽度 `484 pt`，外边距 `20 pt`，section 垂直间距 `24 pt`。
- sidebar 顺序：`通用`、`工作规则`、`面板与启动`、`外观与皮肤`、`数据与隐私`、`快捷键`、`关于`。
- 窗口关闭不影响面板、计薪、通知或导入前已提交的数据。

### 15.2 通用

- 下班通知开关；关闭不请求权限。
- 皮肤提示音开关，默认关闭。
- 应用外观 segmented control：跟随系统/浅色/深色。
- 每个异步开关只有写入或系统调用成功后更新最终状态；失败时恢复原值并显示 inline error。

### 15.3 工作规则

- 日工资输入，前缀 `¥`，最多两位小数。
- 固定上班时间与固定下班时间，24 小时制。
- 当日已打卡后，字段仍可编辑，但 section 顶部显示 info banner：“修改将于明日生效”。
- 字段错误紧邻字段下方显示；错误不清空输入。
- 用户点击保存时，UI 只发送一次保存命令；Application 为该命令只采样一次 `BusinessCommandContext.timestampMs` 和 `commandTimeZoneIdentifier`，并生成唯一 `commandDateKey`。UI 不得自行读取或重读 `Calendar.current`/`TimeZone.current`，也不得在 loading、错误映射或 success 后用新的日期/时区重新验证输入。
- 两个墙上时间必须使用该命令的 `commandDateKey`/`commandTimeZoneIdentifier` 严格验证；不存在或重复的字段显示 inline error：“当前时区下，此时间不存在或无法唯一确定，请选择其他时间”。proposed schedule 的 DST 结果、Settings/Today typed load 与 expected token、目标业务状态、完整目标 `BusinessViewState`、success event、提交意图、持久化、inline error 与 success announcement 必须属于同一 command context，不得自动替换输入。
- 保存期间 UI 保留命令前最后已验证的 Panel/MenuBar/Settings 状态作为可恢复底层内容，并显示“正在检查…”；只有 Application 已完整构造 `SaveSettingsPlan` 后才进入“正在保存…”。UI 不得在 Repository commit 后自行调用日期、日程、金额或状态推导来决定显示结果。
- preflight 或 target construction 失败时，UI 退出 loading、保留输入、旧 UI revision、旧业务状态和旧 `BusinessViewState`，显示该命令的 inline/banner error，不显示 success。Repository revision/damage-token conflict 或 I/O failure 使用相同保留语义，并明确“设置未保存，原设置未改变”；本命令不得推进 revision。
- commit 成功后，UI 必须从 committed result 一次发布 plan 中已构造的目标业务状态/`BusinessViewState`、committed revision 和单次 success toast/announcement；该发布为非抛出步骤。commit 后不得出现“保存失败”，也不得因展示层延迟或非关键 success 动画问题回滚 UI revision。若进程在 commit 后、success UI 前终止，重启后加载 committed revision/状态，不显示虚假失败或用旧 revision 自动重试。
- 用户重试时创建新的保存命令和新的 context；command ID/token 必须阻止旧命令的异步 validation、inline error、revision conflict、I/O failure、committed revision 或 success 覆盖重试结果。若旧命令已经 committed，其持久化事实必须通过最新 load/revision 合并，不能被描述成失败。
- 若启动/刷新因已保存设置触发日程时间错误，section 顶部显示 error banner：“今日工作时间无法确定，原有设置和记录未被修改。请调整上下班时间后重试。”并聚焦到第一个无效时间字段。
- 保存按钮右下对齐；无修改时 disabled，保存中显示“正在保存…”。
- Settings 文件损坏时，section 顶部显示 error banner：“设置数据无法读取，原文件未被改写。请重新填写并确认替换。”；不得把默认值显示成已恢复的原设置。用户使用明确的“确认替换设置”操作后必须进入与普通保存相同的“正在检查…”→完整 plan→“正在保存…”顺序；preflight/target/conflict/I/O failure 保留错误 banner、输入、旧 ViewState/UI revision且不显示 success，commit 成功后只发布预构造 target/committed revision/success，禁止 commit 后首次 resolver/parser/deriver/reconcile。
- 同一 banner 下提供独立 destructive“重置设置…”，并使用第 7.3 节二次确认。替换是写入新有效记录，重置是将 damaged 记录变为 missing；两者不得删除 Today，且成功后的 Panel/MenuBar 必须按 Product 0.8 第 7.2 节矩阵转移，不得无条件跳到 `READY`。

### 15.4 面板与启动

- toggle“始终置顶”。
- toggle“锁定面板位置”。
- toggle“全屏应用时隐藏”。
- toggle“登录时启动”。
- button“恢复默认面板位置”。
- 每项附一行不超过 44 个中文字符的说明；失败信息显示在对应控件下。

### 15.5 外观与皮肤：浏览

- 顶部显示标题“外观与皮肤”、当前外观模式和“导入皮肤…”按钮。
- 皮肤卡片使用三列自适应网格；标准卡片 `168 × 132 pt`，间距 `12 pt`。
- 卡片预览 Frame `152 × 90 pt`，按 `320:190` 等比缩放 standard panel；预览不运行动画、不接受内部点击。
- 卡片底部显示名称、来源标签（内置/已安装/禁用）和当前选中勾号。
- 单击卡片只选择预览；双击或明确“使用此皮肤”才切换，防止误切。
- 详情区显示名称、作者、版本、来源/版权、支持外观、兼容状态和“使用此皮肤”。用户皮肤另显示“删除”。
- A 显示“默认 · 内置 · 不可删除”；B 显示“内置验证皮肤”。

### 15.6 导入与拖放

- 导入区 Frame 最小 `544 × 96 pt`，虚线边框，文案“将 .incomeclocktheme 拖到此处，或选择文件”。
- 拖入合法扩展名时边框使用 accent；不支持文件使用 error 并显示“不支持此文件类型”。
- 验证期间显示文件名、系统进度指示和阶段文案：“正在检查 Manifest/资源/兼容性/预览”。取消仅在原子安装开始前可用。
- 验证不冻结悬浮面板或业务状态。

### 15.7 安装前预览

验证成功后显示 `680 × 500 pt` sheet：

- 标题、作者、版本、来源/版权和最低应用版本。
- 浅色、深色两个 `240 × 143 pt` standard panel 预览；可切换 `READY`、`EARNING`、`AWAITING_CLOCK_OUT`、`COMPLETED`、`RECOVERY_REQUIRED`。
- 显示 Token 自动钳制或安全替换列表；为空时显示“未发现需要修正的视觉参数”。
- 显示声明式权限说明：“此皮肤不能运行代码、访问网络或修改打卡记录”。
- secondary“取消”，primary“安装皮肤”。安装成功后提供“立即使用”和“稍后”。

### 15.8 验证失败

- sheet 标题“无法导入此皮肤”，不得显示预览为已安装。
- 错误按 Manifest、兼容性、路径、媒体、容量、无障碍或资源缺失分组。
- 每条包含资源/字段名、简短原因和可操作建议；技术路径只显示包内相对路径。
- 提供“关闭”和“复制诊断信息”；不提供“仍然安装”。
- 失败后当前皮肤、工资设置和今日记录保持不变，临时文件清理不以 UI 成功假设。

### 15.9 重复、升级与不兼容

- 同 ID 同版本：sheet 显示“此版本已安装”，操作为“取消”与“重新安装”。
- 更高版本：显示 `旧版本 → 新版本`、兼容变化和“更新皮肤”。
- 低版本或作者冲突：阻止覆盖，显示删除现有皮肤后重试的说明。
- `minimumAppVersion` 或 required capability 不满足：显示所需版本/能力与当前版本，不提供安装按钮。
- optional capability 被忽略且标准回退有效：预览明确标记“将使用标准外观降级”，用户确认后才安装。

### 15.10 切换、删除与恢复默认

- 切换成功后当前卡片勾号和所有可渲染载体同步更新；失败则恢复原选中状态并显示原因。
- 删除非当前用户皮肤：确认文案“删除后需要重新导入才能使用”；取消/删除。
- 删除当前用户皮肤：确认文案“将先切换为默认皮肤「暖屿」，再删除此皮肤”；只有默认选择持久化成功后才删除。
- 内置 A、B 不显示删除操作。
- “恢复默认皮肤”始终可见；当前已经是 A 时 disabled，并显示“正在使用默认皮肤”。
- 当前皮肤损坏或升级后失效时，顶部 non-blocking banner：“当前皮肤无法使用，已恢复为暖屿”，操作“查看原因”。

### 15.11 数据与隐私、快捷键、关于

- 数据与隐私：本地数据说明、存储位置说明、通知不保证必达、destructive“重置今日记录”。
- 快捷键：显示/隐藏面板默认为 `⌥⌘I`；冲突或录入失败时保留旧值并显示错误。
- 关于：应用名称、版本、最低系统版本、本地优先和皮肤安全说明。

## 16. 通用反馈状态

### 16.1 Loading

- 应用启动尚未完成本地恢复时，面板显示“正在恢复今日记录…”，隐藏金额，使用系统小型 ProgressView，业务操作 disabled。
- 正常本地读取不人为增加 loading 时长。
- 今日记录解析失败进入 `RECOVERY_REQUIRED`；其他不可恢复读取失败显示明确错误，不使用 `¥0.00` 冒充已恢复。
- 当前工作日的本地日程时间不存在或无法唯一解析时必须结束 loading，显示第 5 节定义的日程时间错误；普通恢复的新业务 ViewState/金额保持未发布，“开始今天” preflight 则必须保留旧工作日已验证结算。
- Settings 无法读取且没有有效 Today 时必须结束 loading，并以独立错误表面替换业务主体：隐藏金额、进度、倒计时、角色和打卡操作，显示标题“设置数据无法读取”、说明“原设置文件未被改写，请在设置中重新填写并确认替换”及“打开设置”。不得进入普通 `UNCONFIGURED` 或显示 `¥0.00`。
- Settings 无法读取但有效 Today 可独立验证时，继续显示该 Today 的权威业务状态，并显示非阻塞“设置需要修复”；该错误不得改写 Today 或停止其已冻结的结算流程。
- Settings 与 Today 同时无法读取时，必须结束 loading 并显示第 7.3 节的确定双错误优先级；重置任一 record 后立即映射另一 record 的真实剩余状态，不得回到 loading、`READY` 或伪 `UNCONFIGURED`。

### 16.2 Disabled

- disabled 控件 opacity 不低于 `0.45`，文字仍满足 `3:1`，移除 hover/pressed，保留 tooltip 和 VoiceOver 原因。
- 禁用不能只通过降低透明度表达；光标、状态说明或帮助文本同时给出原因。

### 16.3 Error

- 字段错误就地显示；跨页面错误使用顶部 inline banner；不会阻塞主要内容的非关键错误使用 non-blocking banner。
- 错误文案说明发生了什么、哪些内容未改变、用户下一步可以做什么。
- 不使用只含“失败”“未知错误”的不可操作文案。
- DST v1 日程时间错误必须区分“时间不存在”和“时间重复、无法唯一确定”的诊断类别；用户文案可以统一，但不得声称已自动调整。错误表面必须提供“打开设置”或等效恢复入口。

### 16.4 Success

- 设置保存、主题安装或切换成功使用 `1.5–2.5 s` 非阻塞 toast，并提供单次 VoiceOver announcement。Settings success 只消费 Repository committed result，并与同一 `SaveSettingsPlan` 的目标 ViewState/revision 一起发布；不得在 commit 后重新推导成功条件。
- Settings 的 DST 严格解析失败时不结束为 success、不显示 toast、不发 success announcement，且持久化前后值保持不变。
- Settings preflight/target failure、revision conflict 与 I/O failure 均不显示 success，保留旧 ViewState/revision。Repository 已 committed 的结果不得再显示“保存失败”；进程内 committed target 发布必须非抛出，崩溃恢复则以 committed bytes/revision 为准。
- 打卡成功以状态转换为主，不叠加遮挡金额的 toast。

### 16.5 Empty

- 没有用户导入皮肤时仍显示 A、B 内置皮肤；“已导入”分组显示空态：“还没有导入皮肤”，并提供“导入皮肤…”。
- 搜索/筛选无结果时显示“没有符合条件的皮肤”和“清除筛选”。首版不提供在线商店推荐。

### 16.6 Recovery

- 业务记录恢复使用第 7 节，Theme 失效使用第 15.10 节 non-blocking banner；两者不得混用。
- Theme 恢复不得遮挡或替换业务 `RECOVERY_REQUIRED`。

## 17. 无障碍 Contract

### 17.1 键盘与焦点

- 面板默认不抢焦点；用户通过快捷键明确聚焦或点击面板后才进入键盘导航。
- 标准焦点顺序：设置 → 隐藏 → 主要操作；确认页为取消 → 确认；恢复确认同序。
- `Tab`/`Shift-Tab` 遍历，`Space`/`Return` 激活；`Escape` 取消确认、关闭 sheet 或退出临时预览，不退出应用。
- 焦点环为 `2 pt` 外描边，距控件 `2 pt`，对相邻背景至少 `3:1`；皮肤不能隐藏。

### 17.2 VoiceOver

- 金额可访问名称：“今日已获得”；EARNING value 示例：“123 元 4 角 5 分 6 厘，实时收入估算”；停止/完成 value 只读到分并说明“已结算”。
- 第三位只作实时估算语义，不以正式人民币结算单位误导用户。
- 动画帧和千分之一元变化不发送 announcement。
- announcement 只用于：上班打卡成功、自动停止、下班打卡成功、结算完成、写入失败、进入恢复状态、主题回退。
- 装饰、背景纹理和角色均 accessibilityHidden。

### 17.3 字体放大与系统辅助设置

- 使用系统语义字体并支持最高 `120%` 的应用文字比例；金额按第 8.2 节重新选择离散字号，按钮文字不得裁切。
- 辅助字段在 120% 下可从左右并列变为上下两行，但必须保持在 `(12, 100, 228, 42)` 内并保留完整计时值。
- 结算祝福最多两行；超过可用宽度时缩短为语义等价的应用内置可访问文案，不允许皮肤改写。
- 支持 Increase Contrast、Reduce Transparency 和 Reduce Motion，优先级高于皮肤。

## 18. 可观察 UI 验收标准

以下均为待实现、待验证标准，不表示已经通过。

### A. Profile 与布局

- [ ] standard panel 在 1x/2x 显示比例下内容尺寸均为 `320 × 190 pt`，安全区和所有固定 Frame 符合第 3 节。
- [ ] A、B 的状态、金额、进度、辅助信息、按钮和点击区域逐项重合。
- [ ] A、B 切换不改变焦点顺序、窗口位置、面板尺寸或任何业务 View State。
- [ ] `320 × 190` 和布局常量只来自展示层 Profile，不被业务 Store 读取。
- [ ] 未来 Profile 接口不导致首版出现异形、竖向、胶囊或 HUD 验收项。

### B. 七状态与流程

- [ ] 七个状态的图标、文案、金额精度、辅助信息和操作与第 5 节完全一致。
- [ ] `CLOCKED_IN_WAITING` 显示 `¥0.000` 且无数字滚动。
- [ ] `EARNING` 显示三位金额和“实时收入估算”，不显示收入速度。
- [ ] `AWAITING_CLOCK_OUT` 显示两位金额、100% 和“请打卡下班”，无滚轮。
- [ ] 主动下班确认的预计金额持续从权威值刷新，取消不改变状态。
- [ ] 确认下班写入失败不进入完成页；成功后显示完整结算信息与两位祝福金额。
- [ ] `RECOVERY_REQUIRED` 不显示金额、角色或未经验证数据，并能完成二次确认重置。
- [ ] 有效未完成 Today 跨日后显示旧工作日日期并保持 `AWAITING_CLOCK_OUT`；新日打卡不可用，成功下班后显示旧日完整结算。
- [ ] 旧日 `COMPLETED` 的“开始今天”取消、删除成功和删除失败分别保持旧结算、进入当前日期、保持旧记录及错误。
- [ ] “开始今天”确认后先显示检查态，任一 Settings/日期/时区/DST/目标构造错误都退回可恢复的旧结算；只有 preflight 成功后才显示原子提交 loading。
- [ ] Settings damaged 时旧日结算保留，“开始今天”不可用；Settings missing 成功清理后只进入 `UNCONFIGURED`，valid 且日程唯一时才进入 `READY`。
- [ ] 次日和多日后下班展示旧工作日日期与真实下班日期/时间，不进入 Recovery；东/西时区切换不重新解释旧 Today。
- [ ] DST gap/fold 日程时间错误不映射成七状态中的任一状态，不显示金额、角色、进度、倒计时或快捷打卡，并能打开设置恢复。
- [ ] Settings 读取错误不映射成 `UNCONFIGURED`；无有效 Today 时不显示 `¥0.00`，有效 Today 时继续其冻结业务状态并提示修复。
- [ ] Settings missing/damaged 与 Today missing/valid/damaged 全组合按 Product 0.8 第 7.2 节显示；双损坏使用 Today 主错误 + Settings 次错误，两种重置顺序后状态确定。
- [ ] 重置 Settings 不删除 Today；有效 Today 存在时继续显示 snapshot 状态，无 Today 才显示 `UNCONFIGURED`，不得无条件进入 `READY`。
- [ ] Settings 保存的校验、loading、错误、retry、revision 和 success 可证明绑定同一次 `BusinessCommandContext`；UI 不读取 `Calendar.current` 或 `TimeZone.current`。

### C. 金额与动效

- [ ] `¥999.999 → ¥1,000.000` 时小数点锚位、金额容器和其他组件不移动。
- [ ] 最大工资范围内金额不裁切、不省略、不小于 `26 pt`。
- [ ] `12.009→12.010`、`12.099→12.100`、`99.999→100.000` 原子正确进位。
- [ ] 动画只在真实 `¥0.001` 边界变化，不使用循环尾数或伪造数字。
- [ ] 30/60 FPS 和跳帧下，相同目标值的文字完全一致。
- [ ] 后台恢复直接校准，不补播；自动停止和主动完成直接重算两位金额。
- [ ] Reduce Motion 下数值正确更新且无 transform/角色位移动画。

### D. A 与 B 视觉

- [ ] A 浅色、深色和跟随系统使用第 10 节确定 Token，核心对比度达标。
- [ ] B 只改变第 11 节允许的 Token/资源，角色严格裁切在安全装饰插槽并不命中鼠标。
- [ ] B 每个必需状态均有浅/深资源；恢复、确认和 loading 状态不显示角色。
- [ ] B 的 `companionFocus` 不与金额速度绑定，Reduce Motion 下完全静止。
- [ ] 角色、纹理或背景不遮挡金额、进度、状态、按钮、错误和焦点环。

### E. MenuBarExtra 与设置

- [ ] MenuBarExtra 的顺序、文案、快捷键、toggle 和状态摘要符合第 14 节，且不运行动画或角色。
- [ ] 设置窗口七个页面在最小尺寸下无核心内容裁切，键盘可完整操作。
- [ ] 不存在/重复的本地时间在对应字段显示 inline error，保留输入；失败时无 success toast/announcement，原持久化值与 revision 不变。
- [ ] 普通 Settings 保存与 damaged Settings “确认替换设置”只有在同一个 `SaveSettingsPlan` 已构造目标业务状态、完整目标 ViewState、success event 与提交意图后才从“正在检查…”进入“正在保存…”；每个 preflight/target failure 都保留旧 Panel/MenuBar/ViewState、输入、damaged banner 和 UI revision。
- [ ] 两种 Settings 保存入口的 revision/damage-token conflict 与 I/O failure 均显示“未保存/原设置未改变”，无 success；commit 成功则原子显示 plan target/committed revision/success，之后没有 resolver/parser/deriver/reconcile 首次失败或“已写入但 UI 报失败”。
- [ ] Settings 保存重试使用新 command ID/context；陈旧 validation/error/conflict/failure/committed result/success 不能覆盖新命令。commit 后进程中断的恢复读取 committed revision，不以旧 revision 重试。
- [ ] 从启动日程时间错误打开设置、修改为可唯一解析的时间并重试后，错误可解除；失败重试不发布业务 ViewState。
- [ ] 皮肤浏览、选择、安装前预览、验证成功、验证失败、重复安装、升级、不兼容、切换、删除和恢复默认均有可观察 UI。
- [ ] 验证失败没有“仍然安装”，不显示虚假成功，也不改变当前皮肤。
- [ ] 删除当前皮肤先成功切换 A；任何失败均保持一个有效当前皮肤。
- [ ] 计薪中切换 A/B 时，屏幕金额立刻与同一业务值一致且持续增长。

### F. 反馈与无障碍

- [ ] loading、disabled、error、success、empty、业务 recovery 和 Theme fallback 均按第 16 节显示且语义不混淆。
- [ ] 正常文字、主要按钮、焦点环和非文字控件达到第 12.2 节对比度底线。
- [ ] Increase Contrast、Reduce Transparency、Reduce Motion 均覆盖皮肤设置。
- [ ] VoiceOver 不高频播报金额，装饰不出现在可访问树中，状态事件只播报一次。
- [ ] Tab 顺序、Escape 行为、焦点可见性和 disabled 原因可验证。
- [ ] 120% 文字比例下金额、主要按钮、错误标题和结算信息不被裁切。

### G. S4R-003 真实系统 UI 验收延期

- S4R-003 当前 finding 状态为 `deferred`，原因是当前缺少物理外接显示器，无法取得真实系统证据；这不等于 closed、passed、verified 或 UI 验收完成。
- 延期期间，本节不勾选任何通过项，不以 fake screen、合成 notification、截图几何、属性断言或单显示器观察替代真实窗口服务器行为。
- 发布候选版/正式发布前必须在真实外接显示器上验证：扩展显示模式、主副屏切换、外接屏断开与重新连接、Dock 位置变化、分辨率和缩放变化、Space 与全屏切换、睡眠及唤醒恢复，以及面板始终约束在当前 `visibleFrame` 内。
- 上述任一场景失败或没有可审计证据时，S4R-003 必须保持 `deferred` 或恢复为 `open`；禁止宣称 UI 验收通过、生成 Release Candidate 或正式发布。
- 该延期只改变门槛归属，不授权 Stage 5；Stage 5 仍须用户单独授权，UI Spec 0.5 也须先完成独立 Contract Review。
- 若 Product 0.8/UI 0.5/Technical 0.4 candidate 获批，Technical 18.1 的 `Stage 4D — Contract Delta Implementation & Re-verification` 必须先另行授权并达到 `verified`；只有之后才允许另行申请 Stage 5 A UI。本 UI Contract 不把 Stage 1～3 的历史 verified 当作 current candidate 已实现，也不授权 Stage 4D。

## 19. UI Review Checklist

审查日期：2026-08-16。审查对象：UI Spec 0.5 完整候选文档及其与 Product Spec 0.8 的一致性。PD-001 只证明 UI 0.4 的历史批准事件；旧版内容缺失使增量复核不可行，下一轮必须基于 candidate 快照执行 full-document re-review。此处仅为修复后自查，不代表独立 Review、批准、代码或真实渲染验证。

- [x] `source_spec_version` 已更新为 `0.8`；A、B、C 的角色与首版范围一致。
- [x] A、B 原始概念板已保存并使用相对路径引用，且明确不是逐像素实现稿。
- [x] 面板尺寸、安全区、拖动区域、点击区域、区块 Frame 和间距均已确定。
- [x] 七个状态、主动下班确认、写入失败、自动停止、结算祝福和业务恢复与 `SPEC.md` 一致。
- [x] 实时三位、停止/结算两位、小数点锚位、最大金额适配和进位边界明确。
- [x] odometer 时长、缓动、方向、错峰、跳帧、后台恢复、停止和 Reduce Motion 参数均可观察。
- [x] A 的浅/深颜色、字体、形状、边框、阴影、进度和按钮 Token 已确定。
- [x] B 的差异 Token、角色安全区、动画和可选声音要求已确定；10 个必需 `@2x` 与 10 个 `@3x` 状态资源已保存并通过第 11.5 节静态检查。
- [x] Theme Token 允许范围、钳制、对比度替换、字体/资源回退和拒绝边界明确。
- [x] MenuBarExtra 结构、状态摘要和原生限制明确。
- [x] 设置窗口尺寸、导航，以及皮肤浏览、预览、导入、验证、安装、升级、切换、删除和恢复流程完整。
- [x] loading、disabled、error、success、empty、recovery 和 Theme fallback 有独立语义。
- [x] DST v1 日程时间错误与 loading、`UNCONFIGURED`、`RECOVERY_REQUIRED` 和 success 区分明确，并提供可操作恢复入口。
- [x] 旧日未完成 Today、旧日结算和“开始今天”的保留、确认、删除失败与当前日期阻断行为明确。
- [x] “开始今天”的无写入 preflight、typed failure 保留旧结算、单一原子提交和 valid/missing 目标映射可观察。
- [x] Settings missing/damaged 在 Panel、MenuBarExtra 和 Settings 中具有独立表面，不使用普通 `UNCONFIGURED` 或 `¥0.00` 冒充恢复；有效 Today 和双损坏矩阵及重置顺序已对齐。
- [x] 普通 Settings 保存与 damaged Settings 明确替换 UI 均只发送一次命令并共用同一 plan/commit 协议；DST/typed load/目标 ViewState/success/提交意图在 commit 前形成完整 plan，“正在检查/正在保存”、revision、错误、重试与陈旧结果抑制已固定。
- [x] Panel、MenuBarExtra、Settings inline error 与 VoiceOver/success 抑制的可观察行为一致。
- [x] 键盘、VoiceOver、焦点、对比度、字体放大、Increase Contrast、Reduce Transparency 和 Reduce Motion 明确。
- [x] A、B 使用完全相同的业务语义、标准 Profile、组件 Frame、点击区域与焦点顺序。
- [x] standard profile 数值未被写成未来所有皮肤的全局限制，未来能力未进入首版 UI 验收。
- [x] 文档中没有未决定的首版颜色、尺寸、间距、动效参数或不可观察的成功标准。
- [x] 未声称 SwiftUI、业务代码、测试或真实 UI 已实现、运行或通过。
- [x] S4R-003 明确为 finding 级 `deferred`，延期原因、真实补验清单、Release Candidate/正式发布禁令完整，且未声称通过。
- [x] Stage 5 A UI 之前新增的 Stage 4D Contract Delta 门禁只定义未实施；Stage 1～3 历史 verified 不冒充 candidate 实现证据。
- [x] Frontmatter 为 0.5、`status: review`、`approved_on: null`、`last_verified: null`，并如实记录 PD-001 历史批准事件、旧版内容证据缺口和 full-document re-review 方法。

## 20. Readiness 与未完成内容

**PD2RR-007 Contract Repair 自查：Complete；Full-document independent re-review：Pending；Approval：Not granted。**

UI Spec 0.5 PD2RR-007 recovery transaction repaired candidate 包含 S4R-003 发布硬门槛、Settings 单 command context、普通保存与 damaged replacement 共用的 commit 前完整 `SaveSettingsPlan`、“正在检查/正在保存”边界、失败零提交/旧 ViewState 保留和 commit 后非抛出目标发布 UI 规则，并保持 Product 0.8 为唯一产品来源与 Stage 4D 前置门禁。PD2RR-007 为 `ADDRESSED / AWAITING INDEPENDENT RE-REVIEW`；PD2RR-001/002/003/004/005/006 的既有独立关闭结论不变。0.5 尚未通过新 candidate 的独立 full-document re-review 或批准。

UI Spec 0.5 状态为 `review`，`last_verified` 保持 `null`。S4R-003 不再是 Stage 5 开发前门槛，但仍是 Release Candidate/正式发布前不可豁免的真实系统 UI 门槛；Stage 4D 与 Stage 5 本轮均未授权。
