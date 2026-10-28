# GPU 精度实测（macOS / Metal）

状态：**测量工具已完成并跑出本机数据**；生产路径发现 1 个真 BUG（拖尾丢失，见 §6），**未修**（本任务只做测量）。
日期：2026-10-26 · 分支 `feat/macos-platform` · 基线 `743cd5f`(v1.0.2)
上游对照：`RLPlayer-upstream` @ `68e628f`，`tools/gpu_precision.cpp`（260 行，CUDA/HIP）

---

## 1. 一句话结论

**mac 的 Metal 后端精度与 HIP 同量级（卷积 −126.5 ~ −148.4 dB 相对 RMS），但升频差 10 个数量级
（float vs FP64）；性能结论与上游相反——按生产的 4096 样分块形态，GPU 卷积在任何 IR 长度下都比 CPU 慢
2.1~3.6 倍（IR 越长亏越多），上游的「IR≥65536 走 GPU」在 mac 上不成立。**

---

## 2. 本机环境（实测）

| 项 | 值 |
|---|---|
| 系统 / CPU | macOS 27.0.1 / arm64 / Apple M4 |
| 编译器 | Apple clang 21.0.0（`-O2 -std=c++20`） |
| GPU 后端 | `librtagpu.dylib`（`src/gpu/gpu_metal.mm`，72 KB，运行时编译 MSL） |
| 后端构建 | `bash tools/build_gpu_metal_mac.sh`（已存在，本次未重建） |
| 探针构建 | `clang++ -O2 -std=c++20 -I src tools/gpu_precision.cpp -o build-gpuprec/gpu_precision -ldl` |
| 音频设备 | **全程未打开**（纯离线，铁律 1） |

---

## 3. 铁律 5 双门（都过了才采数据）

| 门 | 判据 | 本机实测 | 结果 |
|---|---|---|---|
| 门 1a | 直接 `dlopen` + `rta_gpu_available()` | `=1` | ✅ |
| 门 1b | `rta::dsp::GpuBridge`（**生产路径**） | `available=1`，`status="GPU 卷积可用（librtagpu.dylib）"` | ✅ |
| 门 2a | 恒等卷积（δ IR），判据 ≤1e-5 | `rc=0`，`max\|y−x\| = 1.979e-08` | ✅ |
| 门 2b | 多分区（随机 IR=2048 / block=512 ⟹ **P=4**），判据 ≤1e-5 | `rc=0`，`max\|Δ\|/峰值 = 6.122e-08` | ✅ |

> **为什么门 1 要查两条路径**：`test_gpu_bridge.cpp` 的文件头记录过「桥接层没取符号、GPU 从未真正启用」
> 的事故。只测直接 `dlopen` 会漏掉这一类，所以生产桥接也必须单独验。
>
> **为什么门 2 要有 2b**：δ IR 只有 P=1 个分区，测不出「跨分区累加」——而那正是 IR 长度门控最依赖的路径。
> ⚠️ 本工具第一版把 2b 写成 `IR=64 / block=512`（P 实际等于 1），名字叫「多分区」却只测了单分区；
> 已改成 `IR=2048 / block=512`（P=4）。判据与名称不符就是假测试（铁律 3）。

**参考基准自证**：`StreamingConvolver` vs `direct_convolve` 定义式 = −273.5 dB（45.4 bit）。
参考本身可信，后面的误差都相对它算。

---

## 4. 卷积精度矩阵（本机实测）

**测试条件**：输入 65536 样，fs=48k，音乐样（997/1234/3141 Hz 正弦 + 1/f 粉噪，峰值 0.7）；
IR 为房间校正样（指数衰减 + 一阶平滑噪声，归一化）；
参考 = CPU 双精度 `StreamingConvolver`（已对齐 B 帧算法延迟）；
GPU = `rta_gpu_convolve` **整块 API**（mac：CPU 端 double FFT → 只把频谱降 float → GPU 复数乘累加 → CPU 端 double IFFT）。

