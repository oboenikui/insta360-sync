import {
  apiFetch,
  certificateDownloadURL,
  clearPushSubscriptions,
  collectPushDiagnostics,
  ensureServiceWorker,
  fetchCertificateInfo,
  fetchPushSubscriptions,
  getApiToken,
  getBaseURL,
  getLocalPushSubscription,
  getServiceWorkerDetails,
  getServiceWorkerStatusLabel,
  pingServiceWorker,
  registerPush,
  removePushSubscription,
  sendTestPush,
  setApiToken,
  setBaseURL,
  type CertificateInfo,
  type PushDeliveryResult,
  type PushDiagnosticEvent,
  type PushSubscription,
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
  folderStructureMode: string;
  vapidPublicKey: string;
  cameras: Array<{
    id: string;
    displayName: string;
    ssid: string;
    isEnabled: boolean;
    destinationRoot: string;
  }>;
};

type View = "main" | "settings";

let latestCertificateInfo: CertificateInfo | null = null;
const pushEventHistory: PushDiagnosticEvent[] = [];
const MAX_PUSH_EVENT_HISTORY = 8;

function init() {
  document.querySelector<HTMLButtonElement>("#openSettings")!.onclick = () => {
    showView("settings");
  };
  document.querySelector<HTMLButtonElement>("#closeSettings")!.onclick = () => {
    showView("main");
  };

  setupPairingSection();
  setupPushSection();
  setupCertificateSection();
  setupPendingList();
  setupServiceWorkerMessageBridge();
  void bootstrapServiceWorker();
}

async function bootstrapServiceWorker() {
  try {
    await ensureServiceWorker();
  } catch (error) {
    console.warn("Service worker bootstrap failed:", error);
  }
  await refreshServiceWorkerStatus();
}

