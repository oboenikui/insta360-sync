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

export async function registerPush(vapidPublicKey?: string): Promise<void> {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    throw new Error("このブラウザは Web Push に対応していません");
  }
  const publicKey = vapidPublicKey ?? (await fetchVapidPublicKey());
  const registration = await navigator.serviceWorker.register("./sw.js");
  await navigator.serviceWorker.ready;
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
