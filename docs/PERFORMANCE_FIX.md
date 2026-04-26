# 后台 CPU 占用优化跟踪

> 当前分支：v4.0 SDK 迁移（plugin refactor）
> 触发场景：用户实测 Activity Monitor 显示 `Claude Statistics Debug` 443% CPU、累计 45 小时 CPU 时间

## 问题快照

`sample` 抓 8 秒（PID 64626，270 sessions / 18 projects，Claude 活跃会话写入 transcript）：

- 主线程：100% 跑 `SessionViewModel.recomputeGroups()` + `SessionStats` computed properties
- 后台线程 ×7 并发：`SessionDataStore.processDirtyIds → ClaudeProvider.scanSessions → SessionScanner.readCwd`，外加多个线程并发跑 `SessionStats.init(from:)` JSON 反序列化
- 3 个 user-interactive-qos 线程在 `__DISPATCH_ROOT_QUEUE_CONTENDED_WAIT__` 抢调度
- 总线程数 35（与截图一致）

## 根因（按危害程度排序）

### R1. `processDirtyIds` 每次 watcher fire 都跑全量 `scanSessions()`

`ClaudeStatistics/Services/SessionDataStore.swift:332`

```swift
let scannedSessions = Self.deduplicatedSessions(provider.scanSessions(), provider: providerKind)
let cache = db.loadAllCached(provider: providerKind)
```

watcher 已经通过 `changedSessionIds` 给出精确的 dirty session 列表，但代码不论 ids 是否非空，都重新扫所有项目目录、读所有 transcript 的 cwd、解码所有 cache。270 sessions 时单次扫描已经 >2s，超过 watcher 的 2s debounce。

`Task.detached` 没有 in-flight 合并：watcher 每次 fire 都新建一个 detached Task，旧的没结束新的就开始。**多个并发 task 同时跑全量 scan + cache decode → 抢 CPU 互相饿死 → 永久高占用**。

这段逻辑至少从 `80169d1`（v3.1 release）就存在，未在 SDK 迁移分支被改动。但 270 sessions 这个规模刚跨过 watcher debounce 临界点，加上 R3 的放大效应，于是"突然炸了"。

### R2. `SessionScanner.readCwd` 是 O(N²) 字符串重 decode

`ClaudeStatistics/Providers/Claude/SessionScanner.swift:88-131`

每读 8KB chunk 就把**整个累积 buffer**重新 UTF-8 decode 一次，并从头 `range(of: "\"cwd\":\"")` 搜一遍。文件越大叠加越严重；270 个 transcript 文件每次 scanSessions 都会全部重读一遍。

样本证据：`StringProtocol.range(of:options:range:locale:)` 占据 readCwd 总时间 99%。

### R3. SDK 迁移期间引入的放大器

未提交改动：

- `Providers/Claude/TranscriptParser.swift` 在 `parseSessionQuick` 末尾新加 `findTopicByLineScan` fallback——找不到 topic 就重新打开文件再扫 100 行 JSON。每个 dirty session 多一次重 IO。
- `Models/Session.swift` 把 `provider` 从 `ProviderKind` 枚举改成 `String` rawValue（SDK 解耦），`ActiveSessionsTracker` 等 hot path 现在每次都要构造 `ProviderKind(rawValue:)` 做反向查找。

### R4. `SessionStats` computed property 反复重算（次要）

`Plugins/Sources/ClaudeStatisticsKit/SessionStats.swift:46/56/116/131` —— `modelBreakdown` / `toolUseCounts` / `totalTokens` / `toolUseTotal` 每次访问都遍历 `fiveMinSlices`。`SessionViewModel.recomputeGroups` 在 R1 反复发布 `$sessions` 时被 Combine debounce 触发，每次主线程都重算一遍所有 270 个 session 的衍生统计。

### R5. `DiagnosticLogger.log` 每次新建 `NSISO8601DateFormatter`（微优化）

`ClaudeStatistics/Services/DiagnosticLogger.swift:99` —— 每条 verbose 日志 alloc 一次，sample 里能看到 8 个 sample 在格式化器初始化里。

## 修复计划