function showView(view: View) {
  document.querySelector<HTMLDivElement>("#mainView")!.hidden = view !== "main";
  document.querySelector<HTMLDivElement>("#settingsView")!.hidden = view !== "settings";
  document.querySelector<HTMLButtonElement>("#openSettings")!.hidden = view !== "main";
  if (view === "settings") {
    void refreshCertificate();
    void refreshPushSubscriptions();
    void refreshServiceWorkerStatus();
    void refreshPushDiagnostics();
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
      void refreshPushSubscriptions();
      void refreshServiceWorkerStatus();
      void refreshPushDiagnostics();
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

function formatPushDeliveryResult(result: PushDeliveryResult): string {
  const lines: string[] = [];
  if (result.ok) {
    lines.push(`✓ ${result.endpointHost} …${result.endpointSuffix}`);
    lines.push(`HTTP ${result.statusCode ?? "?"}`);
  } else {
    lines.push(`✗ ${result.endpointHost} …${result.endpointSuffix}`);
    if (result.statusCode != null) {
      lines.push(`HTTP ${result.statusCode}${result.reason ? `: ${result.reason}` : ""}`);
    } else {
      lines.push(result.error ?? "失敗");
    }
  }
  if (result.payloadBytes != null) {
    lines.push(`payload: ${result.payloadBytes} bytes`);
  }
  if (result.apnsID) {
    lines.push(`apns-id: ${result.apnsID}`);
  }
  const headers = result.responseHeaders ?? {};
  for (const [key, value] of Object.entries(headers).sort(([a], [b]) => a.localeCompare(b))) {
    if (key.toLowerCase() === "apns-id") continue;
    lines.push(`${key}: ${value}`);
  }
  if (result.responseBody) {
    lines.push(`body: ${result.responseBody}`);
  } else if (result.ok) {
    lines.push("body: (empty)");
  }
  if (!result.ok && result.error) {
    lines.push(result.error);
  }
  return lines.join("\n");
}

function setStatus(message: string) {
  const el = document.querySelector<HTMLParagraphElement>("#pairingStatus");
  if (el) el.textContent = message;
}

function setPushStatus(message: string) {
  const el = document.querySelector<HTMLParagraphElement>("#pushStatus");
  if (el) el.textContent = message;
}

async function refreshServiceWorkerStatus() {
  const el = document.querySelector<HTMLParagraphElement>("#serviceWorkerStatus");
  if (!el) return;
  const label = await getServiceWorkerStatusLabel();
  el.textContent = `Service Worker: ${label}`;
}

function setupServiceWorkerMessageBridge() {
  if (!("serviceWorker" in navigator)) return;
  navigator.serviceWorker.addEventListener("message", (event) => {
    const data = event.data as PushDiagnosticEvent | undefined;
    if (!data?.type || !data.at) return;
    pushEventHistory.unshift(data);
    if (pushEventHistory.length > MAX_PUSH_EVENT_HISTORY) {
      pushEventHistory.length = MAX_PUSH_EVENT_HISTORY;
    }
    renderPushEventLog();
  });
}

function renderPushEventLog() {
  const container = document.querySelector<HTMLDivElement>("#pushEventLog");
  if (!container) return;
  if (pushEventHistory.length === 0) {
    container.textContent =
      "SW イベント: まだありません（テスト送信後もここが空なら push が SW に届いていません）";
    return;
  }

  replaceChildren(
    container,
    ...pushEventHistory.map((event) => {
      const time = formatDate(event.at);
      let text = `[${time}] ${event.type}`;
      if (event.message) text += `: ${event.message}`;
      if (event.rawData) text += ` (data: ${event.rawData})`;
      if (event.title) text += ` → ${event.title}`;
      if (event.error) text += ` — ${event.error}`;

      const className =
        event.type === "push-error"
          ? "event-error"
          : event.type === "push-received" || event.type === "notification-shown"
            ? "event-ok"
            : undefined;
      return el("div", { className, textContent: text });
    })
  );
}

async function refreshPushDiagnostics() {
  const container = document.querySelector<HTMLDivElement>("#pushDiagnostics");
  if (!container) return;

  const diagnostics = await collectPushDiagnostics();
  const swDetails = await getServiceWorkerDetails().catch(() => null);
  const entries: Array<{ term: string; value: string; valueClassName?: string }> = [
    {
      term: "通知許可",
      value: formatNotificationPermission(diagnostics.notificationPermission),
    },
    {
      term: "PushManager（ページ）",
      value: formatPushManagerAvailability(
        diagnostics.pushManagerInWindow,
        diagnostics.pushManagerOnRegistration
      ),
    },
    {
      term: "ページ origin",
      value: diagnostics.pageOrigin,
      valueClassName: "mono",
    },
  ];

  if (diagnostics.vapidSubject) {
    entries.push({
      term: "VAPID subject (sub)",
      value: diagnostics.vapidSubjectWarning
        ? `${diagnostics.vapidSubject}\n⚠ ${diagnostics.vapidSubjectWarning}`
        : `${diagnostics.vapidSubject} ✓`,
      valueClassName: "mono",
    });
  }

  if (swDetails) {
    entries.push(
      {
        term: "active SW",
        value: swDetails.activeScriptURL ?? "(なし)",
        valueClassName: "mono",
      },
      {
        term: "controller SW",
        value: swDetails.controllerScriptURL ?? "(なし)",
        valueClassName: "mono",
      }
    );
    if (swDetails.waitingScriptURL) {
      entries.push({
        term: "waiting SW",
        value: `${swDetails.waitingScriptURL} — 更新待ち。再読み込みしてください`,
        valueClassName: "mono",
      });
    }
  }

  if (diagnostics.localSubscription) {
    entries.push(
      {
        term: "このブラウザの購読",
        value: `…${diagnostics.localSubscription.endpointSuffix}`,
        valueClassName: "mono",
      },
      {
        term: "Mac 側に同一購読",
        value:
          diagnostics.serverHasLocalSubscription === null
            ? "確認不可（API トークン未設定など）"
            : diagnostics.serverHasLocalSubscription
              ? "あり ✓"
              : "なし ✗ — 「Push 通知を有効化」を再実行してください",
      }
    );
  } else {
    entries.push({
      term: "このブラウザの購読",
      value: "未登録 — 「Push 通知を有効化」を実行してください",
    });
  }

  if (diagnostics.serverSubscriptionCount !== null) {
    entries.push({
      term: "Mac 側の購読数",
      value: String(diagnostics.serverSubscriptionCount),
    });
  }

  appendDefinitionList(container, entries);
}

function formatNotificationPermission(permission: NotificationPermission | "unsupported"): string {
  switch (permission) {
    case "granted":
      return "許可 ✓";
    case "denied":
      return "拒否 ✗ — Safari 設定 → Web サイト → 通知 で許可してください";
    case "default":
      return "未設定 — 「Push 通知を有効化」で許可ダイアログを出してください";
    default:
      return "非対応";
  }
}

function formatPushManagerAvailability(inWindow: boolean, onRegistration: boolean): string {
  if (!inWindow) {
    return "非対応 ✗ — macOS 13+ / Safari 16+ が必要。SW 内では pushManager は使えません";
  }
  if (!onRegistration) {
    return "registration.pushManager なし ✗ — このコンテキストでは Web Push 不可";
  }
  return "利用可能 ✓（購読確認はページの Web インスペクタで）";
}

function setupPushSection() {
  document.querySelector<HTMLButtonElement>("#pingServiceWorker")!.onclick = async () => {
    try {
      setPushStatus("SW に ping 送信中…");
      const pong = await pingServiceWorker();
      setPushStatus(`SW pong ✓\n${pong.scriptURL}\n${formatDate(pong.at)}`);
      await refreshServiceWorkerStatus();
      await refreshPushDiagnostics();
    } catch (error) {
      setPushStatus(`SW ping 失敗: ${(error as Error).message}`);
    }
  };

  document.querySelector<HTMLButtonElement>("#sendTestPush")!.onclick = async () => {
    if (!getApiToken()) {
      setPushStatus("API トークンを設定してください");
      return;
    }
    try {
      setPushStatus("送信中…");
      const local = await getLocalPushSubscription();
      if (!local) {
        setPushStatus("このブラウザに Push 購読がありません。「Push 通知を有効化」を実行してください。");
        return;
      }
      const response = await sendTestPush(local.endpoint);
      const lines = response.results.map((result) => formatPushDeliveryResult(result));
      setPushStatus(
        lines.length > 0
          ? `${lines.join("\n\n")}\n\n※ 201 + apns-id は APNs 受理。push イベントは端末側で確認`
          : "購読が登録されていません"
      );
      await refreshPushSubscriptions();
      await refreshPushDiagnostics();
    } catch (error) {
      setPushStatus(`テスト送信失敗: ${(error as Error).message}`);
    }
  };

  document.querySelector<HTMLButtonElement>("#clearPushSubscriptions")!.onclick = async () => {
    if (!getApiToken()) {
      setPushStatus("API トークンを設定してください");
      return;
    }
    try {
      await clearPushSubscriptions();
      setPushStatus("すべての購読を削除しました");
      await refreshPushSubscriptions();
    } catch (error) {
      setPushStatus(`削除失敗: ${(error as Error).message}`);
    }
  };

  document.querySelector<HTMLDivElement>("#pushSubscriptionList")!.addEventListener("click", async (event) => {
    const target = (event.target as HTMLElement).closest<HTMLButtonElement>("button[data-endpoint]");
    if (!target?.dataset.endpoint) return;
    try {
      await removePushSubscription(target.dataset.endpoint);
      setPushStatus("購読を削除しました");
      await refreshPushSubscriptions();
    } catch (error) {
      setPushStatus(`削除失敗: ${(error as Error).message}`);
    }
  });
}

async function refreshPushSubscriptions() {
  const container = document.querySelector<HTMLDivElement>("#pushSubscriptionList");
  if (!container) return;
  if (!getApiToken()) {
    container.textContent = "API トークンを設定すると購読一覧を表示できます";
    return;
  }
  try {
    const subscriptions = await fetchPushSubscriptions();
    renderPushSubscriptions(container, subscriptions);
  } catch (error) {
    container.textContent = `購読一覧の取得に失敗: ${(error as Error).message}`;
  }
}

function renderPushSubscriptions(container: HTMLElement, subscriptions: PushSubscription[]) {
  if (subscriptions.length === 0) {
    appendMutedMessage(container, "登録済みの購読はありません。「Push 通知を有効化」で登録してください。");
    return;
  }

  replaceChildren(
    container,
    ...subscriptions.map((subscription) => {
      const created = formatDate(subscription.createdAt);
      const info = el("div", { className: "push-subscription-info" });
      info.append(el("strong", { textContent: subscription.endpointHost }));
      info.append(
        el("div", { className: "muted", textContent: `…${subscription.endpointSuffix} / 登録: ${created}` })
      );

      const removeButton = el("button", { className: "secondary", textContent: "削除" });
      removeButton.dataset.endpoint = subscription.endpoint;

      return el("article", { className: "push-subscription-item" }, info, removeButton);
    })
  );
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
