// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
#include "meta/store.h"
#include <filesystem>
#include <cstdio>
#include <unistd.h>
int main(){
 using namespace rta::meta; namespace fs=std::filesystem;
 auto root=fs::temp_directory_path()/("rlp-lyric-cache-"+std::to_string(getpid()));
 auto& ms=MetaStore::instance();ms.setBaseDir(root.string());
 TrackMeta tm;tm.path="synthetic.wav";
 tm.fields["title"]={"Song A","tag",0,1};tm.fields["artist"]={"Artist A","tag",0,1};
 tm.fields["lyrics"]={"Synthetic wrong words","netease",0,1};ms.save(tm);
 TrackMeta got;bool ok=ms.load(tm.path,got,true) && !got.fields.count("lyrics") && got.fields.count("lyrics_refresh");
 printf("%s old network cache is not served as verified lyrics\n",ok?"PASS":"FAIL");
 ms.save(got);TrackMeta original;
 const bool kept=ms.load(tm.path,original)&&original.fields["lyrics_unverified"].value=="Synthetic wrong words";
 printf("%s failed refresh save preserves quarantined original bytes\n",kept?"PASS":"FAIL");ok=ok&&kept;
 got.fields["lyrics_refresh_try"]={"attempt","internal",1000,1};
 const bool cooldown=!lyric_refresh_due(got,1001)&&lyric_refresh_due(got,1000+86400);
 printf("%s failed refresh has a bounded retry cooldown\n",cooldown?"PASS":"FAIL");ok=ok&&cooldown;
 tm.fields["lyrics"].source="user";ms.save(tm);
 const bool user=ms.load(tm.path,got,true)&&got.fields["lyrics"].value=="Synthetic wrong words";
 printf("%s user-authored lyrics preserved\n",user?"PASS":"FAIL");
 tm.fields["lyrics"].source="netease";
 tm.fields["lyrics_identity"]={lyric_cache_identity(tm),"internal",0,1};ms.save(tm);
 const bool verified=ms.load(tm.path,got,true)&&got.fields.count("lyrics")&&!got.fields.count("lyrics_refresh");
 printf("%s verified matching cache remains usable\n",verified?"PASS":"FAIL");
 fs::remove_all(root);return ok&&user&&verified?0:1;
}
