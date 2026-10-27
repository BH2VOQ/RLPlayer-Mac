// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
'use strict';
const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');

const base = (process.argv[2] || 'http://127.0.0.1:19207').replace(/\/$/, '');
const out = process.argv[3] || 'debug/i7-final/b7-updbeta';
fs.mkdirSync(out, { recursive: true });

const lines = [];
let failures = 0;

function check(ok, label, detail) {
  const line = `${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(detail)}`;
  lines.push(line);
  console.log(line);
  if (!ok) failures++;
}

async function api(p, body) {
  const r = await fetch(base + p, body === undefined ? {} : {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  return r.json();
}

(async () => {
  let s;
  try {
    const settings = await api('/api/settings');
    if (!settings.kv || settings.kv.backend !== 'null') {
      throw new Error('test requires backend=null');
    }

    s = await ub.open({ url: base, width: 1400, height: 900 });
    if (!await s.waitFor('window.S && typeof openSettingsTab === "function"', 15000)) {
      throw new Error('page not ready');
    }

    // 切换到「诊断」页（软件更新卡片所在位置）
    await s.eval(`openSettingsTab('diag')`);
    await ub.sleep(300);

    // 1. 勾选框是否存在
    const exists = await s.eval(`!!D('sp_updbeta')`);
    check(exists, 'checkbox sp_updbeta exists', { exists });
    if (!exists) {
      throw new Error('sp_updbeta checkbox does not exist');
    }

    // 2. 默认不勾 (初始未配置状态)
    const initChecked = await s.eval(`D('sp_updbeta').checked`);
    check(initChecked === false, 'checkbox default unchecked', { initChecked });

    // 截屏初始状态
    await s.shot(path.join(out, '01_initial_unchecked.png'));

    // 3. 真实点击勾选 -> 触发 change 事件 -> 自动持久化保存
    // 真实点击元素
    await s.eval(`D('sp_updbeta').click()`);
    await ub.sleep(300);
    const checkedAfterClick = await s.eval(`D('sp_updbeta').checked`);
    check(checkedAfterClick === true, 'checkbox checked after click', { checkedAfterClick });

    // 等待 /api/settings 保存
    await ub.sleep(500);

    // 验证后端 settings kv
    let s1 = await api('/api/settings');
    check(s1.kv && s1.kv.updbeta === '1', 'api /api/settings reflects updbeta=1', s1.kv && s1.kv.updbeta);

    await s.shot(path.join(out, '02_checked_persisted.png'));

    // 刷新页面
    await s.send('Page.reload');
    if (!await s.waitFor('window.S && typeof openSettingsTab === "function"', 15000)) {
      throw new Error('page not ready after reload 1');
    }
    await s.eval(`openSettingsTab('diag')`);
    await ub.sleep(400);

    const checkedAfterReload1 = await s.eval(`!!(D('sp_updbeta') && D('sp_updbeta').checked)`);
    check(checkedAfterReload1 === true, 'checkbox remains checked after reload', { checkedAfterReload1 });
    await s.shot(path.join(out, '03_after_reload1.png'));

    // 4. 再次真实点击 -> 取消勾选
    await s.eval(`D('sp_updbeta').click()`);
    await ub.sleep(300);
    const checkedAfterSecondClick = await s.eval(`D('sp_updbeta').checked`);
    check(checkedAfterSecondClick === false, 'checkbox unchecked after click 2', { checkedAfterSecondClick });

    await ub.sleep(500);

    let s2 = await api('/api/settings');
    check(s2.kv && s2.kv.updbeta === '0', 'api /api/settings reflects updbeta=0', s2.kv && s2.kv.updbeta);

    await s.shot(path.join(out, '04_unchecked_persisted.png'));

    // 再次刷新
    await s.send('Page.reload');
    if (!await s.waitFor('window.S && typeof openSettingsTab === "function"', 15000)) {
      throw new Error('page not ready after reload 2');
    }
    await s.eval(`openSettingsTab('diag')`);
    await ub.sleep(400);

    const checkedAfterReload2 = await s.eval(`!!(D('sp_updbeta') && D('sp_updbeta').checked)`);
    check(checkedAfterReload2 === false, 'checkbox remains unchecked after reload', { checkedAfterReload2 });
    await s.shot(path.join(out, '05_after_reload2.png'));

  } catch (e) {
    check(false, 'execution error', String(e.stack || e));
  } finally {
    if (s) {
      try { await s.close(); } catch (e) { check(false, 'browser cleanup', String(e)); }
    }
    fs.writeFileSync(path.join(out, 'ui_result.txt'), lines.join('\n') + '\n');
  }
  process.exitCode = failures ? 1 : 0;
})();
