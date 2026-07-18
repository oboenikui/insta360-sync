const SW_TAG = "[Insta360Sync SW]";

async function broadcast(payload) {
  const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  for (const client of clients) {
    client.postMessage(payload);
  }
}

function swLog(message, extra = {}) {
  console.log(SW_TAG, message, extra);
  void broadcast({
    type: "sw-log",
    message,
    at: new Date().toISOString(),
    ...extra,
  });
}

async function isDebugMode() {
  const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  return clients.some((client) => client.url.includes("debugPush=1"));
}

self.addEventListener("message", (event) => {
  if (event.data?.type === "ping") {
    const reply = {
      type: "sw-pong",
      at: new Date().toISOString(),
      scriptURL: self.location.href,
    };
    swLog("ping received", { scriptURL: self.location.href });
    if (event.source) {
      event.source.postMessage(reply);
    }
    void broadcast(reply);
  }
});

self.addEventListener("install", (event) => {
  swLog("install");
  event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", (event) => {
  swLog("activate");
  event.waitUntil(
    (async () => {
      await self.clients.claim();
      swLog("clients claimed");
    })()
  );
});

self.addEventListener("pushsubscriptionchange", (event) => {
  swLog("pushsubscriptionchange", { hasNewSubscription: !!event.newSubscription });
});

self.addEventListener("push", (event) => {
  event.waitUntil(handlePush(event));
});

async function handlePush(event) {
  const receivedAt = new Date().toISOString();
  let rawData = null;
  if (event.data) {
    try {
      rawData = event.data.text();
    } catch {
      rawData = "(unreadable)";
    }
  }

  swLog("push event received", { hasData: !!event.data, rawData });
  await broadcast({
    type: "push-received",
    at: receivedAt,
    hasData: !!event.data,
    rawData,
  });

  if (await isDebugMode()) {
    debugger;
  }

  let payload = { title: "Insta360 Sync", body: "新しい通知があります", pendingId: "" };
  if (event.data) {
    try {
      payload = { ...payload, ...event.data.json() };
    } catch {
      payload.body = rawData ?? payload.body;
    }
  }

  try {
    await self.registration.showNotification(payload.title, {
      body: payload.body,
      data: { pendingId: payload.pendingId ?? "" },
    });
    swLog("showNotification succeeded", { title: payload.title });
    await broadcast({
      type: "notification-shown",
      at: new Date().toISOString(),
      title: payload.title,
      body: payload.body,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    swLog("showNotification failed", { error: message });
    await broadcast({
      type: "push-error",
      at: new Date().toISOString(),
      error: message,
    });
    throw error;
  }
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const pendingId = event.notification.data?.pendingId;
  const target = pendingId ? `./?pendingBackup=${pendingId}` : "./";
  swLog("notificationclick", { pendingId: pendingId ?? "" });
  event.waitUntil(clients.openWindow(target));
});
