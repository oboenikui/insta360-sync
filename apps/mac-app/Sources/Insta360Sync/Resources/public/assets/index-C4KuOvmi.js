(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const n of document.querySelectorAll('link[rel="modulepreload"]'))i(n);new MutationObserver(n=>{for(const s of n)if(s.type==="childList")for(const l of s.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&i(l)}).observe(document,{childList:!0,subtree:!0});function r(n){const s={};return n.integrity&&(s.integrity=n.integrity),n.referrerPolicy&&(s.referrerPolicy=n.referrerPolicy),n.crossOrigin==="use-credentials"?s.credentials="include":n.crossOrigin==="anonymous"?s.credentials="omit":s.credentials="same-origin",s}function i(n){if(n.ep)return;n.ep=!0;const s=r(n);fetch(n.href,s)}})();const h="insta360-sync.apiToken",g="insta360-sync.baseUrl";function c(){var e;return((e=localStorage.getItem(h))==null?void 0:e.trim())??""}function p(e){localStorage.setItem(h,e.trim())}function d(){return localStorage.getItem(g)??window.location.origin}function f(e){localStorage.setItem(g,e.replace(/\/$/,""))}async function o(e,t={}){const r=c();if(!r)throw new Error("401 API トークン未設定");const i=new Headers(t.headers);i.set("Authorization",`Bearer ${r}`),t.body&&!i.has("Content-Type")&&i.set("Content-Type","application/json");const n=await fetch(`${d()}${e}`,{...t,headers:i});if(!n.ok)throw n.status===401?new Error("401 API トークン不一致"):new Error(`${n.status} ${n.statusText}`);if(n.status!==204)return await n.json()}function y(e){const t="=".repeat((4-e.length%4)%4),r=(e+t).replace(/-/g,"+").replace(/_/g,"/"),i=atob(r),n=new Uint8Array(i.length);for(let s=0;s<i.length;s+=1)n[s]=i.charCodeAt(s);return n}async function m(){const e=await fetch(`${d()}/api/public/vapid`);if(!e.ok)throw new Error(`${e.status} VAPID 公開鍵の取得に失敗`);const t=await e.json();if(!t.vapidPublicKey)throw new Error("VAPID 公開鍵が空です");return t.vapidPublicKey}async function b(e){if(!("serviceWorker"in navigator)||!("PushManager"in window))throw new Error("このブラウザは Web Push に対応していません");const t=await m(),r=await navigator.serviceWorker.register("./sw.js");await navigator.serviceWorker.ready;const n=(await r.pushManager.subscribe({userVisibleOnly:!0,applicationServerKey:y(t)})).toJSON();await o("/api/push/subscribe",{method:"POST",body:JSON.stringify({endpoint:n.endpoint,keys:n.keys})})}const v=document.querySelector("#app");function w(){v.innerHTML=`
    <main class="container">
      <header>
        <h1>Insta360 Sync</h1>
        <p class="muted">Mac からのバックアップ承認</p>
      </header>

      <section class="card">
        <h2>ペアリング</h2>
        <label>Mac HTTPS URL<input id="baseUrl" type="url" placeholder="https://your-mac.local:9443" /></label>
        <label>API トークン<input id="apiToken" type="text" placeholder="Mac アプリに表示されたトークン" /></label>
        <button id="savePairing">保存</button>
        <button id="enablePush">Push 通知を有効化</button>
        <p id="pairingStatus" class="muted"></p>
      </section>

      <section class="card">
        <h2>承認待ち</h2>
        <div id="pendingList"></div>
      </section>

      <section class="card">
        <h2>進捗</h2>
        <pre id="progressBox" class="mono"></pre>
      </section>

      <section class="card">
        <h2>履歴</h2>
        <div id="historyList"></div>
      </section>
    </main>
  `;const e=document.querySelector("#baseUrl"),t=document.querySelector("#apiToken");e.value=d(),t.value=c(),document.querySelector("#savePairing").onclick=()=>{f(e.value),p(t.value),a("ペアリング情報を保存しました")},document.querySelector("#enablePush").onclick=async()=>{try{if(f(e.value),p(t.value),!c()){a("API トークンを Mac アプリの設定画面からコピーして入力してください");return}await o("/api/settings"),await b(),a("Push 通知を登録しました")}catch(r){const i=r.message;if(i.includes("401")){a("Push 登録失敗: API トークンが一致しません。Mac アプリの設定 → API トークンを「コピー」して PWA に貼り付けてください");return}a(`Push 登録失敗: ${i}`)}}}function a(e){const t=document.querySelector("#pairingStatus");t&&(t.textContent=e)}async function u(){if(c())try{const e=await o("/api/backup/pending");P(e);const t=await o("/api/backup/status");S(t),k(t.history)}catch(e){a(`API エラー: ${e.message}`)}}function P(e){const t=document.querySelector("#pendingList");if(e.length===0){t.innerHTML='<p class="muted">承認待ちはありません</p>';return}t.innerHTML=e.map(r=>`
      <article class="pending-item">
        <div>
          <strong>${r.cameraName}</strong>
          <div class="muted">${r.ssid}</div>
        </div>
        <div class="actions">
          <button data-approve="${r.id}">バックアップ開始</button>
          <button data-skip="${r.id}" class="secondary">スキップ</button>
        </div>
      </article>`).join(""),t.querySelectorAll("[data-approve]").forEach(r=>{r.addEventListener("click",async()=>{const i=r.dataset.approve;await o("/api/backup/approve",{method:"POST",body:JSON.stringify({pendingId:i})}),await u()})}),t.querySelectorAll("[data-skip]").forEach(r=>{r.addEventListener("click",async()=>{const i=r.dataset.skip;await o("/api/backup/skip",{method:"POST",body:JSON.stringify({pendingId:i})}),await u()})})}function S(e){const t=document.querySelector("#progressBox");if(!e.progress){t.textContent=`状態: ${e.status}`;return}t.textContent=JSON.stringify(e.progress,null,2)}function k(e){const t=document.querySelector("#historyList");if(e.length===0){t.innerHTML='<p class="muted">履歴はまだありません</p>';return}t.innerHTML=e.slice(0,10).map(r=>`
      <article class="history-item">
        <strong>${r.cameraName}</strong>
        <div class="muted">新規 ${r.copiedCount} / スキップ ${r.skippedCount} / 失敗 ${r.failedCount}</div>
      </article>`).join("")}function I(){const t=new URLSearchParams(window.location.search).get("pendingBackup");t&&a(`通知から開きました: ${t}`)}w();I();setInterval(()=>{u()},5e3);u();