| 编号 | 改动 | 状态 | 预期收益 |
|------|------|------|---------|
| P0-a | `processDirtyIds` 在 `changedIds` 非空且 `forceRescan=false` 时跳过全量 `scanSessions`，用 `self.sessions` 直接挑出 dirty session | [x] | 单次工作量降两个数量级 |
| P0-b | `processDirtyIds` 加 in-flight 合并：一个 detached Task 在跑时，新 fire 只 mark dirty + pending；当前 task 结束后统一处理累积 dirty ids | [x] | 消除并发任务堆积，35 线程→3 |
| P0-c | `processDirtyIds` 在 forceRescan 路径也用 fingerprint-only load（`stats_json IS NOT NULL` 不解码 JSON），仅对真正 dirty 的 sessions decode JSON | [x] | 每次 forceRescan 不再解码 270 个 cache JSON |
| P1-a | `SessionScanner.readCwd` 改成滚动窗口：只在新 chunk 边界向前几字节搜，永不重 decode 整 buffer | [x] | 单文件 readCwd O(N²)→O(N)，270 文件全扫 5–10s→<1s |
| P1-b | （可选）把 cwd 持久化到 cache，未变化文件直接读 cache 不再 readCwd | [ ] | 增量 scan 几乎零 IO |
| B-a | `CodexSessionScanner` 用 POSIX `lstat()` 替代 `attributesOfItem` | [x] | 文件元数据成本 67% → 5% |
| B-b | `CodexSessionScanner` 缓存 SQLite db handle，主 db 文件 fingerprint 不变就复用 | [x] | 消除每次 scan 的 SQLite open + schema-prepare 开销 |
| P2 | `DiagnosticLogger` 持有静态 `ISO8601DateFormatter` 实例 | [ ] | 每条日志省 ~100us |
| P3 | `SessionStats` 把 O(slices) 的 getter 改成 stored aggregates，parser 末尾 + Decoder init 末尾各调一次 `precomputeAggregates()` | [x] | View 读 `modelBreakdown` / `toolUseCounts` / `totalTokens` 等从 O(slices) → O(1) |
| S-a | `SessionDataStore.dailyHeatmapData` 改成 stored cache（`_dailyHeatmapCache`），在 `rebucket()` / `rebucketAllTime()` 末尾通过 `recomputeAllTimeAggregates()` 一次性算 | [x] | AllTimeView body 不再每次 re-render 触发 270 sessions × 100 slices 全量遍历 |
| S-b | `SessionDataStore.topProjects` 同样改成 stored cache（`_topProjectsCache`），与 heatmap 在同一遍 O(sessions × slices) 循环里一起算 | [x] | 进入统计页面时不再多次重算 top projects |
| P4 | （可选）`ClaudeProvider.parseSession` 改成增量解析，只读新增的 transcript 字节 | [ ] | active 场景 CPU 进一步下降，10% → 个位数 |

## 实测结果

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| 峰值 CPU | 443% | ~30% |
| 平均 CPU（user 活跃用 Claude） | ~40% | ~7-8% |
| Idle CPU（无活跃 transcript 写入） | 持续 ~20% | <1%（实测 T+90s 0.5%） |
| 并发线程数 | 35（堆积） | 3（每 store 一个 in-flight） |
| `CodexSessionScanner.scanSessions` 在 sample 中 | 主热点（~10% CPU） | 完全消失（缓存命中） |

## 验收标准

修复 P0+P1 后用 `sample` 再抓一次，必须满足：

1. **idle 场景**（关闭所有 Claude 会话 60s 后）：60 秒内 utime+stime 增量 < 1s
2. **active 场景**（用户在 Claude 里持续跑 Opus）：瞬时 CPU < 30%、不出现 200%+ 持续占用
3. **启动场景**（冷启动加载 270 sessions）：parseProgress 完成时间 < 5s
4. **线程数**：稳态 ≤ 5 个 active 线程，不再出现 dispatch root queue 拥塞

不达标即回滚。

## 测试步骤

```bash
# 1. 杀掉运行中实例
pkill -f "Claude Statistics Debug"

# 2. 修复 + 重启
bash scripts/run-debug.sh

# 3. 等待初次扫描完成（观察 parseProgress 消失）

# 4. idle 验证
PID=$(pgrep -f "Claude Statistics Debug" | head -1)
ps -o utime,stime -p $PID; sleep 60; ps -o utime,stime -p $PID
# 增量应 < 1s

# 5. active 验证
# 在另一个终端跑 claude code 任意会话写入 transcript
sample $PID 8 -mayDie 2>/dev/null > /tmp/cs-after.txt
# 检查 Thread 数量、检查 scanSessions 调用次数
grep -c "ClaudeProvider.scanSessions" /tmp/cs-after.txt
# 应远小于修复前
```

## 不在本次范围

- SwiftUI body 重渲染本身的优化（属于 R4 之上的另一层问题，需要 EquatableView / 视图拆分，工作量大）
- `db.loadAllCached` 的全量 JSON 解码——P0-a 落地后这个调用频率从持续→仅初次启动，性价比不再吸引
- Codex / Gemini provider 的对应 readCwd 类逻辑（如有）——本次只修 Claude，验证收益后再推广
