// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// httptest.cpp — HTTP 客户端自检：拉取 URL 并报告大小/状态码
#include "platform/console.h"
#include "platform/time.h"
#include "net/http_client.h"
#include <cstdio>
#include <string>

using namespace rta::net;

static unsigned long long fnv1a(const std::vector<unsigned char>& b) {
    unsigned long long h = 1469598103934665603ULL;
    for (unsigned char c : b) { h ^= c; h *= 1099511628211ULL; }
    return h;
}

int main(int argc, char** argv) {
    rta::platform::enable_utf8_console();
    setvbuf(stdout, nullptr, _IONBF, 0);
    if (argc < 2) { printf("用法: httptest <url> [附加头]\n"); return 2; }
    std::vector<std::string> hdrs;
    for (int i = 2; i < argc; ++i) hdrs.push_back(argv[i]);

    auto t0 = rta::platform::monotonic_ms();
    HttpResponse r = http_get(argv[1], hdrs);
    auto ms = rta::platform::monotonic_ms() - t0;

    printf("URL  : %s\n", argv[1]);
    printf("状态 : %d  (%s)\n", r.status, r.ok ? "OK" : r.error.c_str());
    printf("类型 : %s\n", r.contentType.c_str());
    printf("大小 : %zu 字节\n", r.body.size());
    printf("耗时 : %llu ms\n", (unsigned long long)ms);
    if (!r.body.empty()) printf("FNV1a: %016llx\n", fnv1a(r.body));
    return r.ok ? 0 : 1;
}
