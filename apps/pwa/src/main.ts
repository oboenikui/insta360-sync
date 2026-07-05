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
import { appendDefinitionList, appendMutedMessage, el, replaceChildren } from "./dom";
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
    failures?: Array<{ path: string; error: string }>;
  }>;
};

type PublicSettings = {
  destinationRoot: string;
  folderStructureMode: string;
  vapidPublicKey: string;
  cameras: Array<{ id: string; displayName: string; ssid: string; isEnabled: boolean }>;
};

type View = "main" | "settings";

let latestCertificateInfo: CertificateInfo | null = null;

function init() {
  document.querySelector<HTMLButtonElement>("#openSettings")!.onclick = () => {
    showView("settings");
  };
  document.querySelector<HTMLButtonElement>("#closeSettings")!.onclick = () => {
    showView("main");
  };

  setupPairingSection();
  setupCertificateSection();
  setupPendingList();
}

function showView(view: View) {
  document.querySelector<HTMLDivElement>("#mainView")!.hidden = view !== "main";
  document.querySelector<HTMLDivElement>("#settingsView")!.hidden = view !== "settings";
  document.querySelector<HTMLButtonElement>("#openSettings")!.hidden = view !== "main";
  if (view === "settings") {
    void refreshCertificate();
  }
}

function setupPairingSection() {
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

function setupCertificateSection() {
  const crtLink = document.querySelector<HTMLAnchorElement>("#downloadCrt")!;
  const copyButton = document.querySelector<HTMLButtonElement>("#copyPem")!;

  const applyLinks = () => {
    crtLink.href = certificateDownloadURL("crt");
    if (latestCertificateInfo) {
      crtLink.setAttribute("download", `${latestCertificateInfo.downloadBaseName}.crt`);
    }
  };
  applyLinks();
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
      setCertificateStatus(`コピーに失敗しました: ${(error as Error).message}`);
    }
  });
}

async function refreshCertificate() {
  const summary = document.querySelector<HTMLDivElement>("#certificateSummary");
  if (!summary) return;
  try {
    const info = await fetchCertificateInfo();
    latestCertificateInfo = info;
    renderCertificateSummary(summary, info);
    const crtLink = document.querySelector<HTMLAnchorElement>("#downloadCrt");
    if (crtLink) {
      crtLink.setAttribute("download", `${info.downloadBaseName}.crt`);
    }
  } catch (error) {
    summary.textContent = `証明書情報の取得に失敗しました: ${(error as Error).message}`;
  }
}

function renderCertificateSummary(container: Element, info: CertificateInfo) {
  const dns = info.dnsNames.length > 0 ? info.dnsNames.join(", ") : "(なし)";
  const ips = info.ipAddresses.length > 0 ? info.ipAddresses.join(", ") : "(なし)";
  const notBefore = formatDate(info.notBefore);
  const notAfter = formatDate(info.notAfter);

  appendDefinitionList(container, [
    { term: "コモンネーム", value: info.commonName },
    { term: "DNS 名", value: dns },
    { term: "IP アドレス", value: ips },
    { term: "有効期間", value: `${notBefore} 〜 ${notAfter}` },
    { term: "SHA-256 フィンガープリント", value: info.sha256Fingerprint, valueClassName: "mono" },
  ]);
}

