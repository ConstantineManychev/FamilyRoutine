'use strict';

const APP_PREFIX = '/app/';
const FALLBACK_LINK = '/app/notifications';
const OPEN_MESSAGE = 'open-link';
const APP_TITLE = 'Family Routine';

function safeLink(aLink)
{
  return typeof aLink === 'string' && aLink.startsWith(APP_PREFIX) && !aLink.includes('//') ? aLink : FALLBACK_LINK;
}

function readPayload(aEvent)
{
  try
  {
    return aEvent.data ? aEvent.data.json() : {};
  }
  catch (_)
  {
    return {};
  }
}

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (aEvent) => aEvent.waitUntil(self.clients.claim()));

self.addEventListener('push', (aEvent) =>
{
  const payload = readPayload(aEvent);
  const title = typeof payload.title === 'string' && payload.title ? payload.title : APP_TITLE;
  aEvent.waitUntil(self.registration.showNotification(title, {
    body: typeof payload.body === 'string' ? payload.body : '',
    tag: typeof payload.tag === 'string' ? payload.tag : undefined,
    icon: '/icons/Icon-192.png',
    badge: '/icons/Icon-maskable-192.png',
    data: { link: safeLink(payload.link) },
  }));
});

self.addEventListener('notificationclick', (aEvent) =>
{
  aEvent.notification.close();
  const link = safeLink(aEvent.notification.data && aEvent.notification.data.link);
  aEvent.waitUntil((async () =>
  {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const client = windows.find((aClient) => new URL(aClient.url).origin === self.location.origin);
    if (client)
    {
      client.postMessage({ type: OPEN_MESSAGE, link });
      return client.focus();
    }
    return self.clients.openWindow(link);
  })());
});
