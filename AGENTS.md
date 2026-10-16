# 可视收入打卡机 — 项目开发入口

本文件适用于本项目全部目录。用户当前任务中的明确要求优先。

本项目当前处于工作区 `开发范式.md` 的 Strict 路径：已批准的 Product/UI/Technical Contract、活动授权、证据和发布门禁决定具体工作范围。下文的 Spec 治理是本项目的高风险特例，不是整个工作区恢复“所有任务先写 Spec”的旧默认；不得据此放松本项目任何现有门禁。

## 治理来源与项目事实

- 本项目完整采用总 `spec-development` 规则。通用规则来源为 `../skills/spec-development/SKILL.md` 及其任务相关 references；涉及构建、测试、证据或恢复时必须读取 `artifact-lifecycle.md`、`xcode-macos-artifact-lifecycle.md` 与 `artifact-lifecycle-bad-cases.md`。
- `SPEC_GOVERNANCE.md` 只记录本项目对通用规则的持久落地方式、历史字段映射和固定 gate；不得复制通用规则全文，也不得保存会随每次复审改变的当前 candidate、Review、Finding 或授权值。
- `DEVELOPMENT_STATE.md` 是当前活动状态的唯一权威来源，回答当前可执行什么、是否有授权、应在哪个 gate 停止。
- `SPEC_INDEX.md` 定位活动 Contract、历史批准基线、固定 candidate、Review 与证据；它不只索引已批准 Spec。索引中的活动 Contract/Delivery 列是便于定位的投影，Review/Finding/授权当前值必须指向 `DEVELOPMENT_STATE.md`，不得成为第二份活动状态源。
- 已批准 Product → UI → Technical Contract 回答系统应该做什么；下游只能在上游边界内细化，不得反向改变上游语义。
- `review` candidate 只是固定复审输入，不能冒充已批准 Contract，也不能因 frontmatter、文件名或 `next_action` 获得实施授权。
- 代码、测试、schema、工程配置和实际运行证据回答系统实际上做了什么；绿色测试不能替代 Contract 审查。
- `DECISIONS.md` 记录理由与历史决策，不替代活动 Contract、当前授权或实际实现证据。

## Cold-start 顺序

新任务至少依次读取：

1. 适用的 `AGENTS.md`；
2. `SPEC_GOVERNANCE.md`；
3. `DEVELOPMENT_STATE.md`；
4. `SPEC_INDEX.md`；
5. 当前状态指向的固定 candidate manifest、目标 Contract、Review/Repair 或授权记录；
6. 仅与当前工作包和证据声明直接相关的代码、测试、schema、配置与验证结果。

只有在活动来源冲突、缺少 provenance 或需要解释历史状态时，才读取 `DECISIONS.md` 和历史报告。不得使用历史聊天重建项目事实。

Cold-start 必须能从活动文件回答：rigor、current phase、独立状态字段、active candidate、授权工作包、execution mode、human gates、暂停条件、重试停止条件、required validation、证据适用范围、下一项安全动作、final acceptance 和 deployment authorization。不能回答时先修复治理 drift，不得扩大实施。

## 产物生命周期硬门禁

- 本项目已记录 `BC-ART-001` 与 `BC-ART-002`：约 11 MiB 的恢复后源码工作树曾伴随约 17 GiB 的历史生成物目录。该事实用于防复发，不授权处置历史目录。
- 每个 Stage/工作包默认只允许一个已声明的 DerivedData 根；默认使用 `/private/tmp/visual-income-check-in/<stage>/<run-id>/DerivedData`，不得放入 iCloud 工作区、项目源码、fixed input 或 sealed evidence 根。
- `.xcresult` 必须使用显式 `-resultBundlePath` 输出到与 DerivedData 分离的命名运行目录；只有映射到 acceptance ID、记录 producer、环境、结果、限制和 SHA-256 的最小材料才能成为 evidence candidate。
- 默认预警阈值：单 Stage DerivedData `>2 GiB`、项目内构建缓存合计 `>5 GiB`、单产物树 `>50,000` 文件、计划整树备份 `>1 GiB`、fixed input dataless 文件 `>0`。当源码基线 `<100 MiB` 时，生成物同时 `>1 GiB` 且 `>50x` 源码也触发预警。
- 任一阈值触发后立即停止扩张，只做精确路径的只读盘点；不得通过再复制一份完整目录来“恢复”或“保全”。阈值触发不产生删除、移动、压缩或迁移授权。
- 每个物质工作包开始前在活动状态或工作包记录 Artifact Plan；结束或交接前记录 Artifact Disposition。未获清理授权时只能写 `cleanup-pending-authorization`。
- 当前活动文件不得指向不存在的 fixed input 或 evidence 根。恢复后路径失效时，先标记不可用与归档来源，再设计最小可验证恢复包；不得为维持旧路径表象而重建整个历史生成树。

## 七个独立状态字段

活动记录不得使用一个混合 `status` 同时表达多种事实，必须分别记录：

