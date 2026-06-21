self.addEventListener("push", (event) => {
  let payload = { title: "Insta360 Sync", body: "新しい通知があります", pendingId: "" };
  if (event.data) {
    try {
      payload = { ...payload, ...event.data.json() };
    } catch {
      payload.body = event.data.text();
    }
  }

  event.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      data: { pendingId: payload.pendingId ?? "" },
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const pendingId = event.notification.data?.pendingId;
  const target = pendingId ? `./?pendingBackup=${pendingId}` : "./";
  event.waitUntil(clients.openWindow(target));
});
