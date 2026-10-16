---
title: 可视收入打卡机 Spec 治理规则
document_type: spec_governance
governance_state: active
rigor: strict
last_updated: 2026-08-21
governance_source: "../skills/spec-development/SKILL.md and required references, read 2026-08-17"
---

# 可视收入打卡机 — Spec 治理规则

本文件把总 `spec-development` 规则落实到本项目。通用定义仍以总规则为准；本文件只记录项目权威方向、历史迁移映射、固定 candidate 规则、持久 gate 和原子同步要求。它不保存会随每次复审或授权改变的活动值，也不修改任何 Product/UI/Technical 语义、历史 Review/Repair 结论或产品决策。

`DEVELOPMENT_STATE.md` 是本项目当前 phase、candidate、七个独立状态字段、授权、human gate 和下一动作的唯一权威来源。`SPEC_INDEX.md` 只负责定位 Contract、固定 candidate、Review/Finding 证据和历史 provenance；本文件与索引都不得用重复的可变值覆盖 `DEVELOPMENT_STATE.md`。

本次迁移于 2026-08-17 读取的总规则来源指纹：`SKILL.md` `60c0137a02fdfa1b14820ca277be95e4ea3f9ebf9ed28e92544eeb4a38fd5794`；`spec-governance.md` `cb9643cd1f50516b36ae13f0a3029059773dea89264330fa8f74fa60e274fa1f`；`spec-status-rules.md` `fcaa8e45a38b4ee501e1453739f98a937d5db4dd6e6311661f8a3600fe8f9863`；`execution-boundaries.md` `556bf726b9c6afc961f541c29598570e91e8a9ea205f3ca9653e03bee34efa86`；`cold-start-checklist.md` `666009c06651f43c4653f06c2b499ec0103505647a1239156bf24e7d79817412`。这些指纹只重建本次迁移所用规则版本；后续任务仍须读取当时最新版。

## 1. Rigor 与权威方向

- 项目治理等级固定为 **Strict**：本项目涉及金额、持久化、DST/时区、恢复、不可变 candidate、多个审批 gate 和发布硬门槛。
- 规范权威方向是 **Product → UI → Technical**。
  - Product 拥有产品结果、业务规则、范围、默认值、失败与验收含义。
  - UI 只能在 Product 允许范围内细化可观察界面、交互、无障碍和展示验收。
  - Technical 只能在 Product 与 UI 边界内细化架构、接口、数据、并发、持久化、错误和验证方式。
- 下游不得反向改变上游；冲突必须先回到拥有该语义的上游 Contract，再固定新 candidate 并复审所有受影响依赖。
- 当前用户明确决定拥有新意图与当前授权；已批准 Contract 拥有“系统应该做什么”；活动状态拥有“现在可执行什么”；代码/测试/schema/配置/运行证据拥有“实际做了什么”；`DECISIONS.md` 只拥有理由和 provenance。

## 2. 历史批准基线与 review candidate 的区别

| 集合 | 身份 | 可证明内容 | 不可推断内容 |
|---|---|---|---|
| Product 0.7 / UI 0.4 / Technical 0.3 | `PD-001` 记录的历史 approved 基线 | 2026-08-15 曾被批准；Stage 1～3 的历史实现/验证针对当时 Contract | 由于不可变内容快照缺失，不能重建精确内容、伪造旧 fingerprint，不能把批准或证据继承给后继版本 |
| 后继 Product/UI/Technical review candidate | `DEVELOPMENT_STATE.md` 指向的命名 fixed candidate | 对应不可变快照、manifest、SHA-256、独立 Review 和 Finding 证据能够证明的精确内容 | 不自动继承历史 approval 或 implementation evidence；Review conclusion 也不等于 approved、implemented 或 verified |

活动 candidate 的准确版本、manifest 和 fingerprint 只在 `DEVELOPMENT_STATE.md` 记录；`SPEC_INDEX.md` 提供相应文件与证据入口。本治理文件不复制这些可变身份。

## 3. 固定 candidate、快照与 SHA-256