function formatDate(input?: string): string {
  if (!input) return "不明";
  const date = new Date(input);
  if (Number.isNaN(date.getTime())) return input;
  return date.toLocaleString();
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

function setupPendingList() {
  const container = document.querySelector<HTMLDivElement>("#pendingList");
  if (!container) return;

  container.addEventListener("click", async (event) => {
    const target = (event.target as HTMLElement).closest<HTMLButtonElement>("button[data-approve], button[data-skip]");
    if (!target) return;

    const approveId = target.dataset.approve;
    const skipId = target.dataset.skip;

    try {
      if (approveId) {
        await apiFetch("/api/backup/approve", {
          method: "POST",
          body: JSON.stringify({ pendingId: approveId }),
        });
      } else if (skipId) {
        await apiFetch("/api/backup/skip", {
          method: "POST",
          body: JSON.stringify({ pendingId: skipId }),
        });
      }
      await refresh();
    } catch (error) {
      setStatus(`操作に失敗しました: ${(error as Error).message}`);
    }
  });
}

function renderPending(items: PendingBackup[]) {
  const container = document.querySelector<HTMLDivElement>("#pendingList");
  if (!container) return;

  if (items.length === 0) {
    appendMutedMessage(container, "承認待ちはありません");
    return;
  }

  replaceChildren(
    container,
    ...items.map((item) => {
      const info = el("div");
      info.append(el("strong", { textContent: item.cameraName }));
      info.append(el("div", { className: "muted", textContent: item.ssid }));

      const approveButton = el("button", { textContent: "バックアップ開始" });
      approveButton.dataset.approve = item.id;

      const skipButton = el("button", { className: "secondary", textContent: "スキップ" });
      skipButton.dataset.skip = item.id;

      const actions = el("div", { className: "actions" }, approveButton, skipButton);

      return el("article", { className: "pending-item" }, info, actions);
    })
  );
}

function formatAppStatus(status: string): string {
  switch (status) {
    case "stopped":
      return "停止中";
    case "running":
      return "実行中";
    case "error":
      return "エラー";
    default:
      return status;
  }
}

function renderProgress(status: BackupStatus) {
  const box = document.querySelector<HTMLDivElement>("#progressBox");
  if (!box) return;
  if (!status.progress) {
    appendMutedMessage(box, `状態: ${formatAppStatus(status.status)}`);
    return;
  }

  const { cameraName, phase, completed, total, currentFile } = status.progress;
  const entries: Array<{ term: string; value: string; valueClassName?: string }> = [
    { term: "カメラ", value: cameraName },
    { term: "フェーズ", value: phase },
    { term: "進捗", value: total > 0 ? `${completed} / ${total} (${Math.round((completed / total) * 100)}%)` : `${completed}` },
  ];
  if (currentFile) {
    entries.push({ term: "ファイル", value: currentFile, valueClassName: "mono" });
  }

  const dl = el("dl", { className: "cert-info progress-info" });
  for (const { term, value, valueClassName } of entries) {
    dl.append(el("dt", { textContent: term }));
    dl.append(el("dd", { className: valueClassName, textContent: value }));
  }

  if (total > 0) {
    const fill = el("div", { className: "progress-bar-fill" });
    fill.style.width = `${Math.min(100, Math.round((completed / total) * 100))}%`;
    dl.append(el("div", { className: "progress-bar" }, fill));
  }

  replaceChildren(box, dl);
}

function renderHistory(history: BackupStatus["history"]) {
  const container = document.querySelector<HTMLDivElement>("#historyList");
  if (!container) return;

  if (history.length === 0) {
    appendMutedMessage(container, "履歴はまだありません");
    return;
  }

  replaceChildren(
    container,
    ...history.slice(0, 10).map((entry) => {
      const children: HTMLElement[] = [
        el("strong", { textContent: entry.cameraName }),
        el("div", {
          className: "muted",
          textContent: `新規 ${entry.copiedCount} / スキップ ${entry.skippedCount} / 失敗 ${entry.failedCount}`,
        }),
      ];

      if (entry.failures && entry.failures.length > 0) {
        children.push(
          el(
            "ul",
            { className: "failure-list" },
            ...entry.failures.map((failure) =>
              el(
                "li",
                { className: "failure-item" },
                el("span", { className: "failure-path mono", textContent: failure.path }),
                el("span", { className: "failure-error muted", textContent: failure.error })
              )
            )
          )
        );
      } else if (entry.message && !entry.message.startsWith("protocol=")) {
        children.push(el("div", { className: "failure-item mono", textContent: entry.message }));
      }

      return el("article", { className: "history-item" }, ...children);
    })
  );
}

function handleDeepLink() {
  const params = new URLSearchParams(window.location.search);
  const pendingId = params.get("pendingBackup");
  if (pendingId) {
    setStatus(`通知から開きました: ${pendingId}`);
  }
  if (!getApiToken()) {
    showView("settings");
  }
}

init();
handleDeepLink();
setInterval(() => {
  void refresh();
}, 5000);
void refresh();
