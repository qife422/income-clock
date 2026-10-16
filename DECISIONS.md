---
title: 可视收入打卡机决策记录
document_type: decision_log
status: active
last_updated: 2026-08-17
---

# 决策记录

## PD-001 — 批准 DST v1 Contract

- 日期：2026-08-15
- 状态：`approved`
- 决策：批准 Product Spec 0.7、UI Spec 0.4、Technical Design 0.3，采用 DST v1 本地日程时间安全策略。
- 核心约束：当前工作日的本地上下班时间必须存在且可唯一解析；不得静默校正或猜测；失败时不发布业务 ViewState 或成功反馈，保留原始数据并提供可恢复日程时间错误；Settings 必须在持久化前拒绝无效日程，用户可调整时间后重试。
- 替代版本：Product Spec 0.7 替代 0.6；UI Spec 0.4 替代 0.3；Technical Design 0.3 替代 0.2。
- 授权边界：本决策只批准 Contract，不授权修改生产代码或测试代码，不授权修复 Stage 3 findings，不授权进入或实现 Stage 4。
- 依据：`SPEC.md` 0.7、`UI_SPEC.md` 0.4、`TECH_SPEC.md` 0.3。
- 历史证据边界：`PD-001` 继续证明 Product 0.7、UI 0.4、Technical 0.3 曾在 2026-08-15 获得批准；但项目没有保留这些版本的不可变内容快照、稳定哈希或可重放差异，当前同名文件已是后继候选稿。因此不得伪造旧快照，也不能对后继候选稿相对这些旧版本作内容级增量证明。

## PD-002 — 延期 S4R-003 真实物理系统矩阵

- 日期：2026-08-16
- 状态：`approved`
- 决策：将 S4R-003 finding 明确标记为 `deferred`，从 Stage 5 开发前门槛调整为 Release Candidate/正式发布前硬门槛。阶段继续使用项目既有合法状态；Stage 4 保持 `review`，不得标记 `verified`。
- 延期原因：当前缺少物理外接显示器，无法取得真实系统证据。
- 风险：多显示器归属和位置恢复、断开/重连、Dock/scale、Space/全屏、睡眠/唤醒以及 `visibleFrame` 约束尚未经过真实窗口服务器与物理硬件验证；现有单元、AppKit harness、XCUITest、fake screen 和合成通知不能排除真实系统缺陷。
- 补验条件：未来必须使用真实外接显示器完整执行并记录扩展显示模式、主副屏切换、外接屏断开与重新连接、Dock 位置变化、分辨率和缩放变化、Space 与全屏切换、睡眠及唤醒恢复，并证明全过程 Panel 始终约束在当前 `visibleFrame` 内。结果须经独立 Review；失败项另行授权修复后重验。
- 禁止发布条件：任一补验项未执行、失败、证据不可审计，或 S4R-003 仍为 `deferred`/`open` 时，禁止生成或对外分发 Release Candidate、正式版、签名发布包或公证发布物；不得标记 closed、passed 或 verified。
- 状态语义：`deferred` 是 finding 级延期状态，不等于风险接受、验收通过或阶段验证；不新增阶段级 `conditional`。Stage 4 的 `last_verified` 保持 `null`。
- 授权边界：本决策不授权修改生产代码或测试代码，不授权 Stage 5，不授权发布；Product 0.8、UI 0.5、Technical 0.4 候选 Contract 仍须独立 Review，不能自行标记 approved。
- 依据：当前设备仅有内建显示器的真实系统探针结果；`STAGE4_REVIEW.md` 的 S4R-003 缺口；Product Spec 0.8、UI Spec 0.5、Technical Design 0.4 候选更新。
- 审查方式：由于 PD-001 对应的旧版内容证据缺失，Product 0.8、UI 0.5、Technical 0.4 不得继续按“已证明只包含 PD-002 增量”审查；必须固定当前 candidate 快照和 SHA-256，并对三份候选 Contract 执行完整文档 re-review。candidate 快照不具有 approved 身份。

## PD-003 — 批准 Product 0.8 / UI 0.5 / Technical 0.4 并授权 Stage 4D

- 日期：2026-08-17
- Contract approval：`approved`。用户接受固定 `contract_snapshots/2026-08-17-pd2rr-007-recovery-transaction-repair-candidates/SHA256SUMS` 所标识的精确 intended behavior。
- 批准身份：Product 0.8 `62c630f748818da14333aabe58f2ebb7b9da45ed1ad1fb8ce32d66a337026dea`；UI 0.5 `cfd5e3a733347c0fbd326cdcfbede31b0e5b0909b72167b0eee19a1fa6af36fe`；Technical 0.4 `d32be84b0eb2cee69f7541c352ca7efc3e0657e0720c451e6bb59f78b230a7e6`；manifest SHA-256 `10d994a8ca452aaba742c0e6de25fd763f3ea6d42d826c42918e87fb4eaed150`。
- Review 依据：`PD2RR_007_RECOVERY_TRANSACTION_REPAIR_REREVIEW.md`，Review status `completed`、conclusion `READY`、PD2RR-001～007 `CLOSED`。
- Stage 4D authorization：立即授权 Technical 0.4 §18.1 定义的 Domain、Persistence、BusinessStore 与 Tests delta，`execution_mode: continuous`；允许范围和保护范围以用户 2026-08-17 授权及 `DEVELOPMENT_STATE.md` 为准。
- Stage 5 conditional pre-authorization：只有 Stage 4D 完整实现与回归通过、证据绑定准确、独立 Review 无 OPEN/ADDRESSED P0/P1/P2、delivery 独立判定 `verified`、批准 Contract 未改变且没有新的人类产品/安全/数据/架构决定时自动生效；否则不得进入 Stage 5。
- 独立边界：Contract approval 不等于 implementation verification、Final human acceptance 或 Deployment authorization。Final human acceptance 继续 `PENDING`，Deployment authorization 继续 `NOT_AUTHORIZED`。
- Release hard gate：S4R-003 继续 `DEFERRED / RELEASE HARD GATE`；真实外接显示器矩阵独立关闭前禁止 RC、签名、公证、正式发布和部署。