| B | IR | 相对RMS dB | 等效bit | max\|Δ\|/峰值 | 带内占比 | 差异样数 | CPU ms | GPU ms | GPU/CPU |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 512 | 1024 | −144.3 | 24.0 | 9.38e-08 | 1.000 | 65023 | 2.8 | 3.1 | 1.12x |
| 512 | 16384 | −134.9 | 22.4 | 2.96e-07 | 1.000 | 65023 | 5.4 | 3.8 | 0.70x |
| 512 | 65536 | **−126.5（最差）** | 21.0 | 6.72e-07 | 1.000 | 65023 | 14.4 | 4.8 | 0.34x |
| 512 | 262144 | −132.9 | 22.1 | 4.10e-07 | 1.000 | 65023 | 55.9 | 8.6 | 0.15x |
| 1024 | 1024 | **−148.4（最好）** | 24.6 | 6.04e-08 | 1.000 | 64511 | 3.0 | 3.3 | 1.12x |
| 1024 | 16384 | −137.2 | 22.8 | 3.02e-07 | 1.000 | 64511 | 4.2 | 4.1 | 0.96x |
| 1024 | 65536 | −130.6 | 21.7 | 5.91e-07 | 1.000 | 64511 | 8.4 | 4.7 | 0.56x |
| 1024 | 262144 | −133.9 | 22.2 | 2.96e-07 | 1.000 | 64511 | 28.8 | 9.6 | 0.33x |
| 2048 | 1024 | −147.1 | 24.4 | 7.85e-08 | 1.000 | 63487 | 3.2 | 3.5 | 1.08x |
| 2048 | 16384 | −139.7 | 23.2 | 1.80e-07 | 1.000 | 63487 | 3.8 | 4.0 | 1.05x |
| 2048 | 65536 | −134.4 | 22.3 | 3.46e-07 | 1.000 | 63487 | 5.9 | 5.4 | 0.91x |
| 2048 | 262144 | −136.6 | 22.7 | 2.76e-07 | 1.000 | 63487 | 15.4 | 9.9 | 0.64x |
| 4096 | 1024 | −147.0 | 24.4 | 6.45e-08 | 1.000 | 61439 | 3.5 | 4.2 | 1.22x |
| 4096 | 16384 | −141.3 | 23.5 | 1.31e-07 | 1.000 | 61439 | 3.7 | 4.5 | 1.21x |
| 4096 | 65536 | −140.0 | 23.2 | 1.64e-07 | 1.000 | 61439 | 4.8 | 5.9 | 1.22x |
| 4096 | 262144 | −139.1 | 23.1 | 1.64e-07 | 1.000 | 61439 | 9.3 | 10.5 | 1.13x |

**误差列 3 次重跑逐位一致**（确定性可复现）；耗时为 3 次取最小值，会随机器负载小幅浮动。

### 解读

1. **精度**：最差 −126.5 dB（≈21.0 bit 等效），最好 −148.4 dB。误差谱带内占比 **1.000** —— 误差不是白化
   高频噪声，而是与信号同谱（掩蔽友好）。max|Δ|/峰值 ≤ 6.72e-07，远低于任何抖动地板。
2. **与 HIP 的对照**：上游 HIP 实测 −127.6 ~ −147.8 dB，本机 −126.5 ~ −148.4 dB。**量级一致、极值不同**。
   数值路径两边其实相同（都已核实：`gpu_conv_hip.cpp:78/87` 与 `gpu_metal.mm:456/472` 都是
   "double FFT → 频谱降 float → GPU 乘累加 → double IFFT"），差异来自 CPU/编译器/驱动不同。
3. **趋势**：同一 B 下 IR 越长误差略增（分区数 P 增加、累加项变多）；同一 IR 下 B 越大误差越小。
   与上游同向，但**具体数字不能互抄**。