1. Strict Review、批准或验证只能针对一个命名且固定的 candidate，不得复审移动中的活动文件。
2. 每个 candidate 使用新的唯一目录；不得覆盖、重命名或重写任何旧 snapshot 或 `SHA256SUMS`。
3. Candidate 至少包含完整 Product、UI、Technical Contract 和 manifest；manifest 记录完整 SHA-256。
4. 开始和结束 Review/治理完整性检查时运行 `shasum -a 256 -c`；活动 Contract 必须以 `cmp -s` 与快照逐字节一致。
5. SHA 不符、活动文件不符、manifest 被覆盖或复审期间变化时，固定输入失效，立即停止语义复审或批准；下一动作只能是重新固定 candidate。
6. Approval 只适用于被审查的精确内容。Contract frontmatter、文件名、repair 自查或 candidate 路径本身都不产生批准。
7. 不可变 candidate 内关于“等待复审”等流程文字只描述其固定时的 authoring context；复审完成后不得回写快照，也不得把该文字当作当前 Review 状态。当前流程值仍只读取 `DEVELOPMENT_STATE.md`。

## 4. 七个独立状态字段

| 状态字段 | 允许值/记录方式 |
|---|---|
| Contract status | `draft → review → approved → superseded` |
| Delivery state | `not_authorized → authorized → implementing → implemented → verified`；外部 blocker 才用 `blocked` |
| Review status | `awaiting_independent_review / in_review / completed / blocked` |
| Review conclusion | 只允许 `READY / CONDITIONALLY_READY / NOT_READY`；Review 未完成时记录 `null` |
| Finding state | `OPEN / ADDRESSED / CLOSED / DEFERRED / ACCEPTED_RISK` |
| Final human acceptance | `PENDING / ACCEPTED / REJECTED / ACCEPTED_WITH_RISK` |
| Deployment authorization | `NOT_AUTHORIZED / AUTHORIZED`，并绑定范围 |

七个字段的当前值只读取 `DEVELOPMENT_STATE.md`。`workflow_status` 仅可作为活动记录的路由提示，不能代替七个字段中的任何一条；`last_verified` 只表示绑定证据 coverage，不表示批准、final acceptance 或部署授权。

## 5. 历史字段迁移映射

历史文档不得机械重写；其术语按产生时语境解释：

| 旧字段/写法 | 新轴解释 | 迁移规则 |
|---|---|---|
| Contract frontmatter `status: review/approved` | Contract status | 历史原文保留；活动 Contract 继续使用该轴 |
| Review `readiness: NOT READY/READY` 或正文 Readiness | Review conclusion | 只绑定该报告固定的 candidate；不得转抄为其他 candidate 的结论；未复审 candidate 的 conclusion 为 `null` |
| `repair_status`、`OPEN/ADDRESSED/CLOSED` | Finding workflow/state | Repair 可提出 `addressed`；只有与修补分离的 recheck 可 `closed` |
| Stage/Report `status: review/verified`、`NOT VERIFIED` | 历史 Delivery/technical verification 混合记录 | 历史原文不改；活动状态从现在起分别记录 Delivery state 与证据 coverage |
| `workflow_status`、`current_phase` | 路由/当前上下文 | 不等于 Contract、Delivery、Review 或授权 |
| `next_action`、下一步 | 推荐动作 | 永远不是 active authorization |
| `approved_on` | Contract approval 事件 | 不授权实现、部署或外部写入 |
| `last_verified` | 证据 coverage | 必须绑定版本、指纹、环境、命令和结果；不可自动继承 |

旧 candidate 的 `NOT READY`、旧 Finding 的 `OPEN` 和旧 Stage 的 `review` 是历史事实，继续保存在原 Review/Repair/Stage 文档中。活动 candidate 的当前字段只从 `DEVELOPMENT_STATE.md` 读取，不得把历史结论提升为当前结论。

## 6. Finding 转换与特殊状态

标准转换：

`OPEN → ADDRESSED → separate recheck → CLOSED`

- `OPEN`：问题已确认且未解决。
- `ADDRESSED`：存在候选修补，但尚未由与修补动作分离的 recheck 验证。本项目 Strict Contract finding 要求独立 full-document re-review。
- `CLOSED`：固定 candidate 与受影响上下文已被分离复核；必须记录证据位置与状态转换理由。
- 修补者不得把自己的 `ADDRESSED` 直接设为 `CLOSED`。