1. Contract status：`draft | review | approved | superseded`；
2. Delivery state：`not_authorized | authorized | implementing | implemented | verified | blocked`；
3. Review status：`awaiting_independent_review | in_review | completed | blocked`，记录固定 candidate 的复审流程状态；
4. Review conclusion：只允许 `READY | CONDITIONALLY_READY | NOT_READY`；复审尚未完成时必须为 `null`，不得用等待态占位；
5. Finding state：`OPEN | ADDRESSED | CLOSED | DEFERRED | ACCEPTED_RISK`；
6. Final human acceptance：`PENDING | ACCEPTED | REJECTED | ACCEPTED_WITH_RISK`；
7. Deployment authorization：`NOT_AUTHORIZED | AUTHORIZED`，并记录明确范围。

历史文件保留其原字段和原结论；迁移说明见 `SPEC_GOVERNANCE.md`。从活动 `DEVELOPMENT_STATE.md` 与 `SPEC_INDEX.md` 开始不得新增混合状态。

## 授权与 continuous 执行

- Contract approval 与 implementation authorization 是两个独立人类决定；用户可在一条明确指令中同时给出，但活动记录必须分别落盘。
- `next_action`、recommended step、roadmap、依赖 ready 或上一阶段完成都不是授权。
- 未记录为当前 active authorization 的工作包不得实施；阶段完成不得自动进入下一阶段。
- 获得明确、范围受限的实施授权后，默认 `execution_mode: continuous`：在允许范围内连续完成任务排序、实现、诊断、实质不同的修复、验证和状态同步，不为日常步骤反复询问“是否继续”。
- 人类保留产品语义、范围/非目标、验收含义、重大架构/数据/安全/隐私/财务/合规取舍、残余风险、破坏性/生产/外部操作、final acceptance 与 deployment authorization。

## 立即暂停与三次停止规则

出现 Contract 歧义或语义改变、授权不足、越过保护范围、破坏性/生产/外部写入/不可逆操作、重大安全隐私财务合规选择、需要用户在多个产品结果间决策、必要证据无法取得或无法安全回滚时，立即暂停受影响范围；这些情况不消耗三次技术修复循环。

对已授权范围内的普通技术 blocker，最多允许三个完整、证据驱动且实质不同的修复循环。每轮必须包含失败证据、因果假设、范围受限修补、最小验证和实际结果。连续三轮无实质进展后停止修改，保留安全状态，报告共同原因、三轮证据、保留/回退建议及恢复所需的最小人类决定。重复命令、等价改写、注释或格式变化不计有效循环。

## 更新与验证边界

- 修改已批准语义前必须有可重建基线；语义变化生成新的固定 review candidate，不继承批准或验证。
- Strict candidate 使用唯一不可变目录和 SHA-256 manifest；开始与结束时校验 manifest，并以 `cmp` 或等价方式确认活动文件身份。
- 验证证据必须绑定 requirement/acceptance、Contract 版本、源码 revision 或内容指纹、环境与关键配置、命令/方法、日期、实际结果、限制和未测范围。
- `verified` 只表示绑定的技术证据成立，不等于 final human acceptance、accepted risk 或 deployment authorization。
- 重大迁移必须在同一工作包原子同步活动 Contract metadata（若允许）、Review/finding、`SPEC_INDEX.md`、`DEVELOPMENT_STATE.md` 与证据引用；无法一致同步时报告 document drift，不得宣称完成。

## 项目保护边界

- 未经当前明确授权，不修改 Product/UI/Technical Contract、不可变 snapshot、历史 Review/Repair 结论、生产代码、测试、工程配置或真实 Application Support 数据。
- 不为通过测试而放宽金额、时间、Theme ID、持久化、安全或恢复约束。
- 测试持久化只能使用独立临时目录。
- 不安装依赖、不初始化或发布 Git 仓库、不执行签名、公证、部署、外部分发、外部写入或付费操作，除非明确授权。
- UI 阶段才加载相应 UI skill；纯治理、Contract、Domain、Persistence、状态和 Markdown Review 不加载 UI skill。

## 冷启动最小指令

> 请执行本项目的 spec-development cold-start check，并仅处理 DEVELOPMENT_STATE.md 明确记录的当前已授权工作包。

如果 `active_authorization: none`，只能报告状态与推荐动作；不得把推荐动作当作授权。


## Stage 9 批量收尾执行规则

来源：2026-09-07 用户明确流程调整授权。剩余软件工作按共享代码、测试环境与依赖批量实施、集中验证、批量独立复审；取消逐 coverage row 授权/构建/复审/返回管理对话要求。开发与 reviewer 角色分离，reviewer 不修改代码，实施者不裁决自身改动。当前授权与状态只读取 DEVELOPMENT_STATE.md；不改变 Approved Contract 语义、验收含义、真实硬件/系统 gate、最终人类接受或发布硬门禁。历史 ledger/reviews/seals 不覆盖。