4. **性能**：整块口径下 GPU 在 IR ≥ 16384 时开始占优（0.16x~0.94x），**但 IR=1024 时 GPU 一律更慢**。
   ⚠️ 这个口径**不是**生产形态，见 §5。

---

## 5. 性能：三种口径必须分开说（这是本任务最重要的方法论结论）

### 5.1 整块口径（上游探针的口径，n=65536 一次吃完）

见 §4 表最后一列：IR=1024 时 GPU 慢 7~24%；IR≥16384 时 GPU 快 6%~84%；IR=262144 时快 3~6 倍。

### 5.2 16 块累加（模拟 rtaweb 生产者 kChunk=4096）

| IR | CPU 合计 ms | GPU 合计 ms | GPU/CPU | 判定 |
|---:|---:|---:|---:|---|
| 65536 | 9.59 | 35.50 | 3.70x | GPU 更慢 |
| 262144 | 29.15 | 105.39 | 3.62x | GPU 更慢 |

### 5.3 ★ 单块调用（**生产的真实形态**：`n=4096`, `block=cfg_.convBlock=1024`）

生产代码是 `src/engine/pipeline.h:323`：
`gb.convolve(w.data(), w.size(), cp.ir.data(), cp.ir.size(), tmp.data(), (int)cfg_.convBlock)`
其中 `w.size() ≤ 4096`（`tools/rtaweb.cpp:3034` `kChunk=4096`），`cfg_.convBlock` 默认 1024（`pipeline.h:77`）。

| IR | CPU 单块 ms | GPU 单块 ms | GPU/CPU | 判定 |
|---:|---:|---:|---:|---|
| 1024 | 0.165 | 0.356 | 2.15x | GPU 更慢 |
| 4096 | 0.187 | 0.426 | 2.28x | GPU 更慢 |
| 16384 | 0.252 | 0.693 | 2.75x | GPU 更慢 |
| 32768 | 0.344 | 1.037 | 3.02x | GPU 更慢 |
| 65536 | 0.527 | 1.683 | 3.20x | GPU 更慢 |
| 131072 | 0.906 | 3.236 | 3.57x | GPU 更慢 |
| 262144 | 1.743 | 6.113 | **3.51x** | GPU 更慢 |

**⟹ 在 mac 的生产形态下，GPU 卷积在任何 IR 长度下都是负优化，且 IR 越长亏得越多。**

**为什么与上游相反**（机理，不是猜测）：
- mac 的 `rta_gpu_convolve` 把 **FFT 留在 CPU**（`gpu_metal.mm` §3 的既定取舍），GPU 只做逐点复数乘累加。
  每次调用的固定开销 = 命令缓冲提交 + `waitUntilCompleted` + 频谱 float 往返，
  而 4096 样 / block=1024 的块只够 P 次乘加，收益压不过固定开销。
- 上游独显是 H2D/D2H 显式拷贝 + 每次 `hipMalloc/hipFree`，但它一次吃 262144 样，
  摊薄后能赢；mac 分块形态吃不到这个摊薄。
- CPU 侧 `StreamingConvolver` 是纯双精度、跨块保持状态、无任何提交开销。

### 5.4 升频（对照：GPU 在这里是大幅占优的）

| 形态 | 转换 | CPU ms | GPU ms | GPU/CPU |
|---|---|---:|---:|---:|
| 整块 32768 样 | 44.1k→352800 | 2425.0 | 33.0 | 0.014x |
| 整块 32768 样 | 44.1k→384000 | 44.2 | 4.4 | 0.10x |
| 分块 4×4096 | 44.1k→352800 | 605.9 | 21.1 | 0.035x |
| 分块 4×4096 | 44.1k→384000 | 21.7 | 4.0 | 0.183x |

