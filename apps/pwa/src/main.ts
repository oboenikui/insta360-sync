import {
  apiFetch,
  certificateDownloadURL,
  fetchCertificateInfo,
  getApiToken,
  getBaseURL,
  registerPush,
  setApiToken,
  setBaseURL,
  type CertificateInfo,
} from "./api";
import "./style.css";

type PendingBackup = {
  id: string;
  cameraName: string;
  ssid: string;
  detectedAt: string;
  status: string;
};

type BackupStatus = {
  status: string;
  progress?: {
    cameraName: string;
    completed: number;
    total: number;
    currentFile?: string;
    phase: string;
  };
  pending: PendingBackup[];
  history: Array<{
    id: string;
    cameraName: string;
    copiedCount: number;
    skippedCount: number;
    failedCount: number;
    message?: string;
  }>;
};

type PublicSettings = {
  destinationRoot: string;
  folderStructureMode: string;
  vapidPublicKey: string;
  cameras: Array<{ id: string; displayName: string; ssid: string; isEnabled: boolean }>;
};

const app = document.querySelector<HTMLDivElement>("#app")!;

function renderShell() {
  app.innerHTML = `
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
  `;

  const baseUrlInput = document.querySelector<HTMLInputElement>("#baseUrl")!;
  const apiTokenInput = document.querySelector<HTMLInputElement>("#apiToken")!;
  baseUrlInput.value = getBaseURL();
  apiTokenInput.value = getApiToken();

  document.querySelector<HTMLButtonElement>("#savePairing")!.onclick = () => {
    setBaseURL(baseUrlInput.value);
    setApiToken(apiTokenInput.value);
    setStatus("ペアリング情報を保存しました");
    void refreshCertificate();
  };

  setupCertificateSection();

  document.querySelector<HTMLButtonElement>("#enablePush")!.onclick = async () => {
    try {
      setBaseURL(baseUrlInput.value);
      setApiToken(apiTokenInput.value);
      if (!getApiToken()) {
        setStatus("API トークンを Mac アプリの設定画面からコピーして入力してください");
        return;
      }
      await apiFetch<PublicSettings>("/api/settings");
      await registerPush();
      setStatus("Push 通知を登録しました");
    } catch (error) {
      const message = (error as Error).message;
      if (message.includes("401")) {
        setStatus(
          "Push 登録失敗: API トークンが一致しません。Mac アプリの設定 → API トークンを「コピー」して PWA に貼り付けてください"
        );
        return;
      }
      setStatus(`Push 登録失敗: ${message}`);
    }
  };
}

function setStatus(message: string) {
  const el = document.querySelector<HTMLParagraphElement>("#pairingStatus");
  if (el) el.textContent = message;
}

function setCertificateStatus(message: string) {
  const el = document.querySelector<HTMLParagraphElement>("#certificateStatus");
  if (el) el.textContent = message;
}

let latestCertificateInfo: CertificateInfo | null = null;

function setupCertificateSection() {
  const mobileConfigLink =
    document.querySelector<HTMLAnchorElement>("#downloadMobileConfig")!;
  const crtLink = document.querySelector<HTMLAnchorElement>("#downloadCrt")!;
  const copyButton = document.querySelector<HTMLButtonElement>("#copyPem")!;

  const applyLinks = () => {
    mobileConfigLink.href = certificateDownloadURL("mobileconfig");
    crtLink.href = certificateDownloadURL("crt");
    if (latestCertificateInfo) {
      const baseName = latestCertificateInfo.downloadBaseName;
      mobileConfigLink.setAttribute("download", `${baseName}.mobileconfig`);
      crtLink.setAttribute("download", `${baseName}.crt`);
    }
  };
  applyLinks();

  mobileConfigLink.addEventListener("click", applyLinks);
  crtLink.addEventListener("click", applyLinks);

  copyButton.addEventListener("click", async () => {
    if (!latestCertificateInfo) {
      setCertificateStatus("証明書情報がまだ取得できていません。");
      return;
    }
    try {
      await navigator.clipboard.writeText(latestCertificateInfo.pem);
      setCertificateStatus("PEM をクリップボードにコピーしました。");
    } catch (error) {
      setCertificateStatus(
        `コピーに失敗しました: ${(error as Error).message}`
      );
    }
  });

  void refreshCertificate();
}

