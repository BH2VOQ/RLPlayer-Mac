# RLPlayer 官网内容包 · rlplayer-site-1.1.4

纯静态站点，**无需构建、无需 Node、无远程运行时依赖**。把 `rlplayer-site-1.1.4/` 目录里的文件原样上传到 Web 根目录即可。

## 上传内容（11 个文件，缺一不可）

```
index.html             # 唯一入口
styles.css             # 基础样式
art-direction.css      # 视觉与动效层
app.js                 # 交互、版本读取、下载信息
motion.js              # 滚动动效
latest.json            # 版本/下载信息（运行时 fetch，见下）
assets/logo.png        # 站点 logo + favicon + apple-touch-icon
assets/ui-hero.webp    # 实机截图（首屏）
assets/ui-dsp.webp     # 实机截图（DSP）
assets/ui-library.webp # 实机截图（曲库）；同时是 og:image
assets/ui-works.webp   # 实机截图（功能）
```

站点内所有引用都是**相对路径**，放在域名根目录或任意子目录（如 `/rlplayer/`）都能正常工作，不需要改配置。

**不要上传**：`tools/`、`package.json`、`README.md`（开发期工具与文档，不属于站点）。

## 需要服务器配合的两点

1. **MIME 类型**：`assets/*.webp` 必须返回 `image/webp`，否则截图不显示。Nginx 若未识别：
   ```nginx
   types { image/webp webp; }
   ```
2. **`latest.json` 建议禁缓存**（页面用 `cache: 'no-store'` 请求，中间代理仍可能缓存）：
   ```
   location = /latest.json { add_header Cache-Control "no-cache, must-revalidate"; }
   ```
   `index.html` 同理建议 `no-cache`；CSS/JS 文件名无内容指纹，建议统一 `Cache-Control: public, max-age=3600`。

页面运行时会额外并行尝试 `raw.githubusercontent.com` 与 `cdn.jsdelivr.net` 上的同名 `latest.json`，取版本号最高的一份。
两个源失败（离线、被拦、跨域）会静默忽略，页面回落到 HTML 内置值 + 同目录 `latest.json`，**不依赖外网也能正常显示**。

## 本版同步了什么（1.1.3.2 → 1.1.4）

| 项 | 值 |
|---|---|
| 版本 | v1.1.3.2 → **v1.1.4** |
| 发布日期 | 2026-11-05 → **2026-11-08** |
| 文件大小 | 8.0 MB / 8,012,447 字节 → **8.1 MB / 8,073,906 字节** |
| SHA-256 | `3f04a956…` → `34b9305b…` |
| 下载直链 | `releases/download/v1.1.4/RLPlayer-1.1.4-macOS-arm64.dmg` |

同时修正了路线图区与发布状态不一致的地方：
- 「已发布」里程碑区间 `v1.1.0 – v1.1.3.2` → `v1.1.0 – v1.1.4`，并把单曲页三级实时分析与 dBTP 真峰值并入已发布描述；
- 「近期迭代」区间起点从 `v1.1.4` 后移到 `v1.1.5`（横幅 + 里程碑两处），未来区间描述去掉已随 1.1.4 交付的条目；
- Track Lab（单曲页三级实时分析）卡片状态标签由「近期迭代 · v1.1.4」改为「已发布 · v1.1.4」（描述正文未改）。

## 已验证（本机实测）

- 站点自带静态检查 `npm run check`：14 项 PASS，**0 FAIL、0 警告**（此前那条 `latest.json` 与仓库不一致的警告已随同步消失）。
- 包内 11 个文件与站点源目录 **SHA-256 逐一相同**；zip 解压后与目录 **diff -r 完全一致**。
- 从内容包目录起 `python3 -m http.server` 实跑：12 条 URL（含 `/`）全部 **200**，Content-Type 正确。
- `index.html` 内置值（版本/日期/大小/SHA/直链）与 `latest.json` 完全一致，因此页面加载后 **不会发生版本号跳变**。

## 目录说明

- `rlplayer-site-1.1.4/` + `rlplayer-site-1.1.4.zip` —— **上传这一个**（内容同上，zip 里带同名顶层目录）。
- `_superseded-1.1.3.2/` —— 同步前打出的旧包，**不要部署**，仅留档对比。
- `MANIFEST.txt` —— 逐文件 SHA-256 与字节数，可用 `shasum -a 256 -c` 风格手工核对。
