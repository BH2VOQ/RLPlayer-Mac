# 1.1.7.38 — native_ui_functional 偶发 bus error 根因与修复（task-4）

## 1. 现象与现场的纠正

progress/任务书把这条记为「偶发 bus error，专辑详情导航处，未能复现」。本轮 4 次
`rlplayer_native --audit` 里 **1 次 EXIT=138**，崩溃报告
`evidence/native-audit-sigbus-140145.ips` 给的栈**不在**专辑详情：

    EXC_BAD_ACCESS / SIGBUS / KERN_PROTECTION_FAILURE at 0x19bb28000
      _platform_memmove
      std::__1::basic_string::__assign_no_alias<true>
      rta::update::CheckResult::operator=
      -[RLPUpdateWindowController handleCheckResult:manually:]
      _dispatch_call_block_and_release / _dispatch_main_queue_drain
      Pump(double) <- RLPRunFunctionalAudit <- main

## 2. 根因（最小探针证实，非猜测）

DoneFn = void(^)(const rta::update::CheckResult &r)。旧实现把 r 直接 dispatch_async 到主队列。
Block 捕获 `const T&` 参数是**引用捕获而非拷贝**：最小探针 f(const S&, void(^)(void)) 里
先在 block 内捕获、再析构 S、最后调 block ⟹ **Segmentation fault（exit 139）**。
所以 done(result) 返回后生产者 CheckResult 已析构：remoteVersion 等短串走 SSO 看着正常，
notes/downloadUrl 走堆，被释放后主线程再读就是 SIGBUS。偶发机制 = 时机 + 字符串长度。

## 3. 修复

postCheckResult: 接缝里，跳线程**之前**深拷贝：
std::shared_ptr<rta::update::CheckResult> owned = std::make_shared<...>(r);
dispatch_async(main, ^{ [self_ handleCheckResult:*owned manually:manually]; });

## 4. 判据（先红后绿）

新 ctest `native_update_result_lifetime`：400 KiB notes 的 CheckResult 交给接缝后立即离开
作用域，再排空主队列，断言主线程看到完整 notes（尾部哨兵 ZEND）与远端版本号。

| 时点 | 结果 | 证据 |
|---|---|---|
| 旧实现（引用捕获） | **3 PASS / 2 FAIL**（want=409604 got=0） | native-update-uaf-red-20261114.log |
| 新实现（深拷贝） | **5 PASS / 0 FAIL** | native-update-uaf-green-20261114.log |

## 5. 修复后稳定性：连续 4 轮 audit

| 轮 | 结果 | exit |
|---|---|---|
| 1 | 246 passed, 0 failed | 0 |
| 2 | 246 passed, 0 failed | 0 |
| 3 | 246 passed, 0 failed | 0 |
| 4 | 246 passed, 0 failed | 0 |

日志 `evidence/native-task4-audit-4rounds-after-fix-20261114.log`。
**如实**：修复前 4 轮崩 1 轮（25%）；修复后 4 轮 0 崩溃。4 轮是小样本，不宣称概率归零；
但根因是确定性的所有权缺失，不是随机内存损坏。历史同一 flake 记 2/5，本轮 1/4，合计 3/9。

## 6. 挂账

- ProgressFn 也是 const NativeProgress&，但用法是**同步**取 detail 再 dispatch，不持引用，
  本轮判安全（未加判据）。
- 未在 ASan 下复跑（仓内未配 ASan target）；判据用大块堆缓冲制造确定性读悬垂。
