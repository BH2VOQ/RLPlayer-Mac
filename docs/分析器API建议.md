# 音频体检分析器 API 建议（B1a 算法层 + B1b 编排层 → 主线接线契约）

日期：2026-10-26（工作区 `D:\RTA-health`，分支 `audio-health`）
读者：主线（rtaweb / UI）接线者。本文是接口承诺 + 实测量级 + 接线建议；实现见
`src/analysis/track_health.h`、`src/analysis/health_store.h`，算法见 `src/analysis/dynamics.h`、
`src/analysis/fake_lossless.h`（B1a），实测证据见 `docs/WIP-B1b.md`。

---

## 1. 函数签名一览

### B1a 纯算法层（不解码、不开设备）

```cpp
// src/analysis/dynamics.h
struct DynamicsResult { double drDb, lufsIntegrated, lra, peakDbfs; bool valid; };
DynamicsResult measure_dynamics(const double* const* ch, int channels, size_t n, double fs);
//   TT DR（3s 块前 20% 合并样本 RMS₂）+ BS.1770-4 LUFS + EBU R128 LRA + 样本峰值

// src/analysis/fake_lossless.h
struct LosslessCheck { bool suspected; double cutoffHz, confidence; std::string reason; bool fake24bit; };
LosslessCheck check_lossless(const double* const* ch, int channels, size_t n, double fs, int srcBits);
//   频谱截止 + 陡沿 + 窗间一致率 → suspected（confidence <0.5 强制不判假）；
//   srcBits ≥24 时另做 LSB 检查（16-bit 内容装 24-bit 容器 → fake24bit）
```

### B1b 编排层（本包新增）

```cpp
// src/analysis/track_health.h
struct TrackHealth {
    double drDb, lufs, lra, peakDbfs;                 // 动态（dynamics.h 透传）
    bool losslessSuspected; double cutoffHz, confidence;
    std::string reason; bool fake24bit;               // 假无损（fake_lossless.h 透传，reason 为中文人话）
    double durationSec; uint32_t fs; int channels, bits;
    std::string status;                               // "ready" / "error"
    std::string error;                                // status=error 时的人话原因
    int64_t analyzedAtMs;                             // 分析完成时刻（Unix 毫秒）
};
TrackHealth analyze_buffer(const rta::audio::AudioBuffer& buf);  // 解码无关，不抛异常
TrackHealth analyze_file(const std::string& path);               // read_any 解码，绝不抛异常
std::string track_health_json(const TrackHealth& h);             // 单个 JSON 对象文本

// src/analysis/health_store.h
class HealthStore {
public:
    explicit HealthStore(const std::string& jsonPath);   // 不存在 → 空库；损坏 → loadError() 非空且拒绝 save()
    bool lookup(const std::string& path, int64_t mtime, int64_t size, TrackHealth& out) const;
    void upsert(const std::string& path, int64_t mtime, int64_t size, const TrackHealth& h);
    bool save();                                         // 原子写（tmp+rename）；损坏库拒绝写盘
    size_t size() const;
    const std::string& loadError() const;
};
std::string normalize_path_key(const std::string& path); // fs::weakly_canonical 的 generic 串
```

### JSON 契约（字段名一字不差，主线按此解析）

`track_health_json` 输出（真实 CLI 实录，单行）：

