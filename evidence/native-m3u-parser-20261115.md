# v3.3.11 M3U 歌单解析（macOS/POSIX 适配，1.1.7.65）

> 待移植清单「M3U 播放列表导入」组的**第一部分：解析纯函数**。
> 放公共层 `RLPSupport`，队列页与判据共用同一真源，不复制第二份解析。

## 1. 上游真值（`/tmp/rlp2-v3311/ui_script.h:12668-12745`）

| 函数 | 语义 |
|---|---|
| `m3uWindowsPath(value, folder)` | **Windows 路径**专用：`file:` URL 解码、`/` → `\`、盘符/UNC 根校验、`..`/`.` 归一化、非法字符拒绝；无 folder 的相对路径返回 null |
| `parseTransportM3u(text, folder)` | 去 UTF-8 BOM → 按 CRLF/LF/CR 分行 trim → `#EXT-X-` 拒绝（HLS）→ `#RTA-CUE a b` 记录区间（`a>=0`、`b==-1 或 b>a`）→ 其余 `#` 注释忽略 → 路径行 + CUE → 返回 `{items, needsFolder}`；尾部孤立 CUE / 空歌单 / 控制字符一律拒绝 |
| `importTransportM3u(file)` | 扩展名 `.m3u/.m3u8`、≤16 MiB、`require_stopped=1&files=…` POST `/api/queue/set`、替换队列前确认 |

## 2. POSIX 适配（与上游的差异，必须说明）

上游 `m3uWindowsPath` 全程生成 `C:\…` / `\\host\share\…`，**在 macOS 上不可用**。
本包按同一套规则改为 POSIX：

| 规则 | 上游 (Windows) | 本包 (macOS) |
|---|---|---|
| 路径分隔 | `\` | `/` |
| 绝对根 | `C:\` 或 UNC | `/` |
| 相对路径 | 拼到 `folder\` 后 | `[folder stringByAppendingPathComponent:]` |
| `..` / `.` | 手工 components 栈 | `stringByStandardizingPath` |
| `file:` URL | `new URL()` 解码 + 盘符处理 | `NSURL.path` |
| 非法字符 | 控制字符、`<>:"|?*` | 控制字符（`<>:"|?*` 在 POSIX 合法，不拒） |
| 无 folder 的相对路径 | `needsFolder=true`，UI 追问文件夹 | 同语义：`needsFolder=YES`，item 保留原样 |

CUE / BOM / 注释 / HLS 拒绝 / 孤立 CUE / 空歌单 / 控制字符规则**逐条照搬**。

## 3. 实现

`tools/native_ui/RLPSupport.h` 声明、`RLPSupport.mm` 实现：

```objc
NSDictionary<NSString*,id> *RLPParseM3U(NSString *text, NSString *folder);
// → @{@"items": @[路径(\tcs\tce)…], @"needsFolder": @(BOOL)}，非法返回 nil
```

纯函数：不读文件、不弹面板、不发请求。

## 4. 红 → 绿（`test_native_queue_sort.mm` 新增 U1–U10）

| 判据 | 占位实现 | 真实现 |
|---|---|---|
| U1 BOM/CRLF/注释解析出 2 首 | FAIL | PASS |
| U2 绝对路径原样 | FAIL | PASS |
| U3 相对路径按文件夹拼接 `/List/sub/B.flac` | FAIL | PASS |
| U4 有文件夹时 needsFolder=NO | FAIL | PASS |
| U5 无文件夹的相对路径 needsFolder=YES | **PASS（巧合）** | PASS |
| U6 `#RTA-CUE 10 20` 附加 `\t10\t20` | FAIL | PASS |
| U7 HLS `#EXT-X-` 拒绝 | FAIL | PASS |
| U8 孤立 CUE 拒绝 | FAIL | PASS |
| U9 空歌单拒绝 | FAIL | PASS |
| U10 控制字符 `\u0001` 拒绝 | FAIL | PASS |

| 轮次 | 结果 | 证据 |
|---|---|---|
| 占位（红） | build 0 error；**9 FAIL + U5 碰巧 PASS** | `evidence/native-m3u-parser-red-20261115.log` |
| 真实现（1.1.7.65） | build 0 error；3 项相关 ctest 全绿 | `evidence/native-m3u-parser-green-20261115.log` |

**如实说明**：U5 在红阶段没红 —— 占位实现恰好返回 `needsFolder=YES`，而 U5 只断言这个键；
它对占位不敏感，但能区分「有 folder」与「无 folder」两种输入，绿阶段由真实现验证。
另：首次判据用了 `\x01bad`，ObjC 把 `bad` 也吃进 hex 转义导致编译失败（假绿），已改 `\u0001` 后重跑。

## 5. 如实挂账（本组未做完）

1. **未做** 队列页 `qImportM3u` 按钮 + `qM3uFile` 文件选择 + `importM3UAtPath:` 接缝 +
   `/api/queue/set` 下发（下一包）。
2. **未做** 16 MiB 大小闸门、`require_stopped=1`、替换队列前的 `NSAlert` 确认。
3. **未做** 相对路径无 folder 时的「请输入歌单所在文件夹」对话框（macOS 上 M3U 相对路径
   通常直接基于文件所在目录，下一包会用文件目录作为 folder，不需要追问；`needsFolder`
   标记保留以便将来需要）。
4. 未新增 i18n 词条（本包无 UI 文案）。