async function refreshCertificate() {
  const summary = document.querySelector<HTMLDivElement>(
    "#certificateSummary"
  );
  if (!summary) return;
  try {
    const info = await fetchCertificateInfo();
    latestCertificateInfo = info;
    summary.innerHTML = renderCertificateSummary(info);
    const mobileConfigLink =
      document.querySelector<HTMLAnchorElement>("#downloadMobileConfig");
    const crtLink = document.querySelector<HTMLAnchorElement>("#downloadCrt");
    if (mobileConfigLink) {
      mobileConfigLink.setAttribute(
        "download",
        `${info.downloadBaseName}.mobileconfig`
      );
    }
    if (crtLink) {
      crtLink.setAttribute("download", `${info.downloadBaseName}.crt`);
    }
  } catch (error) {
    summary.textContent = `証明書情報の取得に失敗しました: ${
      (error as Error).message
    }`;
  }
}

function renderCertificateSummary(info: CertificateInfo): string {
  const dns = info.dnsNames.length > 0 ? info.dnsNames.join(", ") : "(なし)";
  const ips =
    info.ipAddresses.length > 0 ? info.ipAddresses.join(", ") : "(なし)";
  const notBefore = formatDate(info.notBefore);
  const notAfter = formatDate(info.notAfter);
  return `
    <dl class="cert-info">
      <dt>コモンネーム</dt>
      <dd>${escapeHtml(info.commonName)}</dd>
      <dt>DNS 名</dt>
      <dd>${escapeHtml(dns)}</dd>
      <dt>IP アドレス</dt>
      <dd>${escapeHtml(ips)}</dd>
      <dt>有効期間</dt>
      <dd>${escapeHtml(notBefore)} 〜 ${escapeHtml(notAfter)}</dd>
      <dt>SHA-256 フィンガープリント</dt>
      <dd class="mono">${escapeHtml(info.sha256Fingerprint)}</dd>
    </dl>
  `;
}

function formatDate(input?: string): string {
  if (!input) return "不明";
  const date = new Date(input);
  if (Number.isNaN(date.getTime())) return input;
  return date.toLocaleString();
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

async function refresh() {
  if (!getApiToken()) return;
  try {
    const pending = await apiFetch<PendingBackup[]>("/api/backup/pending");
    renderPending(pending);
    const status = await apiFetch<BackupStatus>("/api/backup/status");
    renderProgress(status);
    renderHistory(status.history);
  } catch (error) {
    setStatus(`API エラー: ${(error as Error).message}`);
  }
}

function renderPending(items: PendingBackup[]) {
  const container = document.querySelector<HTMLDivElement>("#pendingList")!;
  if (items.length === 0) {
    container.innerHTML = `<p class="muted">承認待ちはありません</p>`;
    return;
  }
  container.innerHTML = items
    .map(
      (item) => `
      <article class="pending-item">
        <div>
          <strong>${item.cameraName}</strong>
          <div class="muted">${item.ssid}</div>
        </div>
        <div class="actions">
          <button data-approve="${item.id}">バックアップ開始</button>
          <button data-skip="${item.id}" class="secondary">スキップ</button>
        </div>
      </article>`
    )
    .join("");

  container.querySelectorAll("[data-approve]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = (button as HTMLButtonElement).dataset.approve!;
      await apiFetch("/api/backup/approve", {
        method: "POST",
        body: JSON.stringify({ pendingId: id }),
      });
      await refresh();
    });
  });

  container.querySelectorAll("[data-skip]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = (button as HTMLButtonElement).dataset.skip!;
      await apiFetch("/api/backup/skip", {
        method: "POST",
        body: JSON.stringify({ pendingId: id }),
      });
      await refresh();
    });
  });
}

function renderProgress(status: BackupStatus) {
  const box = document.querySelector<HTMLPreElement>("#progressBox")!;
  if (!status.progress) {
    box.textContent = `状態: ${status.status}`;
    return;
  }
  box.textContent = JSON.stringify(status.progress, null, 2);
}

function renderHistory(history: BackupStatus["history"]) {
  const container = document.querySelector<HTMLDivElement>("#historyList")!;
  if (history.length === 0) {
    container.innerHTML = `<p class="muted">履歴はまだありません</p>`;
    return;
  }
  container.innerHTML = history
    .slice(0, 10)
    .map(
      (entry) => `
      <article class="history-item">
        <strong>${entry.cameraName}</strong>
        <div class="muted">新規 ${entry.copiedCount} / スキップ ${entry.skippedCount} / 失敗 ${entry.failedCount}</div>
      </article>`
    )
    .join("");
}

function handleDeepLink() {
  const params = new URLSearchParams(window.location.search);
  const pendingId = params.get("pendingBackup");
  if (pendingId) {
    setStatus(`通知から開きました: ${pendingId}`);
  }
}

renderShell();
handleDeepLink();
setInterval(() => {
  void refresh();
}, 5000);
void refresh();