**升频与卷积的关键差异**：`PolyphaseResampler` 把 `hist_` 留在自己身上跨块累积，每次把"截至当前的历史"
交给 GPU ⟹ **分块调用不会丢拖尾**。卷积那边 `GpuBridge::convolve` 是无状态整块 API，所以会丢（§6）。
形态相同、正确性却不同，**不能想当然类推**。

---

## 6. ⚠️ 生产路径的真 BUG：GPU 卷积逐块调用丢失 IR 拖尾

### 现象（实测，可复现）

`tools/gpu_precision` 第 6 节：δ 放在样点 0，IR=65536，按生产形态 16 块 × 4096 样逐块调用。

```
逐块最大 |out|：1e+00 0e+00 0e+00 0e+00 0e+00 ... 0e+00   ← 只有第 0 块有输出
与真值不符的样点数 = 65409 / 65536
相对 RMS 误差 = −1.63 dB（等效 0.3 bit）
```

IR=16384 / 块=4096 的版本（`tests/test_gpu_precision.cpp` 第 4 节）：不符 16200/16384，块 1..3 全零。

### 根因（代码级）

- `rta_gpu_convolve` 是**无状态整块卷积**：每次调用从零状态算 `conv(本块, ir)`（`gpu_metal.mm:419-531`）。
- 生产管线 `pipeline.h:317-333` 按 4096 样一块**逐块**调用它，且 `w` 每块都是新的。
- ⟹ 「上一块输入 × 本块 IR 的尾巴」这一项**没有任何地方被计算**。
  只要 `irLen > 块长`，就丢掉 `1 − 块长/irLen` 的 IR 能量。
- 对比 CPU 路径：`ss_.conv[c]->process(...)` 用持久 `StreamingConvolver`，跨块保状态，所以 CPU 路径正确。

### 影响面（重要：现在还没暴露）

- 生产默认 `cp.useGpu = false`（`pipeline.h:41`），且 `tools/rtaweb.cpp` 的 `p.convGpu` 默认 `false`（`:308`）
  ⟹ **当前默认路径不受影响**。
- 一旦用户在设置里打开「IR 卷积走 GPU」（`irgpu=1`），**只要 IR 长于 4096 抽头就会听出明显错误**
  （房间校正 IR 动辄 65536~262144 ⟹ 丢掉 94%~98% 的 IR）。
- 这与 mac 的 `IR≥65536` 门控无关：**门控决定"要不要走 GPU"，一旦走就是错的**。

### 建议修法（本任务未实施，交主控决策）

三条路，按代价从小到大：

1. **在 `GpuBridge` 侧加流式状态**：缓存上一块的输入尾 + 用 overlap-add 累加 IR 尾巴。
   代价最小、改动集中在 `gpu_bridge.h`；但要小心多声道共用实例的问题（`GpuBridge` 是单例）。
2. **在 `pipeline.h` 侧改调用形态**：攒够 `≥ irLen` 样再调一次 GPU（延迟变大，不适合实时）。
3. **最保守**：mac 上直接禁用 GPU 卷积（`cp.useGpu` 强制 false / 删掉 `irgpu` 开关），
   理由是本机实测 GPU 卷积在任何 IR 下都更慢（§5.3），**本来就是负优化**。

> 我的建议是 **3 + 记录**：性能上 GPU 卷积在 mac 无收益，正确性上还有这个 BUG。
> 但这属于功能取舍，按「功能不能删除」铁律必须由用户拍板，不由我决定。

---

## 7. mac 阈值建议（取代 `test_gpu_bridge.cpp` 的 1e-4）

| 判据 | mac 实测 | 建议阈值 | 裕量 |
|---|---:|---:|---|
| 卷积 相对 RMS | 最差 −126.5 dB | **≤ −120 dB** | 6.5 dB（约 2.1 倍能量）¹ |
| 卷积 max\|Δ\|/峰值 | 最差 6.72e-07 | **≤ 2e-6** | 2.98 倍 |
| 升频 相对 RMS（float） | 最差 −132.6 dB | **≤ −100 dB** | 32.6 dB |
| 升频 max\|Δ\|/峰值（float） | 最差 4.39e-07 | **≤ 1e-4** | 228 倍 |

