import {
  apiFetch,
  getApiToken,
  getBaseURL,
  registerPush,
  setApiToken,
  setBaseURL,
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
  };

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