`DEFERRED` 必须记录：Finding ID/严重度、owner、原因、风险、命名 future gate、触发器或截止条件、补验/关闭证据、未满足后果。项目级 S4R-003 gate 要求 Release Candidate/正式发布前完成真实外接显示器矩阵；其当前 Finding 状态、owner 和触发条件只在 `DEVELOPMENT_STATE.md` 记录。该 gate 未关闭时禁止 RC、签名、公证和正式发布。

`ACCEPTED_RISK` 必须记录：授权 owner、残余风险的精确范围、理由、受影响资产/行为、expiry 或 re-review trigger、禁止扩大范围的边界。它不等于 `CLOSED`、`VERIFIED`、final acceptance 或 deployment authorization；当前是否存在 accepted risk 只读取 `DEVELOPMENT_STATE.md`。

## 7. Approval、授权与默认 execution mode

- Contract approval 接受 intended behavior；implementation authorization 允许一个命名版本下的有界工作包。两者必须分别记录。
- Contract approval 不自动授权 Stage 4D、Stage 5、迁移、部署、生产/外部写入或破坏性操作。
- `next_action`、recommended package、依赖满足或前一阶段完成不产生授权。
- 授权记录必须包含：精确 Contract 版本/candidate、工作包、允许范围、保护范围、execution mode、human gates、立即暂停条件、retry stop、required validation，以及部署/外部写入/破坏性/付费权限。
- 用户明确授权实施后，默认 `execution_mode: continuous`；在边界内可连续完成实现、例行诊断、实质不同修复、验证和状态同步，不逐步请求“继续”。当前 authorization 与 execution mode 只读取 `DEVELOPMENT_STATE.md`。

## 8. Human gates 与立即暂停

人类 gate：

1. Contract check/approval：确认产品语义、范围、非目标、业务规则与验收。
2. Exception decision：只在立即暂停条件或三次无进展停止发生时请求。
3. Final human acceptance：技术验证包完成后，由用户记录 accepted/rejected/accepted_with_risk。
4. Deployment authorization：与 final acceptance 分离，明确目标、环境、外部动作和回滚条件。

出现以下任一项立即暂停，不消耗技术重试次数：需要改变 Contract/产品语义/验收；需要扩大授权或越过保护范围；需要重大架构/数据/安全/隐私/财务/合规决定；破坏性、生产、外部写入、付费或不可逆操作未授权；多个选择导致不同产品结果；必要证据不可获得却会被推断完成；物质操作缺少安全回滚；固定 candidate 身份失效。

## 9. 三次无实质进展停止规则

仅适用于已授权范围内的普通技术 blocker。每个有效循环必须包含：新失败证据、基于证据的因果假设、与前轮实质不同的有界修补、最小相关验证、实际结果及其证明/否定内容。

重复命令、等价措辞、格式/注释、没有新证据的重试不计循环。连续三次有效循环无实质进展后必须停止修改，保留安全可恢复状态，不弱化 Contract/测试/权限/安全；报告三轮证据、共同原因、保留或回退建议、有限选项和恢复所需的精确人类决定。解决原 blocker 或出现真正独立的新 blocker 后才重置计数。

## 10. 验证证据绑定与失效

每项 verification claim 必须记录：requirement/acceptance ID、Contract 版本、candidate/manifest fingerprint、代码 revision 或源码/产物指纹、环境和关键配置、命令/方法、日期、实际结果、限制与未测范围。

- 自动测试只证明实际覆盖的行为；Contract review、迁移、恢复、真实硬件或真实系统要求不能由不相关绿色测试替代。
- Contract、代码路径、schema、依赖、配置、平台或环境变化影响覆盖时，证据必须标记 stale 或缩小 coverage；不得复制 `last_verified`。
- Stage 1～3 历史 `verified` 只覆盖其绑定的旧 approved Contract；不自动覆盖后继 candidate delta。
- 任一 candidate 的 manifest/cmp 只证明文档身份和字节完整性，不证明语义 Review conclusion、代码实现或技术 verified。

## 11. Final acceptance 与 deployment