¹ **门禁的覆盖缺口（如实标注）**：`tests/test_gpu_precision.cpp` 的 CPU 参考用 O(N·M) 直接卷积
（为了不依赖 dsp 头、也不引入「参考自己错」的风险），所以 IR 只能取到 16384 量级 ——
32k 样 × 65536 抽头 = 21 亿次乘加，跑一次要几十秒，不适合进门禁。因此门禁实测的两格
（−133.4 / −135.3 dB）**优于**探针的最差格（−126.5 dB @ IR=65536）。−120 dB 这个阈值
是按探针全矩阵定的，对门禁实际覆盖的两格有 13~15 dB 裕量。见 §11 挂账第 10 条。

**为什么比实测松这么多**：门禁的目的是抓「精度掉一个数量级」的回归，不是复述实测值。
要精确值看 `tools/gpu_precision` 的输出。

**为什么不照抄上游**：
- 上游卷积阈值 1e-6（−120 dB）在本机实测 −126.5 dB 下**只剩 6.5 dB 裕量**（约 2.1 倍能量），
  机器/编译器一变就可能假红。本工具的建议值同样是 −120 dB，但依据是本机数据 + 明确裕量，不是抄来的。
- 上游升频阈值 **≤8e-16（≤4 ULP）在 mac 上必然假红**——本机实测 4.39e-07，差 9 个数量级。
  mac 的 Apple GPU 没有 double，升频只能 float。**照抄这个阈值 = 让门禁永远红 = 等于没有门禁。**

---

## 8. GPU 加速开关建议矩阵（mac 实测推导）

| 算子 | 建议 | 依据 |
|---|---|---|
| 升频多相 MAC | **保持默认开**（`gpuResample=true`） | 精度 float 量级（−132.6 dB，远低于 24 bit 容器的 −144 dB 底噪）；速度 6~70 倍。**但 `pipeline.h:52` 注释「输出逐位相同」是错的**，见 §9 |
| 卷积（整块口径） | 按 (IR, B) 联合门控 | IR=1024 一律 CPU；IR≥16384 且 B≤2048 才 GPU 占优 |
| 卷积（**生产 4096 分块口径**） | **建议关** | 任何 IR 下 GPU 慢 2.1~3.6 倍，且正确性有 §6 的 BUG |
| `gpuWorth` 门限 | **不能沿用上游的 `irLen ≥ 65536`** | 上游该值建立在「一次吃 262144 样」的整块口径；mac 生产是 4096 分块，口径不同。若保留 GPU 卷积，门限必须按 §5.3 的表重新定（本机实测：**没有**任何 IR 值能让分块形态的 GPU 占优 ⟹ 门限应设为「永不」） |
| SDM 调制 | **不上 GPU**（维持现状） | 与上游同口径：EC 环路对精度/FMA 敏感，float 环路增益误差足以改变稳定性裕度 |

---

## 9. 顺带发现的注释错误（未改，交主控）

`src/engine/pipeline.h:52`：

```cpp
bool gpuResample = true;    // 用 GPU 做多相升频（rtagpu.dll 缺失时自动退回 CPU，输出逐位相同）
```

**「输出逐位相同」在 mac 上不成立**：本机实测升频 GPU vs CPU 有 1048558/1048576 个差异样点，
max|Δ| = 3.313e-06，相对 RMS −115.4 dB（44.1k→352.8k 整块口径）。

上游在 `docs/WIP-A.md` §5 也发现了同一处问题（他们的实测是 ≤2 ULP），建议改成
「输出偏差 ≤2 ULP」。**但 mac 的口径完全不同**（float，不是 FP64），建议改成：

