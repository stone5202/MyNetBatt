// 共用核心（見 CaptiveModels.swift 開頭說明）
import Foundation
import WebKit

/// 注入登入頁的 JavaScript。
enum PortalScript {
    /// App 自己的 JavaScript 世界：頁面的程式看不到教學資料，也冒充不了 App 的訊息。
    @MainActor static let world = WKContentWorld.world(name: "WiFiAutoLogin")

    /// 自動處理一輪：先勾同意方塊，沒得勾才按按鈕。回傳 JSON 字串：
    /// {action: "ticked"|"clicked"|"needsInput"|"none", text, via, step, count, candidates}
    /// done：已經按過的教學步驟編號（同一頁有好幾步時，不要一直重按第一步）。
    static func autoClick(steps: [LearnedStep], done: [Int] = []) -> String {
        let data = (try? JSONEncoder().encode(steps)) ?? Data("[]".utf8)
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let doneJSON = "[" + done.map(String.init).joined(separator: ",") + "]"
        return "(\(autoClickBody))(\(json),\(doneJSON))"
    }

    /// 在 App 的隔離世界執行一輪，回傳解析後的結果。
    @MainActor
    static func run(in webView: WKWebView, steps: [LearnedStep], done: [Int] = []) async -> [String: Any] {
        let raw = (try? await webView.evaluateJavaScript(autoClick(steps: steps, done: done), in: nil, contentWorld: world)) as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    }

    /// 登入頁跳出 confirm() 時要不要按「確定」：只有內容看起來是同意／連線才按。
    static func shouldAcceptConfirm(_ message: String) -> Bool {
        let m = message.lowercased()
        let negative = ["登出", "付費", "收費", "付款", "購買", "儲值", "加值", "元", "取消", "拒絕", "不同意", "刪除", "第三方", "合作夥伴", "行銷",
                        "logout", "log out", "sign out", "pay", "purchase", "buy", "charge", "cancel", "decline", "delete", "third", "partner", "$"]
        if negative.contains(where: { m.contains($0) }) { return false }
        let positive = ["同意", "接受", "確定", "確認", "連線", "上網", "繼續", "agree", "accept", "continue", "connect", "proceed", "ok"]
        return positive.contains(where: { m.contains($0) })
    }

