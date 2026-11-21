# RLPlayer 官网（website/）

纯静态站点：语义化 HTML + CSS + 原生 JS，无构建、无框架、无远程运行时依赖。

## 视觉与动效

- `art-direction.css`：瓷白光谱、冰川玻璃、3D 实机镜头、Bento 指针高光与 Native DSD 位流视觉。
- `motion.js`：滚动镜头、真实 SVG 路径粒子、数字跳表和弹簧阻尼倾斜；离屏暂停绘制，支持 `prefers-reduced-motion`。
- 页面以「实测优势 → 自研信号链 → 当前能力 → 研发愿景」为主线，当前能力与 Future Vision 使用不同标签。

## 本地预览

```bash
cd website
python3 -m http.server 8080
# 打开 http://localhost:8080/
```

也可直接双击 `index.html`。`file://` 下 `latest.json` 的运行时更新会失败，页面保留内置的准确版本值。

## 静态检查

```bash
node --check app.js
node --check motion.js
node tools/check-static.js
```

`tools/check-static.js` 检查：两个脚本的语法、CSS 括号、内部锚点、本地资源路径、重复 id、必需的文案指标、真实截图 `<img>` 数量与动效/无障碍钩子。也可直接运行 `npm run check`。

## 版本与下载

页面在运行时并行读取三份 `latest.json`，按语义版本号取**最高**的那份整体应用（版本号、DMG 直链、SHA-256、文件大小、发布日期一起更新）：

| 顺序 | 来源 | 作用 |
|---|---|---|
| 1 | `latest.json`（站点同目录） | 随站点部署，与安装包同源 |
| 2 | `raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/main/latest.json` | 未重新部署站点时也能跟上 GitHub |
| 3 | `cdn.jsdelivr.net/gh/BH2VOQ/RLPlayer-Mac@main/latest.json` | 国内访问更稳的镜像 |

任一来源失败（离线、`file://`、跨域被拦）都静默忽略，页面保留 HTML 里的内置准确值。

> `github.com/.../releases/latest/download/latest.json` **不能**直接用：该地址不带跨域头，浏览器读取会 `Failed to fetch`（已实测）。

发版后先同步本地副本，再部署：

```bash
cd website
npm run sync-latest   # 校验字段后把仓库根 latest.json 复制到 website/
```

## 截图

页面引用以下真实截图，需由主控现场生成后放入 `assets/`：

- `assets/ui-hero.webp`
- `assets/ui-dsp.webp`
- `assets/ui-library.webp`

文件缺失时，对应 `<figure>` 会整体隐藏（不生成替代图、不使用占位背景）。
`assets/logo.png` 复制自 `docs/images/logo.png`。