```json
{"dr_db":3.010,"lufs":-44.074,"lra":0.000,"peak_dbfs":-44.074,
 "lossless_suspected":false,"cutoff_hz":0.0,"confidence":0.000,
 "reason":"未检出明显频谱截止","fake24":false,
 "duration_sec":6.000,"fs":48000,"channels":2,"bits":16,
 "status":"ready","error":"","analyzed_at_ms":1792944339447}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `dr_db` | number | TT DR（dB）；素材 <3 s 时口径不成立，恒 0 |
| `lufs` / `lra` / `peak_dbfs` | number | BS.1770-4 积分响度 / LRA（LU）/ 样本峰值（dBFS） |
| `lossless_suspected` | bool | 疑似有损源转制（**语义见 §4.3，有损容器上含义不同**） |
| `cutoff_hz` | number | 检出频谱截止（0=未见） |
| `confidence` | number | 0..1；<0.5 时 suspected 必为 false |
| `reason` | string | 中文原因，UI tooltip 可直显 |
| `fake24` | bool | 24-bit 容器实为 16-bit 内容（低 8 位恒零） |
| `duration_sec` / `fs` / `channels` / `bits` | number | 元信息（bits 为解码后位深：有损源解出 32） |
| `status` | string | `ready` / `error` |
| `error` | string | 失败人话原因（ready 时为空串） |
| `analyzed_at_ms` | number | 分析完成时刻（Unix 毫秒）；**>0 = 已有体检结果，=0 = 尚未分析（pending 占位）** |

## 2. 实测量级（本机 2026-10-26 实测，合成 10 s @48k 立体声 16-bit）

| 阶段 | 耗时 | 说明 |
|---|---|---|
| decode（read_wav，磁盘→AudioBuffer） | **1.2 ms** | 无损 WAV 原生解析 |
| dynamics（measure_dynamics） | **15.0 ms** | K 加权全轨滤波 + 分块门限 |
| lossless（check_lossless） | **12.1 ms** | ≤12×65536 点 FFT |
| 合计（两段纯算法） | **27.1 ms** | analyze_buffer 全程实测 28 ms（含平面转换） |
| analyze_file（decode+全部） | **29.5 ms** | WAV 端到端 |

真实文件（ffmpeg 参与解码，5 个实例，详见 WIP-B1b §4）：**193~2011 ms/文件，平均 792 ms**；
FLAC 需经 ffmpeg 转码，解码占大头（蔡琴 47 MB FLAC 共 2011 ms）。

**接线结论**：单文件分析 <30 ms（WAV）~2 s（FLAC/DSD），适合后台 job，不适合 HTTP 同步现算；
缓存命中后 lookup 是内存 map 查询（<0.1 ms），可同步秒回。

## 3. HTTP 契约建议

### 3.1 单曲查询：`GET /api/health?path=<utf8 路径>`

- 主线取文件 `(mtime 毫秒, size)` 查 `HealthStore::lookup`：
  - **命中** → 同步返回 `200`：track_health_json 全部字段 + `"path"`；`analyzed_at_ms>0`。
  - **未命中** → 不阻塞现算。立即回 `200 {"pending":true,"path":...,"analyzed_at_ms":0,...}`（材质字段照
    knowledge 的 `knowledge_pending_json` 先给全、先空着），同时入队后台 job（§3.2）。前端按
    `analyzed_at_ms` 区分「有结果」与「pending」。
- `status:"error"` 也是合法结果（如解码失败），照常返回 —— error 有独立字段，不要用 HTTP 状态码表达
  「文件体检失败」。

### 3.2 播放自动检测 + 批量扫描：`POST /api/health/scan  {"paths":[...]}` → `{"jobId":"...","queued":N}`

- **复用 knowledge 异步 job 模式**（`tools/rtaweb.cpp` 的 `g_know_jobs`：内存 job 表 + mutex + 后台
  `std::thread` + 前端轮询 + 完成后 600 s 清扫）。health 侧建议照搬：
  - job 键 = `normalize_path_key(path) + "@" + mtime + ":" + size` —— **同键已在队/在跑则不重复入队**
    （防重复扫描同一文件）；
  - 后台分析线程**串行单队列**（分析是 CPU 密集，0.2~2 s/文件，串行足够；并行会与播放抢核，
    得不偿失）；
  - `HealthStore::upsert` 只在 `status=="ready"` 时写入（错误结果不入缓存，避免把「瞬时读不了」
    钉死进库；文件真变了 mtime/size 键会失效自然重算）。
- **播放时自动检测挂钩点**：播放成功起播后，把当前曲目 path 交给 §3.1 的查询（未命中即自动入队）。
  用户无感知，播过一遍的曲目下次秒出。

### 3.3 批量进度：`GET /api/health/progress`

```json
{"running":true,"total":128,"done":37,"errors":2,"current":"D:/music/a.flac","jobId":"..."}
```

建议另给 `POST /api/health/scan/cancel` 置取消位；目录级扫描入口（用户选文件夹）在 UI 侧展开成
paths 数组后走同一 `POST /api/health/scan`，不必新开端点。

### 3.4 缓存文件挂载

- `HealthStore(jsonPath)` 的 jsonPath 由主线决定（建议与 MetaStore 同级的用户数据目录）；
- 加载报错（`loadError()` 非空）时**必须向用户提示**且不要删文件（实现已保证此时 `save()` 拒写，
  不会静默清空用户缓存），人工修复/删除后恢复；
- 写盘时机建议：扫描队列清空后或退出前调一次 `save()`（不必每曲目落盘）。

## 4. UI 字段建议（管理员要求：播放自动检测 + 曲目列表一栏反馈，注意美观）

### 4.1 曲目列表「健康」列

- **徽标枚举**：`none`（无异常，默认不画，降噪）/ `pending`（小转圈或空心点）/ `ok`（淡绿点，
  可选）/ `suspect`（黄点 = `fake24`，红点 = `lossless_suspected`；同列可双色环）。
- 判定：`status=="error"` → 灰点，tooltip=error 原文；pending → 空心点；`suspect → 黄/红`；
  其余 `none`。徽标**只画点/小图标，不占文字宽度**。
- **tooltip = `reason` 原文**（分析器已生成中文人话，如「16.2 kHz 处存在陡峭截止（下降 62 dB），
  典型的有损源转制特征」）；fake24 时追加「24-bit 容器实为 16-bit 内容」。
- 列宽建议 **56~72 px**（仅容纳图标 + 可选置信度小字）；表头「健康」。
- **排序键**：`dr_db` 降序（高动态优先）/升序（快速找动态最差）可切换；`cutoff_hz>0` 作假无损
  排序的次级键。suspect 条目建议在排序里永远置顶一档（用户开体检就是想先看这些）。

### 4.2 单曲页 / 详情卡片

完整字段卡片，分区两块：

- **动态**：`DR xx.x dB`、`LUFS xx.x`、`LRA xx.x LU`、`Peak xx.x dBFS`（四个大数字；
  DR≥14 可加「高动态」绿标，≤6 可加「响度战争」黄标——阈值供参考，勿当硬判据）；
- **假无损详情**：`cutoff_hz`（"20.1 kHz 截止"）、`confidence`（"置信度 0.50"）、`reason` 原文、
  `fake24`（"24-bit 容器实为 16-bit 内容"）。
- 元信息行：`fs / channels / bits / duration_sec`（bits 为解码位深，有损源显示 32 属正常，可在
  UI 侧用自家 codec 信息纠正显示）。

### 4.3 「假无损」徽标文案（防误报骚扰）

- `confidence <0.5` 分析器已强制不判假（suspected=false），UI **无需二次过滤**；但显示徽标时
  建议把 confidence 一并展示（如 "疑似(0.75)"）。
- ⚠️ **有损容器的语义区分（实测发现的坑）**：MP3/AAC 等**真有损**文件解码后同样会
  `lossless_suspected=true`（实测 2 例：cutoff 13.1k/15.5k、置信度 0.75/1.00）——它标的是
  「**有损音源**」（事实正确），但不是「假无损」（该词只对无损容器成立）。主线应结合自家
  codec 元数据区分文案：**无损容器 → 「疑似假无损」；有损容器 → 「有损源」或直接不显示徽标**。
  （B1b 的 TrackHealth 不带 codec 字段，属有意保持接口最小——主线已有的媒体信息比体检侧全。）

## 5. 已知局限（接线前必读，详见 docs/WIP-B1a.md §6 / WIP-B1b.md §7）

1. **多声道 LUFS 权重**只实现立体声 L/R=1.0；≥3 声道按 G=1.0，积分响度偏低 ≤1.5 dB。
2. **48k 外采样率** LUFS 精度 ±0.003 LU（44.1/96/192k 实测）；假无损检测仅 44.1k 实测过。
3. **真实文件检出率/误报率未标定**：本机 5 个真实样本（WIP-B1b §4）只有方向性参考，其中
   蔡琴个案置信度恰为 0.50（门限边界），未做人工频谱核对。
4. **纯音/超窄带素材会误报假无损**（B1a 边界，B1b bench 复现：纯 double 正弦被报
   「1.2 kHz 陡峭截止」）；16-bit 量化噪声可自然压住，实测音乐无此现象。测试音/正弦文件
   不要当体检结论看。
5. **大 DSD 整曲解码进内存**：analyze_file 对 DSD 走 read_any 整曲原生解码（271 MB DSD64 实测
   峰值 ~1.8 GB），体检后台 job 对大 DSD 要有内存预期或暂缓（播放侧已有流式路径，体检侧未接）。
6. 缓存 JSON 的 number 走 double：mtime 已按**毫秒**存（100ns 原生 count 会超 2^53 失真），
   主线自行取键时也请用毫秒。