    private static let autoClickBody = #"""
function(learned, done){
  // ---- 工具 ----
  function docs(){
    var out=[];
    (function walk(d,depth){
      out.push(d); if(depth>3) return;
      var fs=d.querySelectorAll('iframe,frame');
      for(var i=0;i<fs.length;i++){ try{ if(fs[i].contentDocument) walk(fs[i].contentDocument,depth+1); }catch(e){} }
    })(document,0);
    return out;
  }
  function win(el){ return (el.ownerDocument && el.ownerDocument.defaultView) || window; }
  function visible(el){
    if(!el || el.disabled) return false;
    if(el.getAttribute && el.getAttribute('aria-disabled')==='true') return false;
    if(!el.getClientRects || !el.getClientRects().length) return false;
    var b=el.getBoundingClientRect(); if(b.width<2 || b.height<2) return false;
    var s=win(el).getComputedStyle(el);
    return s.visibility!=='hidden' && s.display!=='none' && parseFloat(s.opacity||'1')>0.05;
  }
  function clean(t){ return (t||'').replace(/\s+/g,' ').trim(); }
  function textOf(el){
    var t='';
    if(el.tagName==='INPUT') t=el.value||el.alt||el.title||'';
    else t=el.innerText||el.textContent||'';
    t=clean(t);
    if(!t) t=clean(el.getAttribute('aria-label')||el.title||'');
    if(!t && el.querySelector){ var img=el.querySelector('img[alt]'); if(img) t=clean(img.alt); }
    return t.slice(0,80);
  }
  function labelOf(cb){
    if(cb.labels && cb.labels.length) return clean(cb.labels[0].innerText||cb.labels[0].textContent);
    var l=cb.closest && cb.closest('label'); if(l) return clean(l.innerText||l.textContent);
    var p=cb.parentElement; return p ? clean(p.innerText||p.textContent).slice(0,120) : '';
  }
  function fire(el){
    try{ el.scrollIntoView({block:'center'}); }catch(e){}
    var v=win(el);
    ['pointerdown','mousedown','pointerup','mouseup'].forEach(function(type){
      try{
        var C=(type.indexOf('pointer')===0 && v.PointerEvent) ? v.PointerEvent : v.MouseEvent;
        el.dispatchEvent(new C(type,{bubbles:true,cancelable:true,view:v}));
      }catch(e){}
    });
    el.click();
  }
  // 按下去之前看看同一張表單有沒有空的密碼欄或必填欄（那要使用者自己填）
  function missingInput(el){
    var scope=(el.closest && el.closest('form')) || el.ownerDocument;
    var ins=scope.querySelectorAll('input');
    for(var i=0;i<ins.length;i++){
      var x=ins[i], type=(x.type||'text').toLowerCase();
      if(type==='hidden'||type==='checkbox'||type==='radio'||type==='submit'||type==='button'||type==='image') continue;
      if(!visible(x) || x.value) continue;
      if(type==='password' || x.required) return type==='password' ? '密碼' : (x.placeholder||x.name||'必填欄位');
    }
    return null;
  }
  // ---- 打分規則（教學重播與自動找按鈕共用）----
  var POS=[['同意並連線',14],['同意並上網',14],['我同意',12],['同意',10],['接受',9],['開始上網',12],['免費上網',11],
    ['立即上網',11],['馬上上網',11],['我要上網',11],['上網',7],['連線',8],['連接',7],['確認',8],['確定',8],
    ['登入',6],['進入',5],['繼續',5],['下一步',5],['送出',4],['提交',4],
    ['i agree',12],['agree',10],['accept',9],['connect',8],['get online',10],['go online',10],['confirm',8],
    ['login',6],['log in',6],['sign in',5],['continue',5],['proceed',5],['browse',5],['submit',4],['start',4],
    ['ok',4],['next',3],['enter',3],['go',2]];
  var HARD_NEG=['不同意','不接受','不要','不用','拒絕','取消','登出','返回','付費','收費','付款','購買','儲值','加值','升級','訂閱','元','nt$','$',
    'decline','disagree','reject','cancel','logout','log out','sign out','back','pay','purchase','buy','upgrade','subscribe','premium','paid'];
  var SOFT_NEG=['條款','政策','隱私','說明','須知','註冊','忘記','語言','詳細','terms','policy','privacy','help','register','sign up','forgot','language','learn more','more info'];
  // 連到別的網站的連結不按（登入頁的同意按鈕不會把你帶去外站）
  function external(el){
    if(el.tagName!=='A') return false;
    var href=el.getAttribute('href')||'';
    if(!/^(https?:)?\/\//i.test(href)) return false;
    try{ return new URL(href, el.ownerDocument.baseURI).host !== el.ownerDocument.location.host; }catch(e){ return true; }
  }
  function has(t,kw){
    if(/^[a-z ]+$/.test(kw)) return new RegExp('(^|[^a-z])'+kw+'([^a-z]|$)').test(t);
    if(kw==='元') return /\d\s*元|元\s*\/|每.{0,4}元/.test(t);   // 只把金額當付費，不誤殺其他字
    return t.indexOf(kw)>=0;
  }
  function score(el){
    var raw=textOf(el), t=raw.toLowerCase();
    if(!t) return -1;
    for(var i=0;i<HARD_NEG.length;i++) if(has(t,HARD_NEG[i])) return -100;
    if(external(el)) return -100;
    var s=0;
    for(var j=0;j<POS.length;j++){ if(has(t,POS[j][0])) s=Math.max(s,POS[j][1]+(t===POS[j][0]?3:0)); }
    if(s===0) return 0;
    for(var k=0;k<SOFT_NEG.length;k++) if(has(t,SOFT_NEG[k])) s-=6;
    var tag=el.tagName, type=(el.type||'').toLowerCase();
    if(tag==='BUTTON' || (tag==='INPUT' && (type==='submit'||type==='button'||type==='image'))) s+=3;
    if(el.closest && el.closest('form')) s+=1;
    if(raw.length>30) s-=4;
    return s;
  }
  var D=docs();

  // ---- 1. 勾選同意方塊 ----
  var ticked=0;
  function tick(cb){
    var target=cb;
    if(!visible(cb)){
      var lab=(cb.labels && cb.labels[0]) || (cb.closest && cb.closest('label'));
      if(lab && visible(lab)) target=lab;
    }
    target.click();
    if(!cb.checked){
      cb.checked=true;
      cb.dispatchEvent(new Event('input',{bubbles:true}));
      cb.dispatchEvent(new Event('change',{bubbles:true}));
    }
    ticked++;
  }
  function findLearned(st){
    for(var i=0;i<D.length;i++){
      var list=[]; try{ list=D[i].querySelectorAll(st.selector); }catch(e){}
      for(var j=0;j<list.length;j++){
        var el=list[j];
        if(st.kind==='check'){ if(el.type==='checkbox') return el; continue; }
        if(!visible(el)) continue;
        // 按鈕文字變了（例如同一個位置改成「登出」）就不按，請使用者重新教學
        if(!st.text || textOf(el)===st.text) return el;
      }
    }
    if(st.kind==='click' && st.text){
      for(var k=0;k<D.length;k++){
        var cs=D[k].querySelectorAll('button,input[type=submit],input[type=button],input[type=image],a,[role=button],[onclick]');
        for(var m=0;m<cs.length;m++){ if(visible(cs[m]) && textOf(cs[m])===st.text) return cs[m]; }
      }
    }
    return null;
  }
  learned.forEach(function(st){
    if(st.kind!=='check') return;
    var cb=findLearned(st);
    if(cb && !cb.checked && !cb.disabled) tick(cb);
  });
  var AGREE=/同意|接受|閱讀|已讀|知悉|了解|瞭解|遵守|條款|規範|agree|accept|consent|terms|read/i;
  var SKIP=/不同意|不接受|訂閱|電子報|行銷|廣告|記住|合作夥伴|第三方|提供.{0,6}(個人|個資)|分享|付費|購買|subscribe|newsletter|marketing|remember|partner|third.party|share|purchase/i;
  D.forEach(function(d){
    var all=d.querySelectorAll('input[type=checkbox]');
    for(var i=0;i<all.length;i++){
      var cb=all[i]; if(cb.checked || cb.disabled) continue;
      var lt=labelOf(cb);
      if(SKIP.test(lt)) continue;
      if(AGREE.test(lt)) tick(cb);
    }
  });
  if(ticked>0) return JSON.stringify({action:'ticked',count:ticked});

  // ---- 2. 教學記下的按鈕 ----
  for(var i=0;i<learned.length;i++){
    var st=learned[i]; if(st.kind!=='click' || done.indexOf(i)>=0) continue;
    var el=findLearned(st);
    if(el){
      if(score(el)<=-100) continue;   // 變成拒絕／付費／外站之類的，不按
      var miss=missingInput(el);
      if(miss) return JSON.stringify({action:'needsInput',text:miss});
      var t=textOf(el); fire(el);
      return JSON.stringify({action:'clicked',via:'learned',text:t,step:i});
    }
  }

  // ---- 3. 依按鈕文字找 ----
  var SEL='button,input[type=submit],input[type=button],input[type=image],a,[role=button],[onclick],[class*="btn"],[class*="button"],[class*="Btn"],[class*="Button"]';
  var best=null, bestScore=0, seen=[], names=[];
  D.forEach(function(d){
    var cs=d.querySelectorAll(SEL);
    for(var i=0;i<cs.length;i++){
      var el=cs[i];
      if(seen.indexOf(el)>=0 || !visible(el)) continue;
      seen.push(el);
      var tx=textOf(el); if(tx && names.length<12 && names.indexOf(tx)<0) names.push(tx);
      var s=score(el);
      // 分數一樣時選比較內層的（外層容器常常也被選到）
      if(s>bestScore || (s===bestScore && best && best.contains(el))){ best=el; bestScore=s; }
    }
  });
  if(!best || bestScore<5) return JSON.stringify({action:'none',candidates:names});
  var miss2=missingInput(best);
  if(miss2) return JSON.stringify({action:'needsInput',text:miss2});
  var bt=textOf(best); fire(best);
  return JSON.stringify({action:'clicked',via:'auto',text:bt,score:bestScore});
}
"""#

    /// 教學模式：登入頁上每按一下，就把那個元素的選擇器與文字傳回 App。所有框架都注入。
    static let learnRecorder = #"""
(function(){
  if(window.__walRecorder) return; window.__walRecorder=true;
  function clean(t){ return (t||'').replace(/\s+/g,' ').trim(); }
  // 只有按鈕類的 input 讀 value；文字、密碼等輸入欄絕不讀值
  function textOf(el){
    var t='';
    var type=(el.type||'').toLowerCase();
    if(el.tagName==='INPUT') t=/^(submit|button|image|reset)$/.test(type) ? (el.value||el.alt||el.title||'') : '';
    else t=el.innerText||el.textContent||'';
    t=clean(t);
    if(!t) t=clean(el.getAttribute('aria-label')||el.title||'');
    if(type==='checkbox'){
      if(el.labels && el.labels.length) t=clean(el.labels[0].innerText);
      else { var l=el.closest('label'); if(l) t=clean(l.innerText); }
    }
    return t.slice(0,80);
  }
  function esc(s){ return (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g,'\\$&'); }
  function unique(sel){ try{ return document.querySelectorAll(sel).length===1; }catch(e){ return false; } }
  function cssPath(el){
    if(el.id && unique('#'+esc(el.id))) return '#'+esc(el.id);
    var parts=[], node=el;
    while(node && node.nodeType===1 && node!==document.body && node!==document.documentElement && parts.length<6){
      if(node!==el && node.id && unique('#'+esc(node.id))){ parts.unshift('#'+esc(node.id)); break; }
      var part=node.tagName.toLowerCase();
      var name=node.getAttribute('name');
      if(name && /^(input|button|select)$/.test(part)) part+='[name="'+name.replace(/"/g,'\\"')+'"]';
      else if(node.parentElement){
        var same=Array.prototype.filter.call(node.parentElement.children,function(c){return c.tagName===node.tagName;});
        if(same.length>1) part+=':nth-of-type('+(same.indexOf(node)+1)+')';
      }
      parts.unshift(part);
      if(unique(parts.join(' > '))) break;
      node=node.parentElement;
    }
    return parts.join(' > ');
  }
  document.addEventListener('click',function(ev){
    var el=ev.target;
    if(!el || !el.closest) return;
    // 點到 label 時，記它對應的方塊
    var lab=el.closest('label');
    if(lab && el.tagName!=='INPUT'){
      var c=lab.control || lab.querySelector('input[type=checkbox]');
      if(c && c.type==='checkbox') el=c;
    }
    if(!(el.tagName==='INPUT' && el.type==='checkbox')){
      var c2=el.closest('button,input[type=submit],input[type=button],input[type=image],a,[role=button],[onclick]');
      if(c2) el=c2;
    }
    // 點到輸入欄（帳號、密碼、手機…）、選單、文字區都不記
    if(el.tagName==='TEXTAREA' || el.tagName==='SELECT' || el.isContentEditable) return;
    if(el.tagName==='INPUT' && !/^(checkbox|submit|button|image)$/.test((el.type||'').toLowerCase())) return;
    var kind=(el.tagName==='INPUT' && el.type==='checkbox') ? 'check' : 'click';
    try{
      window.webkit.messageHandlers.walLearn.postMessage({kind:kind, selector:cssPath(el), text:textOf(el), page:location.href});
    }catch(e){}
  },true);
})();
"""#
}