```cpp
// 用 GPU 做多相升频（librtagpu.dylib 缺失时自动退回 CPU）。
// ⚠️ 偏差不是零：mac 的 Metal 没有 double，升频走 float，
//    实测 max|Δ|/峰值 ≤ 4.4e-07、相对 RMS ≤ −132.6 dB（tools/gpu_precision）。
```

> 本任务只做测量工具，按任务约束**未改**该注释。

---

## 10. 与上游的差异清单（为什么不照抄）

| 维度 | 上游（CUDA/HIP） | mac（Metal） | 后果 |
|---|---|---|---|
| 后端产物 | `rtagpu.dll`，`LoadLibraryA` | `librtagpu.dylib`，`dlopen` | 探针的加载逻辑必须重写 |
| MSL 编译 | 离线 nvcc/hipcc | **运行时** `newLibraryWithSource` | 首次调用多付 60~120 ms（本机实测 warmup 68.4 ms） |
| 卷积数值路径 | double FFT → float 频谱 → GPU MAC | **相同** | 卷积误差可互相印证 |
| 升频数值路径 | **double**（`gpu_resample_hip.cpp:21-30`） | **float**（`gpu_metal.mm:200-220`，Apple GPU 无 double） | **升频误差差 10 个数量级**；上游 ≤1e-12 口径不可用 |
| 显存 | 独显，显式 H2D/D2H，每次 `hipMalloc/hipFree` | 统一内存 `MTLResourceStorageModeShared`，`Buf::ensure` 几何增长复用 | mac 固定开销本就小得多，但**仍然**在小块下输给 CPU |
| 生产块长 | 262144 样一次 | 4096 样分块（`kChunk`） | **性能结论完全相反** |
| 卷积流式语义 | 无状态整块（同样有拖尾问题） | 无状态整块 | 上游同样会在分块调用下丢拖尾，但他们的生产调用形态不同 |

---

## 11. 未做 / 未验证（如实挂账，铁律 4）

1. **CUDA 侧未实测**：本机无 NVIDIA 卡。上游 WIP-A 的 CUDA 数字是"同源推理"，本文件不复述。
2. **生产管线端到端耗时未测**：只测了算子级（单次 `convolve` / 单次 `resample`）。
   在完整 rplay 播放链路里 GPU 路径占多少 wall time，**未测**。
3. **升频未穷举所有 outRate**：只测了 352800 / 384000（整块）与同样两档（分块）。
   44.1k→88.2k / 192k 只在探索阶段量过（分块 0.018x / 0.12x），**未纳入工具输出**。
4. **多声道（>2）未测**：探针只用 2 声道。`GpuBridge` 是单例，多声道并行调用时的正确性未验证。
5. **超长 IR（>262144）未测**：只到 262144。理论上误差会继续增长，未标定。
6. **`gpu_metal.mm` 的 buffer 复用容量上限未测**：`Buf::ensure` 是几何增长，超长 IR 反复切换时
   会不会抖动，未测。
7. **§6 的 BUG 只做了离线复现，未做真机听感验证**，也未在完整 App 里端到端跑过 `irgpu=1` 路径。
8. **Windows/CI 侧未回归**：本任务只新增文件，未改任何既有源码；`CMakeLists.txt` 未改（见 §12）。
9. **探针各节的随机数已改为独立重播种**（`g_seed = 0x123456789ABCDEF`）。
   原因：初版各节共用一条 xorshift 流，改一个小节的规模就会让后面整张表的数字全变
   （本次真的踩到：门 2b 的 IR 从 64 改到 2048，精度矩阵跟着变了）。重播种后
   §4 矩阵 3 次重跑 md5 完全一致，且与其它小节的规模解耦。
10. **门禁覆盖不到 IR=65536/262144 的卷积精度**（CPU 参考是 O(N·M) 直接卷积，太慢）。
    这两档只有探针（`tools/gpu_precision`）覆盖，靠人读表。见 §7 的脚注 ¹。

---

