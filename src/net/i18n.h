// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// i18n.h —— 界面多语言引擎（head 预处理 + body 运行时翻译引擎）
#pragma once

#include <string>
#include <cstddef>
#include <cstdio>
#include "i18n_table.h"

namespace rta::net {

inline std::string rta_i18n_head_script() {
    // 语言优先级的唯一真相源是**配置文件**（rlplayer-settings.conf 的 lang）。
    // localStorage 只是同一台机器的快速缓存，只在配置里还没有取值时用来兜底。
    // 为什么改（2026-10-30 用户报的 BUG：升级客户端后语言被换掉）：WebKit 的 localStorage
    // 按 bundle/数据容器存在，版本更替时可能残留上一版的旧值；旧实现让它无条件覆盖服务端
    // 渲染的 data-lang，于是"用户设了英文，升级后变回中文"。
    return "<script>(function(){try{"
           "var d=document.documentElement;"
           "if(d&&d.dataset&&d.dataset.langSrc==='conf')return;"
           "var l=localStorage.getItem('rta-lang');"
           "if(l==='en'||l==='zh'){"
           "if(d.dataset.lang!==l){d.dataset.lang=l;d.lang=l;}"
           "}"
           "}catch(e){}})();</script>";
}

inline std::string rta_i18n_escape_json(const char* s) {
    if (!s) return "\"\"";
    std::string out;
    out.reserve(64);
    out.push_back('"');
    for (const char* p = s; *p; ++p) {
        unsigned char c = (unsigned char)*p;
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out.push_back((char)c);
                }
                break;
        }
    }
    out.push_back('"');
    return out;
}

