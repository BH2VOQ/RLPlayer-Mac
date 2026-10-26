// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
(function () {
  var out = {};
  ['dark','light','blue'].forEach(function (t) {
    var e = document.querySelector('.sw[data-theme=' + t + ']');
    var cs = getComputedStyle(e);
    out[t] = { bg: cs.backgroundImage.slice(0, 60), border: cs.borderColor, ring: cs.boxShadow.slice(0, 40), attr: e.getAttribute('data-theme') };
  });
  out.page = document.documentElement.dataset.theme;
  return out;
})()