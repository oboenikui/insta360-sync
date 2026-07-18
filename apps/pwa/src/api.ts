const API_TOKEN_KEY = "insta360-sync.apiToken";
const BASE_URL_KEY = "insta360-sync.baseUrl";

export function getApiToken(): string {
  return localStorage.getItem(API_TOKEN_KEY)?.trim() ?? "";
}

export function setApiToken(token: string) {
  localStorage.setItem(API_TOKEN_KEY, token.trim());
}

export function getBaseURL(): string {
  return localStorage.getItem(BASE_URL_KEY) ?? window.location.origin;
}

export function setBaseURL(url: string) {
  localStorage.setItem(BASE_URL_KEY, url.replace(/\/$/, ""));
}

export async function apiFetch<T>(path: string, init: RequestInit = {}): Promise<T> {
  const token = getApiToken();
  if (!token) {
    throw new Error("401 API トークン未設定");
  }
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${token}`);
  if (init.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  const response = await fetch(`${getBaseURL()}${path}`, { ...init, headers });
  if (!response.ok) {
    if (response.status === 401) {
      throw new Error("401 API トークン不一致");
    }
    throw new Error(`${response.status} ${response.statusText}`);
  }
  if (response.status === 204) {
    return undefined as T;
  }
  return (await response.json()) as T;
}

export function urlBase64ToUint8Array(base64String: string): Uint8Array {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64);
  const output = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i += 1) {
    output[i] = raw.charCodeAt(i);
  }
  return output;
}

export async function fetchVapidPublicKey(): Promise<string> {
  const response = await fetch(`${getBaseURL()}/api/public/vapid`);
  if (!response.ok) {
    throw new Error(`${response.status} VAPID 公開鍵の取得に失敗`);
  }
  const json = (await response.json()) as { vapidPublicKey?: string };
  if (!json.vapidPublicKey) {
    throw new Error("VAPID 公開鍵が空です");
  }
  return json.vapidPublicKey;
}

export type CertificateInfo = {
  commonName: string;
  dnsNames: string[];
  ipAddresses: string[];
  notBefore?: string;
  notAfter?: string;
  sha256Fingerprint: string;
  sha1Fingerprint: string;
  serialNumber?: string;
  downloadBaseName: string;
  pem: string;
};

export async function fetchCertificateInfo(): Promise<CertificateInfo> {
  const response = await fetch(`${getBaseURL()}/api/public/certificate`);
  if (!response.ok) {
    throw new Error(`${response.status} 証明書情報の取得に失敗`);
  }
  return (await response.json()) as CertificateInfo;
}

export function certificateDownloadURL(kind: "pem" | "crt" | "der" | "mobileconfig"): string {
  return `${getBaseURL()}/api/public/certificate.${kind}`;
}

let cachedServiceWorkerRegistration: ServiceWorkerRegistration | null = null;

export function isServiceWorkerSupported(): boolean {
  return "serviceWorker" in navigator;
}

export function isPushSupported(): boolean {
  return isServiceWorkerSupported() && "PushManager" in window;
}

export async function ensureServiceWorker(): Promise<ServiceWorkerRegistration> {
  if (!isServiceWorkerSupported()) {
    throw new Error("このブラウザは Service Worker に対応していません");
  }
  if (cachedServiceWorkerRegistration?.active) {
    return cachedServiceWorkerRegistration;
  }

  const existing = await navigator.serviceWorker.getRegistration();
  if (existing?.active) {
    cachedServiceWorkerRegistration = existing;
    return existing;
  }

  cachedServiceWorkerRegistration = await navigator.serviceWorker.register("./sw.js", {
    scope: "./",
    updateViaCache: "none",
  });
  await navigator.serviceWorker.ready;
  return cachedServiceWorkerRegistration;
}

export async function getServiceWorkerStatusLabel(): Promise<string> {
  if (!isServiceWorkerSupported()) {
    return "非対応（iPhone/iPad はホーム画面に追加した PWA が必要です）";
  }
  try {
    const registration = await ensureServiceWorker();
    const scriptURL = registration.active?.scriptURL ?? registration.installing?.scriptURL ?? "?";
    if (registration.active) {
      return `登録済み（${scriptURL}）`;
    }
    if (registration.installing) {
      return "インストール中…";
    }
    if (registration.waiting) {
      return "更新待ち（ページを再読み込みしてください）";
    }
    return "登録済み（有効化待ち）";
  } catch (error) {
    return `登録失敗: ${(error as Error).message}`;
  }
}

export type LocalPushSubscription = {
  endpoint: string;
  endpointHost: string;
  endpointSuffix: string;
};

export async function getLocalPushSubscription(): Promise<LocalPushSubscription | null> {
  if (!isPushSupported()) {
    return null;
  }
  const registration = await ensureServiceWorker();
  const subscription = await registration.pushManager.getSubscription();
  if (!subscription) {
    return null;
  }
  const endpoint = subscription.endpoint;
  let endpointHost = endpoint;
  try {
    endpointHost = new URL(endpoint).host;
  } catch {
    // keep full endpoint
  }
  return {
    endpoint,
    endpointHost,
    endpointSuffix: endpoint.slice(-24),
  };
}

export type PushDiagnosticEvent = {
  type: string;
  at: string;
  message?: string;
  error?: string;
  rawData?: string | null;
  title?: string;
  body?: string;
};

export type PushDiagnostics = {
  notificationPermission: NotificationPermission | "unsupported";
  pushManagerInWindow: boolean;
  pushManagerOnRegistration: boolean;
  localSubscription: LocalPushSubscription | null;
  serverHasLocalSubscription: boolean | null;
  serverSubscriptionCount: number | null;
  vapidSubject: string | null;
  vapidSubjectWarning: string | null;
  pageOrigin: string;
};

export async function collectPushDiagnostics(): Promise<PushDiagnostics> {
  const notificationPermission =
    typeof Notification !== "undefined" ? Notification.permission : "unsupported";
  const pushManagerInWindow = "PushManager" in window;
  let pushManagerOnRegistration = false;
  let localSubscription: LocalPushSubscription | null = null;

  if (isServiceWorkerSupported()) {
    try {
      const registration = await ensureServiceWorker();
      pushManagerOnRegistration = "pushManager" in registration && registration.pushManager != null;
      if (pushManagerOnRegistration) {
        localSubscription = await getLocalPushSubscription();
      }
    } catch {
      pushManagerOnRegistration = false;
    }
  }

  let serverHasLocalSubscription: boolean | null = null;
  let serverSubscriptionCount: number | null = null;
  let vapidSubject: string | null = null;
  let vapidSubjectWarning: string | null = null;
  if (getApiToken()) {
    try {
      const serverSubs = await fetchPushSubscriptions();
      serverSubscriptionCount = serverSubs.length;
      if (localSubscription) {
        serverHasLocalSubscription = serverSubs.some((sub) => sub.endpoint === localSubscription.endpoint);
      }
    } catch {
      serverHasLocalSubscription = null;
      serverSubscriptionCount = null;
    }
    try {
      const settings = await apiFetch<{
        vapidSubject?: string;
        vapidSubjectWarning?: string | null;
      }>("/api/settings");
      vapidSubject = settings.vapidSubject ?? null;
      vapidSubjectWarning = settings.vapidSubjectWarning ?? null;
    } catch {
      vapidSubject = null;
      vapidSubjectWarning = null;
    }
  }

  return {
    notificationPermission,
    pushManagerInWindow,
    pushManagerOnRegistration,
    localSubscription,
    serverHasLocalSubscription,
    serverSubscriptionCount,
    vapidSubject,
    vapidSubjectWarning,
    pageOrigin: window.location.origin,
  };
}

export async function registerPush(vapidPublicKey?: string): Promise<void> {
  if (!isPushSupported()) {
    throw new Error("このブラウザは Web Push に対応していません（iOS はホーム画面 PWA が必要）");
  }
  const publicKey = vapidPublicKey ?? (await fetchVapidPublicKey());
  const registration = await ensureServiceWorker();
  const subscription = await registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: urlBase64ToUint8Array(publicKey) as BufferSource,
  });
  const json = subscription.toJSON();
  await apiFetch("/api/push/subscribe", {
    method: "POST",
    body: JSON.stringify({
      endpoint: json.endpoint,
      keys: json.keys,
    }),
  });
}

export type PushSubscription = {
  endpoint: string;
  endpointHost: string;
  endpointSuffix: string;
  createdAt: string;
};

export type PushDeliveryResult = {
  endpointSuffix: string;
  endpointHost: string;
  ok: boolean;
  statusCode?: number;
  error?: string;
  apnsID?: string;
  reason?: string;
  responseBody?: string;
  responseHeaders?: Record<string, string>;
  payloadBytes?: number;
};

export async function fetchPushSubscriptions(): Promise<PushSubscription[]> {
  return apiFetch<PushSubscription[]>("/api/push/subscriptions");
}

export async function removePushSubscription(endpoint: string): Promise<void> {
  await apiFetch("/api/push/subscriptions", {
    method: "DELETE",
    body: JSON.stringify({ endpoint }),
  });
}

export async function clearPushSubscriptions(): Promise<void> {
  await apiFetch("/api/push/subscriptions", { method: "DELETE" });
}

export async function sendTestPush(endpoint?: string): Promise<{ results: PushDeliveryResult[] }> {
  return apiFetch<{ results: PushDeliveryResult[] }>("/api/push/test", {
    method: "POST",
    body: JSON.stringify(endpoint ? { endpoint } : {}),
  });
}

export type ServiceWorkerDetails = {
  activeScriptURL: string | null;
  waitingScriptURL: string | null;
  installingScriptURL: string | null;
  controllerScriptURL: string | null;
};

export async function getServiceWorkerDetails(): Promise<ServiceWorkerDetails> {
  const registration = await ensureServiceWorker();
  return {
    activeScriptURL: registration.active?.scriptURL ?? null,
    waitingScriptURL: registration.waiting?.scriptURL ?? null,
    installingScriptURL: registration.installing?.scriptURL ?? null,
    controllerScriptURL: navigator.serviceWorker.controller?.scriptURL ?? null,
  };
}

export async function pingServiceWorker(): Promise<{ scriptURL: string; at: string }> {
  const registration = await ensureServiceWorker();
  const worker = registration.active ?? registration.waiting ?? registration.installing;
  if (!worker) {
    throw new Error("active な Service Worker がありません");
  }

  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      navigator.serviceWorker.removeEventListener("message", onMessage);
      reject(new Error("SW ping がタイムアウトしました（デバッグ中の SW と active SW が一致しているか確認）"));
    }, 4000);

    const onMessage = (event: MessageEvent) => {
      const data = event.data as { type?: string; scriptURL?: string; at?: string } | undefined;
      if (data?.type !== "sw-pong") return;
      window.clearTimeout(timeout);
      navigator.serviceWorker.removeEventListener("message", onMessage);
      resolve({ scriptURL: data.scriptURL ?? "?", at: data.at ?? new Date().toISOString() });
    };

    navigator.serviceWorker.addEventListener("message", onMessage);
    worker.postMessage({ type: "ping" });
  });
}
