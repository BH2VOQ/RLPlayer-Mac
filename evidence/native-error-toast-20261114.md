# 后端错误态：不写副标题、改 toast（1.1.7.50，表 #63）

## web 真相
web 整页（`renderNp()`）**不展示后端 error 字段**；错误只通过播放失败的 toast/提示通道出现。
原生 1.1.7.49 却把 `status.error` 直接写进 `#npSub` 副标题位
（`if(st.error.length) artistLabel2.stringValue=st.error`）——一旦后端返回错误，
副标题就从「艺术家 / 专辑」变成「后端错误：解码失败」，用户看到的是**假信息**（把艺术家挤掉）。

## 判据（`tests/test_native_nowplaying_web.mm` 追加 4 条，放在真实 NSWindow 里跑）
1. 错误发生后 `artistLabel2` **不再等于错误串**（web 整页不展示后端 error）；
2. 出现 `identifier=rlp.toast` 的轻提示（可见反馈不丢）；
3. toast 文案 = 后端错误原文；
4. 真跑一轮 runloop（2.6s），toast **自动消失**（1.8s 后淡出并移除，不常驻挡播放页）。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.49） | **2 FAIL**（副标题被写成错误串；没有 toast） |
| 新码 | **144 passed / 0 failures**（140 既有 + 4 新） |

证据：`evidence/native-toast-{red,green}-20261114.log`。

## 实现
- `refresh` 的 status 分支：错误字符串**不再**写 `artistLabel2`；改 `RLPToast(st.error)`；
  新增 `lastStatusError` 去重（同一错误轮询多次只弹一次，错误消失即清空）。
- `RLPToast` 容器加 `identifier=@"rlp.toast"`（判据/审计按 identifier 找，不靠文案匹配，避免本地化脆断）。

## 如实挂账
1. web 没有 toast 组件（web 的失败提示走另一套通道）；原生用既有 `RLPToast`（1.8s 自动消失），
   文案直接用后端错误原文，属「可见反馈的超集」，不假装是 web 逐像素。
2. 同一错误串去重；不同错误会重新弹（连续变化的错误串可能连弹，暂无合并窗口）。
3. 副标题在没有 metadata 时保持空/艺术家；错误不再占用该位置。