## 12. 需要主控在 `CMakeLists.txt` 加的行

本任务按约束**未改 `CMakeLists.txt`**。需要加的确切文本（建议位置：紧随现有
`add_test(NAME gpu_metal ...)` 之后，即现 `CMakeLists.txt:661` 的下一行）：

```cmake
# ---------------- 2026-10-26：GPU 精度实测（F-6，mac / Metal 口径）----------------
# 探针：手动跑，不进 ctest（它要打印整张矩阵，且依赖本机 GPU；
#       无卡机器上会打印"GPU 不可用"并 exit 2，不适合当门禁）。
add_executable(gpu_precision tools/gpu_precision.cpp)
target_include_directories(gpu_precision PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(gpu_precision PRIVATE ${CMAKE_DL_LIBS})

# 门禁：把本机实测阈值固化（缺 dylib / GPU 不可用时打印 [SKIP] 并 return 0，不算失败）。
add_executable(test_gpu_precision tests/test_gpu_precision.cpp)
target_include_directories(test_gpu_precision PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_gpu_precision PRIVATE ${CMAKE_DL_LIBS})
add_test(NAME gpu_precision COMMAND test_gpu_precision)
```

> 注意：`gpu_precision`（探针）与 `test_gpu_precision`（门禁）是**两个不同目标**，别只注册一个。
> 门禁的 ctest 名字建议用 `gpu_precision`（与上游 `ab2901b` 的命名习惯一致）。
>
> 本机已验证这两个目标能独立构建：
> `clang++ -O2 -std=c++20 -I src tools/gpu_precision.cpp -o build-gpuprec/gpu_precision -ldl` ⟹ 0 error
> `clang++ -O2 -std=c++20 -I src tests/test_gpu_precision.cpp -o build-gpuprec/test_gpu_precision -ldl` ⟹ 0 error
> 两者跑通：探针 exit 0（154 行输出），门禁 9 PASS / 0 FAIL，耗时 0.59 s。

---

## 13. 复现命令

```bash
CM=/private/tmp/cmake-3.31.6-macos-universal/CMake.app/Contents/bin
cd /Users/august/Downloads/DQ/RLPlayer

# 独立目录，不碰 build-mac（主控独占）
mkdir -p build-gpuprec
clang++ -O2 -std=c++20 -I src tools/gpu_precision.cpp      -o build-gpuprec/gpu_precision      -ldl
clang++ -O2 -std=c++20 -I src tests/test_gpu_precision.cpp -o build-gpuprec/test_gpu_precision -ldl

./build-gpuprec/gpu_precision          # 154 行完整矩阵，约 8 s
./build-gpuprec/test_gpu_precision     # 9 PASS / 0 FAIL，约 0.6 s

# 语法门（任务书判据 7）
clang++ -std=c++20 -fsyntax-only -I src tools/gpu_precision.cpp
clang++ -std=c++20 -fsyntax-only -I src tests/test_gpu_precision.cpp
```

**判据变异自证**（证明门禁真有分辨力，不是"永远绿"）：
把 `test_gpu_precision.cpp` 里卷积阈值改成 −160 dB、升频改成上游口径 1e-12 ⟹ 立刻 6 条 FAIL、exit 1。
已实测。

---

## 14. 触碰文件清单

| 文件 | 操作 |
|---|---|
| `tools/gpu_precision.cpp` | **新建**（探针，约 870 行） |
| `tests/test_gpu_precision.cpp` | **新建**（门禁，9 条判据） |
| `docs/WIP-F6-GPU精度.md` | **新建**（本文档） |
| `build-gpuprec/` | 新建构建目录（**构建产物，不应提交**） |

**未改任何既有文件**：`CMakeLists.txt` / `src/gpu/gpu_metal.mm` / `src/dsp/gpu_bridge.h` /
`src/engine/pipeline.h` / `src/dsp/resampler.h` 全部零改动（按任务约束）。