inline std::string rta_i18n_body_script() {
    std::size_t count = 0;
    const I18nPair* pairs = i18n_table(&count);

    std::string s;
    s.reserve(4096 + count * 64);
    s += "<script>(function(){\n";
    s += "try{\n";
    s += "if(!document.documentElement||document.documentElement.dataset.lang!=='en')return;\n";
    s += "var RAW=[";
    for (std::size_t i = 0; i < count; ++i) {
        if (i > 0) s += ",";
        s += "[";
        s += rta_i18n_escape_json(pairs[i].zh);
        s += ",";
        s += rta_i18n_escape_json(pairs[i].en);
        s += "]";
    }
    s += "];\n";
    s += "var CJK=/[\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff]/;\n";
    s += "var exactMap=new Map();\n";
    s += "var charMap=new Map();\n";
    s += "for(var k=0;k<RAW.length;k++){\n";
    s += "  var zh=RAW[k][0],en=RAW[k][1];\n";
    s += "  if(!zh)continue;\n";
    s += "  exactMap.set(zh,en);\n";
    s += "  var ch=zh[0];\n";
    s += "  if(!charMap.has(ch))charMap.set(ch,[]);\n";
    s += "  charMap.get(ch).push([zh,en]);\n";
    s += "}\n";
    s += "charMap.forEach(function(list){\n";
    s += "  list.sort(function(a,b){return b[0].length-a[0].length;});\n";
    s += "});\n";
    s += "var RULES=[\n";
    s += "  [/(\\d+)\\s*(?:首|Tracks)/gi,'$1 tracks'],\n";
    s += "  [/(\\d+)\\s*(?:张专辑|张\\s*Albums|张\\s*albums)/g,'$1 albums'],\n";
    s += "  [/(\\d+)\\s*(?:位艺术家|位\\s*Artists|位\\s*artists)/g,'$1 artists'],\n";
    s += "  [/(\\d+)\\s*小时/g,'$1 hr'],\n";
    s += "  [/(\\d+)\\s*分钟/g,'$1 min'],\n";
    s += "  [/(\\d+)\\s*秒/g,'$1 s'],\n";
    s += "  [/自动（设备最高\\s*(\\d+)）/g,'Auto (device max $1)'],\n";
    s += "  [/（设备不支持）/g,' (unsupported by device)']\n";
    s += "];\n";
    s += "function translate(str){\n";
    s += "  if(!str||typeof str!=='string'||!CJK.test(str))return str;\n";
    s += "  if(exactMap.has(str))return exactMap.get(str);\n";
    s += "  for(var r0=0;r0<RULES.length;r0++){str=str.replace(RULES[r0][0],RULES[r0][1]);}\n";
    s += "  if(!CJK.test(str))return str;\n";
    s += "  var trimmed=str.trim();\n";
    s += "  if(trimmed&&exactMap.has(trimmed)){\n";
    s += "    var enVal=exactMap.get(trimmed);\n";
    s += "    var idx=str.indexOf(trimmed);\n";
    s += "    return str.slice(0,idx)+enVal+str.slice(idx+trimmed.length);\n";
    s += "  }\n";
    s += "  var res='',i=0;\n";
    s += "  while(i<str.length){\n";
    s += "    var c=str[i],list=charMap.get(c),matched=false;\n";
    s += "    if(list){\n";
    s += "      for(var j=0;j<list.length;j++){\n";
    s += "        var zhWord=list[j][0];\n";
    s += "        if(str.startsWith(zhWord,i)){\n";
    s += "          res+=list[j][1];\n";
    s += "          i+=zhWord.length;\n";
    s += "          matched=true;\n";
    s += "          break;\n";
    s += "        }\n";
    s += "      }\n";
    s += "    }\n";
    s += "    if(!matched){res+=c;i++;}\n";
    s += "  }\n";
    s += "  str=res;\n";
    s += "  for(var r=0;r<RULES.length;r++){\n";
    s += "    str=str.replace(RULES[r][0],RULES[r][1]);\n";
    s += "  }\n";
    s += "  return str;\n";
    s += "}\n";
    s += "var processedNodes=(typeof WeakSet==='function')?new WeakSet():null;\n";
    // data-tip 是设置页「?」气泡的正文（tip() 生成 <span class=tip data-tip=…>）；
    // 漏了它就会出现「界面英文、悬浮说明中文」的半截效果（2026-10-29 实测）。
    s += "var ATTRS=['title','placeholder','aria-label','alt','data-tip'];\n";
    s += "function translateTextNode(node){\n";
    s += "  if(!node||!node.nodeValue)return;\n";
    s += "  if(processedNodes&&processedNodes.has(node))return;\n";
    s += "  var p=node.parentElement;\n";
    s += "  if(!p)return;\n";
    s += "  var tag=(p.tagName||'').toLowerCase();\n";
    s += "  if(tag==='script'||tag==='style'||tag==='textarea'||tag==='code'||tag==='pre')return;\n";
    s += "  if(p.closest&&p.closest('script,style,textarea,code,pre,#sp_lang'))return;\n";
    s += "  var val=node.nodeValue;\n";
    s += "  if(!CJK.test(val))return;\n";
    s += "  var trans=translate(val);\n";
    s += "  if(trans!==val)node.nodeValue=trans;\n";
    s += "  if(processedNodes)processedNodes.add(node);\n";
    s += "}\n";
    s += "function translateElementAttrs(el){\n";
    s += "  if(!el||!el.getAttribute)return;\n";
    s += "  var tag=(el.tagName||'').toLowerCase();\n";
    s += "  if(tag==='script'||tag==='style'||tag==='code'||tag==='pre')return;\n";
    s += "  if(el.closest&&el.closest('script,style,code,pre,#sp_lang'))return;\n";
    s += "  for(var a=0;a<ATTRS.length;a++){\n";
    s += "    var attr=ATTRS[a];\n";
    s += "    var val=el.getAttribute(attr);\n";
    s += "    if(val&&CJK.test(val)){\n";
    s += "      var trans=translate(val);\n";
    s += "      if(trans!==val)el.setAttribute(attr,trans);\n";
    s += "    }\n";
    s += "  }\n";
    s += "}\n";
    s += "function processSubtree(root){\n";
    s += "  if(!root)return;\n";
    s += "  if(root.nodeType===Node.TEXT_NODE){\n";
    s += "    translateTextNode(root);\n";
    s += "    return;\n";
    s += "  }\n";
    s += "  if(root.nodeType===Node.ELEMENT_NODE){\n";
    s += "    var tag=(root.tagName||'').toLowerCase();\n";
    s += "    if(tag==='script'||tag==='style'||tag==='textarea'||tag==='code'||tag==='pre')return;\n";
    s += "    if(root.closest&&root.closest('script,style,textarea,code,pre,#sp_lang'))return;\n";
    s += "    translateElementAttrs(root);\n";
    s += "    var walk=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{\n";
    s += "      acceptNode:function(n){\n";
    s += "        var p=n.parentElement;\n";
    s += "        if(!p)return NodeFilter.FILTER_REJECT;\n";
    s += "        var t=(p.tagName||'').toLowerCase();\n";
    s += "        if(t==='script'||t==='style'||t==='textarea'||t==='code'||t==='pre')return NodeFilter.FILTER_REJECT;\n";
    s += "        if(p.closest&&p.closest('script,style,textarea,code,pre,#sp_lang'))return NodeFilter.FILTER_REJECT;\n";
    s += "        return NodeFilter.FILTER_ACCEPT;\n";
    s += "      }\n";
    s += "    });\n";
    s += "    var node;\n";
    s += "    while((node=walk.nextNode())){\n";
    s += "      translateTextNode(node);\n";
    s += "    }\n";
    s += "    var els=root.querySelectorAll?root.querySelectorAll('[title],[placeholder],[aria-label],[alt],[data-tip]'):[];\n";
    s += "    for(var i=0;i<els.length;i++)translateElementAttrs(els[i]);\n";
    s += "  }\n";
    s += "}\n";
    s += "function updateTitle(){\n";
    s += "  if(document.title&&CJK.test(document.title)){\n";
    s += "    var t=translate(document.title);\n";
    s += "    if(t!==document.title)document.title=t;\n";
    s += "  }\n";
    s += "}\n";
    s += "var pendingNodes=[];\n";
    s += "var rafId=null;\n";
    s += "function flushBatch(){\n";
    s += "  rafId=null;\n";
    s += "  var batch=pendingNodes;\n";
    s += "  pendingNodes=[];\n";
    s += "  try{\n";
    s += "    for(var i=0;i<batch.length;i++)processSubtree(batch[i]);\n";
    s += "    updateTitle();\n";
    s += "  }catch(e){}\n";
    s += "}\n";
    s += "function scheduleBatch(n){\n";
    s += "  if(n)pendingNodes.push(n);\n";
    s += "  if(rafId!==null)return;\n";
    s += "  var sched=(typeof requestAnimationFrame==='function')?requestAnimationFrame:function(cb){return setTimeout(cb,0);};\n";
    s += "  rafId=sched(flushBatch);\n";
    s += "}\n";
    s += "if(document.body){\n";
    s += "  processSubtree(document.body);\n";
    s += "  updateTitle();\n";
    s += "  try{\n";
    s += "    var obs=new MutationObserver(function(muts){\n";
    s += "      try{\n";
    s += "        for(var i=0;i<muts.length;i++){\n";
    s += "          var m=muts[i];\n";
    s += "          if(m.type==='childList'){\n";
    s += "            for(var j=0;j<m.addedNodes.length;j++)pendingNodes.push(m.addedNodes[j]);\n";
    s += "          }else if(m.type==='characterData'){\n";
    s += "            if(processedNodes)processedNodes.delete(m.target);\n";
    s += "            pendingNodes.push(m.target);\n";
    s += "          }else if(m.type==='attributes'){\n";
    s += "            pendingNodes.push(m.target);\n";
    s += "          }\n";
    s += "        }\n";
    s += "        if(pendingNodes.length>0)scheduleBatch();\n";
    s += "      }catch(e){}\n";
    s += "    });\n";
    s += "    obs.observe(document.body,{\n";
    s += "      childList:true,\n";
    s += "      subtree:true,\n";
    s += "      characterData:true,\n";
    s += "      attributes:true,\n";
    s += "      attributeFilter:['title','placeholder','aria-label','alt','data-tip']\n";
    s += "    });\n";
    s += "  }catch(e){}\n";
    s += "}\n";
    s += "document.addEventListener('DOMContentLoaded',function(){\n";
    s += "  try{processSubtree(document.body);updateTitle();}catch(e){}\n";
    s += "});\n";
    s += "}catch(e){}\n";
    s += "})();</script>\n";
    return s;
}

} // namespace rta::net
