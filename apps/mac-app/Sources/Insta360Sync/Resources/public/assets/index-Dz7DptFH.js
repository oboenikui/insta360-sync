(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const i of document.querySelectorAll('link[rel="modulepreload"]'))r(i);new MutationObserver(i=>{for(const a of i)if(a.type==="childList")for(const f of a.addedNodes)f.tagName==="LINK"&&f.rel==="modulepreload"&&r(f)}).observe(document,{childList:!0,subtree:!0});function n(i){const a={};return i.integrity&&(a.integrity=i.integrity),i.referrerPolicy&&(a.referrerPolicy=i.referrerPolicy),i.crossOrigin==="use-credentials"?a.credentials="include":i.crossOrigin==="anonymous"?a.credentials="omit":a.credentials="same-origin",a}function r(i){if(i.ep)return;i.ep=!0;const a=n(i);fetch(i.href,a)}})();const S="insta360-sync.apiToken",v="insta360-sync.baseUrl";function l(){var e;return((e=localStorage.getItem(S))==null?void 0:e.trim())??""}function y(e){localStorage.setItem(S,e.trim())}function u(){return localStorage.getItem(v)??window.location.origin}function g(e){localStorage.setItem(v,e.replace(/\/$/,""))}async function c(e,t={}){const n=l();if(!n)throw new Error("401 API トークン未設定");const r=new Headers(t.headers);r.set("Authorization",`Bearer ${n}`),t.body&&!r.has("Content-Type")&&r.set("Content-Type","application/json");const i=await fetch(`${u()}${e}`,{...t,headers:r});if(!i.ok)throw i.status===401?new Error("401 API トークン不一致"):new Error(`${i.status} ${i.statusText}`);if(i.status!==204)return await i.json()}function P(e){const t="=".repeat((4-e.length%4)%4),n=(e+t).replace(/-/g,"+").replace(/_/g,"/"),r=atob(n),i=new Uint8Array(r.length);for(let a=0;a<r.length;a+=1)i[a]=r.charCodeAt(a);return i}async function A(){const e=await fetch(`${u()}/api/public/vapid`);if(!e.ok)throw new Error(`${e.status} VAPID 公開鍵の取得に失敗`);const t=await e.json();if(!t.vapidPublicKey)throw new Error("VAPID 公開鍵が空です");return t.vapidPublicKey}async function $(){const e=await fetch(`${u()}/api/public/certificate`);if(!e.ok)throw new Error(`${e.status} 証明書情報の取得に失敗`);return await e.json()}function k(e){return`${u()}/api/public/certificate.${e}`}async function L(e){if(!("serviceWorker"in navigator)||!("PushManager"in window))throw new Error("このブラウザは Web Push に対応していません");const t=await A(),n=await navigator.serviceWorker.register("./sw.js");await navigator.serviceWorker.ready;const i=(await n.pushManager.subscribe({userVisibleOnly:!0,applicationServerKey:P(t)})).toJSON();await c("/api/push/subscribe",{method:"POST",body:JSON.stringify({endpoint:i.endpoint,keys:i.keys})})}const T=document.querySelector("#app");let d=null;function C(){T.innerHTML=`
    <main class="container">
      <header class="app-header">
        <div>
          <h1>Insta360 Sync</h1>
          <p class="muted">Mac からのバックアップ承認</p>
        </div>
        <button id="openSettings" class="icon-button" type="button" aria-label="設定">
          <span aria-hidden="true">⚙</span>
        </button>
      </header>

      <div id="mainView" class="view">
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
      </div>

      <div id="settingsView" class="view" hidden>
        <div class="settings-header">
          <button id="closeSettings" class="icon-button" type="button" aria-label="戻る">
            <span aria-hidden="true">←</span>
          </button>
          <h2>設定</h2>
        </div>

        <section class="card">
          <h3>ペアリング</h3>
          <label>Mac HTTPS URL<input id="baseUrl" type="url" placeholder="https://your-mac.local:9443" /></label>
          <label>API トークン<input id="apiToken" type="text" placeholder="Mac アプリに表示されたトークン" /></label>
          <div class="settings-actions">
            <button id="savePairing" type="button">保存</button>
            <button id="enablePush" type="button" class="secondary">Push 通知を有効化</button>
          </div>
          <p id="pairingStatus" class="muted"></p>
        </section>

        <section class="card">
          <h3>ルート証明書</h3>
          <p class="muted">
            Mac が生成した自己署名ルート証明書を端末にインストールすると、ブラウザや PWA が
            この Mac の HTTPS を「信頼済み」として扱えるようになります。一度信頼設定を有効に
            すれば、以降このセクションを開く必要はありません。
          </p>
          <div id="certificateSummary" class="muted">証明書情報を取得しています…</div>
          <div class="cert-actions">
            <a id="downloadCrt" class="button-link" href="#" rel="noopener">
              証明書をダウンロード (.crt)
            </a>
            <button id="copyPem" class="secondary" type="button">PEM をコピー</button>
          </div>
          <p id="certificateStatus" class="muted"></p>
          <details class="cert-help">
            <summary>インストール手順</summary>
            <div class="cert-help-body">
              <h4>iOS / iPadOS</h4>
              <ol>
                <li>Safari で「証明書をダウンロード」ボタンをタップし、プロファイルをダウンロードします。</li>
                <li>設定 → 一般 → VPN とデバイス管理 → ダウンロードされたプロファイル
                  を開き、インストールします。</li>
                <li>設定 → 一般 → 情報 → 証明書信頼設定 で当該証明書のスイッチをオンに
                  します（フル信頼の有効化）。</li>
                <li>Safari を再読み込みし、鍵アイコンが警告なしになれば完了です。</li>
              </ol>
              <h4>Android</h4>
              <ol>
                <li>Chrome で「証明書をダウンロード」ボタンをタップしてファイルを保存します。</li>
                <li>設定 → セキュリティとプライバシー → その他 → 暗号化と認証情報 →
                  証明書のインストール → CA 証明書 を選択します（機種により表記が異なる場合があります）。</li>
                <li>ダウンロードしたファイルを選択し「ユーザーによりインストールされた CA 証明書」
                  として保存します。</li>
                <li>Chrome を再起動すると信頼されます（一部のアプリはユーザー CA を信頼しない
                  ことがあります）。</li>
              </ol>
              <p class="muted">
                フィンガープリント (SHA-256) が Mac 設定画面と一致していることを確認してから
                インストールしてください。
              </p>
            </div>
          </details>
        </section>
      </div>
    </main>
  `,document.querySelector("#openSettings").onclick=()=>{h("settings")},document.querySelector("#closeSettings").onclick=()=>{h("main")},I(),q()}function h(e){document.querySelector("#mainView").hidden=e!=="main",document.querySelector("#settingsView").hidden=e!=="settings",document.querySelector("#openSettings").hidden=e!=="main",e==="settings"&&w()}function I(){const e=document.querySelector("#baseUrl"),t=document.querySelector("#apiToken");e.value=u(),t.value=l(),document.querySelector("#savePairing").onclick=()=>{g(e.value),y(t.value),s("ペアリング情報を保存しました"),w()},document.querySelector("#enablePush").onclick=async()=>{try{if(g(e.value),y(t.value),!l()){s("API トークンを Mac アプリの設定画面からコピーして入力してください");return}await c("/api/settings"),await L(),s("Push 通知を登録しました")}catch(n){const r=n.message;if(r.includes("401")){s("Push 登録失敗: API トークンが一致しません。Mac アプリの設定 → API トークンを「コピー」して PWA に貼り付けてください");return}s(`Push 登録失敗: ${r}`)}}}function s(e){const t=document.querySelector("#pairingStatus");t&&(t.textContent=e)}function m(e){const t=document.querySelector("#certificateStatus");t&&(t.textContent=e)}function q(){const e=document.querySelector("#downloadCrt"),t=document.querySelector("#copyPem"),n=()=>{e.href=k("crt"),d&&e.setAttribute("download",`${d.downloadBaseName}.crt`)};n(),e.addEventListener("click",n),t.addEventListener("click",async()=>{if(!d){m("証明書情報がまだ取得できていません。");return}try{await navigator.clipboard.writeText(d.pem),m("PEM をクリップボードにコピーしました。")}catch(r){m(`コピーに失敗しました: ${r.message}`)}})}async function w(){const e=document.querySelector("#certificateSummary");if(e)try{const t=await $();d=t,e.innerHTML=N(t);const n=document.querySelector("#downloadCrt");n&&n.setAttribute("download",`${t.downloadBaseName}.crt`)}catch(t){e.textContent=`証明書情報の取得に失敗しました: ${t.message}`}}function N(e){const t=e.dnsNames.length>0?e.dnsNames.join(", "):"(なし)",n=e.ipAddresses.length>0?e.ipAddresses.join(", "):"(なし)",r=b(e.notBefore),i=b(e.notAfter);return`
    <dl class="cert-info">
      <dt>コモンネーム</dt>
      <dd>${o(e.commonName)}</dd>
      <dt>DNS 名</dt>
      <dd>${o(t)}</dd>
      <dt>IP アドレス</dt>
      <dd>${o(n)}</dd>
      <dt>有効期間</dt>
      <dd>${o(r)} 〜 ${o(i)}</dd>
      <dt>SHA-256 フィンガープリント</dt>
      <dd class="mono">${o(e.sha256Fingerprint)}</dd>
    </dl>
  `}function b(e){if(!e)return"不明";const t=new Date(e);return Number.isNaN(t.getTime())?e:t.toLocaleString()}function o(e){return e.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/'/g,"&#39;")}async function p(){if(l())try{const e=await c("/api/backup/pending");E(e);const t=await c("/api/backup/status");M(t),O(t.history)}catch(e){s(`API エラー: ${e.message}`)}}function E(e){const t=document.querySelector("#pendingList");if(t){if(e.length===0){t.innerHTML='<p class="muted">承認待ちはありません</p>';return}t.innerHTML=e.map(n=>`
      <article class="pending-item">
        <div>
          <strong>${n.cameraName}</strong>
          <div class="muted">${n.ssid}</div>
        </div>
        <div class="actions">
          <button data-approve="${n.id}">バックアップ開始</button>
          <button data-skip="${n.id}" class="secondary">スキップ</button>
        </div>
      </article>`).join(""),t.querySelectorAll("[data-approve]").forEach(n=>{n.addEventListener("click",async()=>{const r=n.dataset.approve;await c("/api/backup/approve",{method:"POST",body:JSON.stringify({pendingId:r})}),await p()})}),t.querySelectorAll("[data-skip]").forEach(n=>{n.addEventListener("click",async()=>{const r=n.dataset.skip;await c("/api/backup/skip",{method:"POST",body:JSON.stringify({pendingId:r})}),await p()})})}}function M(e){const t=document.querySelector("#progressBox");if(t){if(!e.progress){t.textContent=`状態: ${e.status}`;return}t.textContent=JSON.stringify(e.progress,null,2)}}function O(e){const t=document.querySelector("#historyList");if(t){if(e.length===0){t.innerHTML='<p class="muted">履歴はまだありません</p>';return}t.innerHTML=e.slice(0,10).map(n=>`
      <article class="history-item">
        <strong>${n.cameraName}</strong>
        <div class="muted">新規 ${n.copiedCount} / スキップ ${n.skippedCount} / 失敗 ${n.failedCount}</div>
      </article>`).join("")}}function B(){const t=new URLSearchParams(window.location.search).get("pendingBackup");t&&s(`通知から開きました: ${t}`),l()||h("settings")}C();B();setInterval(()=>{p()},5e3);p();
