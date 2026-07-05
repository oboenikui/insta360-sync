(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const n of document.querySelectorAll('link[rel="modulepreload"]'))i(n);new MutationObserver(n=>{for(const o of n)if(o.type==="childList")for(const f of o.addedNodes)f.tagName==="LINK"&&f.rel==="modulepreload"&&i(f)}).observe(document,{childList:!0,subtree:!0});function r(n){const o={};return n.integrity&&(o.integrity=n.integrity),n.referrerPolicy&&(o.referrerPolicy=n.referrerPolicy),n.crossOrigin==="use-credentials"?o.credentials="include":n.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function i(n){if(n.ep)return;n.ep=!0;const o=r(n);fetch(n.href,o)}})();const w="insta360-sync.apiToken",S="insta360-sync.baseUrl";function u(){var e;return((e=localStorage.getItem(w))==null?void 0:e.trim())??""}function h(e){localStorage.setItem(w,e.trim())}function l(){return localStorage.getItem(S)??window.location.origin}function g(e){localStorage.setItem(S,e.replace(/\/$/,""))}async function c(e,t={}){const r=u();if(!r)throw new Error("401 API トークン未設定");const i=new Headers(t.headers);i.set("Authorization",`Bearer ${r}`),t.body&&!i.has("Content-Type")&&i.set("Content-Type","application/json");const n=await fetch(`${l()}${e}`,{...t,headers:i});if(!n.ok)throw n.status===401?new Error("401 API トークン不一致"):new Error(`${n.status} ${n.statusText}`);if(n.status!==204)return await n.json()}function P(e){const t="=".repeat((4-e.length%4)%4),r=(e+t).replace(/-/g,"+").replace(/_/g,"/"),i=atob(r),n=new Uint8Array(i.length);for(let o=0;o<i.length;o+=1)n[o]=i.charCodeAt(o);return n}async function A(){const e=await fetch(`${l()}/api/public/vapid`);if(!e.ok)throw new Error(`${e.status} VAPID 公開鍵の取得に失敗`);const t=await e.json();if(!t.vapidPublicKey)throw new Error("VAPID 公開鍵が空です");return t.vapidPublicKey}async function $(){const e=await fetch(`${l()}/api/public/certificate`);if(!e.ok)throw new Error(`${e.status} 証明書情報の取得に失敗`);return await e.json()}function y(e){return`${l()}/api/public/certificate.${e}`}async function k(e){if(!("serviceWorker"in navigator)||!("PushManager"in window))throw new Error("このブラウザは Web Push に対応していません");const t=await A(),r=await navigator.serviceWorker.register("./sw.js");await navigator.serviceWorker.ready;const n=(await r.pushManager.subscribe({userVisibleOnly:!0,applicationServerKey:P(t)})).toJSON();await c("/api/push/subscribe",{method:"POST",body:JSON.stringify({endpoint:n.endpoint,keys:n.keys})})}const L=document.querySelector("#app");function C(){L.innerHTML=`
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

      <section class="card">
        <h2>ルート証明書</h2>
        <p class="muted">
          Mac が生成した自己署名ルート証明書を iOS / Android にインストールすると、ブラウザや PWA が
          この Mac の HTTPS を「信頼済み」として扱えるようになります。証明書は Mac にのみ保存され、
          他の端末には配布されません。
        </p>
        <div id="certificateSummary" class="muted">証明書情報を取得しています…</div>
        <div class="cert-actions">
          <a id="downloadMobileConfig" class="button-link" href="#" rel="noopener">
            iOS: 構成プロファイル (.mobileconfig)
          </a>
          <a id="downloadCrt" class="button-link secondary" href="#" rel="noopener">
            Android: 証明書 (.crt)
          </a>
          <button id="copyPem" class="secondary" type="button">PEM をコピー</button>
        </div>
        <p id="certificateStatus" class="muted"></p>
        <details class="cert-help">
          <summary>インストール手順</summary>
          <div class="cert-help-body">
            <h3>iOS / iPadOS</h3>
            <ol>
              <li>Safari で「iOS: 構成プロファイル」ボタンをタップして .mobileconfig を開きます。</li>
              <li>「設定 → 一般 → VPN とデバイス管理」からダウンロード済みプロファイルを開き、
                インストールします。</li>
              <li>「設定 → 一般 → 情報 → 証明書信頼設定」で当該証明書のスイッチをオンにします
                （フル信頼の有効化）。</li>
              <li>Safari を再読み込みし、鍵アイコンが警告なしになれば完了です。</li>
            </ol>
            <h3>Android</h3>
            <ol>
              <li>Chrome で「Android: 証明書 (.crt)」ボタンをタップしてダウンロードします。</li>
              <li>「設定 → セキュリティとプライバシー → その他 → 暗号化と認証情報 → 証明書のインストール
                → CA 証明書」を選択します（機種により表記が異なる場合があります）。</li>
              <li>ダウンロードしたファイルを選択して「ユーザーによりインストールされた CA 証明書」として保存します。</li>
              <li>Chrome を再起動すると信頼されます（一部のアプリはユーザー CA を信頼しないことがあります）。</li>
            </ol>
            <p class="muted">
              フィンガープリント (SHA-256) が Mac 設定画面と一致していることを確認してからインストールしてください。
            </p>
          </div>
        </details>
      </section>
    </main>
  `;const e=document.querySelector("#baseUrl"),t=document.querySelector("#apiToken");e.value=l(),t.value=u(),document.querySelector("#savePairing").onclick=()=>{g(e.value),h(t.value),a("ペアリング情報を保存しました"),v()},T(),document.querySelector("#enablePush").onclick=async()=>{try{if(g(e.value),h(t.value),!u()){a("API トークンを Mac アプリの設定画面からコピーして入力してください");return}await c("/api/settings"),await k(),a("Push 通知を登録しました")}catch(r){const i=r.message;if(i.includes("401")){a("Push 登録失敗: API トークンが一致しません。Mac アプリの設定 → API トークンを「コピー」して PWA に貼り付けてください");return}a(`Push 登録失敗: ${i}`)}}}function a(e){const t=document.querySelector("#pairingStatus");t&&(t.textContent=e)}function m(e){const t=document.querySelector("#certificateStatus");t&&(t.textContent=e)}let d=null;function T(){const e=document.querySelector("#downloadMobileConfig"),t=document.querySelector("#downloadCrt"),r=document.querySelector("#copyPem"),i=()=>{if(e.href=y("mobileconfig"),t.href=y("crt"),d){const n=d.downloadBaseName;e.setAttribute("download",`${n}.mobileconfig`),t.setAttribute("download",`${n}.crt`)}};i(),e.addEventListener("click",i),t.addEventListener("click",i),r.addEventListener("click",async()=>{if(!d){m("証明書情報がまだ取得できていません。");return}try{await navigator.clipboard.writeText(d.pem),m("PEM をクリップボードにコピーしました。")}catch(n){m(`コピーに失敗しました: ${n.message}`)}}),v()}async function v(){const e=document.querySelector("#certificateSummary");if(e)try{const t=await $();d=t,e.innerHTML=I(t);const r=document.querySelector("#downloadMobileConfig"),i=document.querySelector("#downloadCrt");r&&r.setAttribute("download",`${t.downloadBaseName}.mobileconfig`),i&&i.setAttribute("download",`${t.downloadBaseName}.crt`)}catch(t){e.textContent=`証明書情報の取得に失敗しました: ${t.message}`}}function I(e){const t=e.dnsNames.length>0?e.dnsNames.join(", "):"(なし)",r=e.ipAddresses.length>0?e.ipAddresses.join(", "):"(なし)",i=b(e.notBefore),n=b(e.notAfter);return`
    <dl class="cert-info">
      <dt>コモンネーム</dt>
      <dd>${s(e.commonName)}</dd>
      <dt>DNS 名</dt>
      <dd>${s(t)}</dd>
      <dt>IP アドレス</dt>
      <dd>${s(r)}</dd>
      <dt>有効期間</dt>
      <dd>${s(i)} 〜 ${s(n)}</dd>
      <dt>SHA-256 フィンガープリント</dt>
      <dd class="mono">${s(e.sha256Fingerprint)}</dd>
    </dl>
  `}function b(e){if(!e)return"不明";const t=new Date(e);return Number.isNaN(t.getTime())?e:t.toLocaleString()}function s(e){return e.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/'/g,"&#39;")}async function p(){if(u())try{const e=await c("/api/backup/pending");M(e);const t=await c("/api/backup/status");N(t),E(t.history)}catch(e){a(`API エラー: ${e.message}`)}}function M(e){const t=document.querySelector("#pendingList");if(e.length===0){t.innerHTML='<p class="muted">承認待ちはありません</p>';return}t.innerHTML=e.map(r=>`
      <article class="pending-item">
        <div>
          <strong>${r.cameraName}</strong>
          <div class="muted">${r.ssid}</div>
        </div>
        <div class="actions">
          <button data-approve="${r.id}">バックアップ開始</button>
          <button data-skip="${r.id}" class="secondary">スキップ</button>
        </div>
      </article>`).join(""),t.querySelectorAll("[data-approve]").forEach(r=>{r.addEventListener("click",async()=>{const i=r.dataset.approve;await c("/api/backup/approve",{method:"POST",body:JSON.stringify({pendingId:i})}),await p()})}),t.querySelectorAll("[data-skip]").forEach(r=>{r.addEventListener("click",async()=>{const i=r.dataset.skip;await c("/api/backup/skip",{method:"POST",body:JSON.stringify({pendingId:i})}),await p()})})}function N(e){const t=document.querySelector("#progressBox");if(!e.progress){t.textContent=`状態: ${e.status}`;return}t.textContent=JSON.stringify(e.progress,null,2)}function E(e){const t=document.querySelector("#historyList");if(e.length===0){t.innerHTML='<p class="muted">履歴はまだありません</p>';return}t.innerHTML=e.slice(0,10).map(r=>`
      <article class="history-item">
        <strong>${r.cameraName}</strong>
        <div class="muted">新規 ${r.copiedCount} / スキップ ${r.skippedCount} / 失敗 ${r.failedCount}</div>
      </article>`).join("")}function O(){const t=new URLSearchParams(window.location.search).get("pendingBackup");t&&a(`通知から開きました: ${t}`)}C();O();setInterval(()=>{p()},5e3);p();
