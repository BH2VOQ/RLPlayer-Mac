// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
#include "diag/report.h"
#include "diag/event.h"
#include <cstdio>
int main(){
 using namespace rta::diag;int fail=0;
 struct Case{const char* stage;const char* code;const char* kv;const char* want;};
 Case cases[]={
 {"decode","decode.truncated_flac","\"format\":\"flac\",\"frames_declared\":200,\"frames_read\":100","decode.flac_truncated"},
 {"negotiate","negotiate.rate_unsupported","\"requested_rate\":96000,\"rate_supported\":false","negotiate.rate_unsupported"},
 {"io","io.underrun","\"underrun\":2","io.underrun"},
 {"meta","meta.timeout","\"timed_out\":true","meta.timeout"},
 {"llm","llm.not_configured","\"key_present\":false","llm.config_error"},
 {"upnp","upnp.no_renderer","\"devices\":0","cast.no_device"},
 {"init","","","run.unclean_exit"},
 {"room","room.cancelled","\"cancelled\":true","room.cancelled"}};
 for(size_t i=0;i<8;++i){
  BundleSpec spec;spec.case_id="RLP-synthetic-blind";spec.cs.simulated=true;spec.run.clean_exit=i!=6;
  // Deliberately wrong scenario label: result must come from event evidence, not fixture answer.
  spec.cs.scenario="wrong-label-do-not-trust";
  const auto& c=cases[i];std::string ev="{\"ts\":1,\"seq\":1,\"sid\":\"s\",\"rid\":\"r\",\"evt\":\"failure\",\"stage\":\""+std::string(c.stage)+"\",\"code\":\""+c.code+"\",\"kv\":{"+c.kv+"}}\n";
  std::vector<BundleEntry> items{make_entry("diag.json","{\"version\":\"synthetic\",\"os\":\"test\"}",EntryKind::Json,100),make_entry("events.jsonl",ev,EntryKind::Jsonl,80),make_entry("uievents.jsonl","",EntryKind::Jsonl,60)};
  auto bundle=assemble(spec,std::move(items),"synthetic report");
  const auto evidence=evidence_from_entries(bundle.entries,spec);const auto report=analyze(evidence);
  bool ok=report.verdict==Verdict::Known&&report.conclusion.id==c.want&&report.simulated;
  printf("%s blind %zu want=%s got=%s\n",ok?"PASS":"FAIL",i,c.want,report.conclusion.id.c_str());fail+=!ok;
 }
 // Negative evidence: a valid empty package must not infer a cause.
 BundleSpec spec;std::vector<BundleEntry> empty{make_entry("diag.json","{}",EntryKind::Json,100),make_entry("events.jsonl","",EntryKind::Jsonl,80),make_entry("uievents.jsonl","",EntryKind::Jsonl,60)};
 auto bundle=assemble(spec,std::move(empty),"unknown");auto report=analyze(evidence_from_entries(bundle.entries,spec));
 bool unknown=report.verdict==Verdict::Unknown;printf("%s insufficient evidence remains unknown\n",unknown?"PASS":"FAIL");fail+=!unknown;
 return fail?1:0;
}