- Final human acceptance 单独记录 `PENDING / ACCEPTED / REJECTED / ACCEPTED_WITH_RISK`，并绑定精确 Contract、delivery evidence 和提交给用户的 acceptance packet。
- 不从用户沉默、测试通过、合并、任务完成或 `verified` 推断 acceptance。
- `ACCEPTED_WITH_RISK` 还必须记录 owner、残余风险、范围、理由和 expiry/review trigger。
- Deployment authorization 单独记录 `NOT_AUTHORIZED / AUTHORIZED`；授权时必须包含目标环境、发布物 fingerprint、允许的外部/生产动作、回滚与停止条件。
- S4R-003 未独立关闭时，无论其他字段状态如何，Deployment authorization 不得覆盖其 Release hard gate；是否关闭只读取 `DEVELOPMENT_STATE.md` 及其链接的独立证据。

## 12. 原子同步与历史保护

物质状态转换必须在同一工作包同步：活动 Contract metadata（若授权修改）、Review conclusion 与 Findings、`SPEC_INDEX.md`、`DEVELOPMENT_STATE.md`、Stage/证据引用和 `last_verified` coverage。无法全部一致更新时必须报告 document drift，不得宣称迁移、批准、关闭或验证完成。

历史 Review、Repair、Decision、Stage 报告、旧 candidate 和 manifest 保留原文与原身份，不机械改名、不追写新轴、不覆盖旧结论。活动状态只链接并解释其适用轴；新治理不追溯改变历史事实。

## 13. Artifact Plan、阈值与恢复后路径真实性

本项目所有会产生物质构建、测试、截图、录屏、`.xcresult`、fixed input 或归档的工作包，必须遵循总 `artifact-lifecycle.md`、`xcode-macos-artifact-lifecycle.md` 与 `artifact-lifecycle-bad-cases.md`。

项目固定门禁：

1. Artifact Plan 至少记录工作包、源码基线、唯一临时根、candidate/sealed evidence 根、绝对阈值、放大倍率阈值、保护集和文件处置权限。
2. Xcode 默认使用 `/private/tmp/visual-income-check-in/<stage>/<run-id>/DerivedData`；`.xcresult` 与选定证据必须在不同根，禁止把 DerivedData、Build、Index、ModuleCache 或整棵 Logs 作为 sealed evidence。
3. 默认预警阈值为：单 Stage DerivedData `>2 GiB`、项目内缓存合计 `>5 GiB`、单树 `>50,000` 文件、整树备份计划 `>1 GiB`、fixed input dataless `>0`。源码 `<100 MiB` 时，生成物同时 `>1 GiB` 且 `>50x` 源码也触发预警。
4. 首个阈值触发即停止继续生成同类产物，进行精确路径只读盘点。不得把清理、迁移、压缩、整树复制或 fixed-evidence 替换当作技术重试循环。
5. Stage close/handoff 必须形成 Artifact Disposition；technical verification、final acceptance、deployment authorization 与 cleanup/migration 状态继续保持独立。
6. `DEVELOPMENT_STATE.md` 和 `SPEC_INDEX.md` 只能把当前可读且身份可验证的路径标为 active。归档中存在但未恢复到活动路径的输入必须标记为 archived/unavailable，不能直接用于新的 readiness 或 verification claim。

恢复基线（2026-08-21）：当前源码工作树约 `10,828 KiB`、209 个普通文件；原始 iCloud 归档中的 `.可视收入打卡机-stage8-build-backup` 约 `17,830,200 KiB`，放大超过 `1,500x`。该记录绑定 `BC-ART-002`，只用于检测和预防，不授权修改原目录。


## Stage 9 批量收尾执行规则

来源：2026-09-07 用户明确流程调整授权。剩余软件工作按共享代码、测试环境与依赖批量实施、集中验证、批量独立复审；取消逐 coverage row 授权/构建/复审/返回管理对话要求。开发与 reviewer 角色分离，reviewer 不修改代码，实施者不裁决自身改动。当前授权与状态只读取 DEVELOPMENT_STATE.md；不改变 Approved Contract 语义、验收含义、真实硬件/系统 gate、最终人类接受或发布硬门禁。历史 ledger/reviews/seals 不覆盖。
