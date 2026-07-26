// SPDX-License-Identifier: GPL-3.0-or-later

const HOST_NAME = "org.downloadmanager.local.chrome_native_host";
const TAKEOVER_KEY = "downloadTakeoverEnabled";
const COOKIES_KEY = "includeCookiesEnabled";

// Envelope version this extension speaks. Version 2 added the `headers` array;
// version 1 is the URL-only envelope an older host still understands.
const PROTOCOL_VERSION = 2;
const LEGACY_PROTOCOL_VERSION = 1;

// RFC 6265 token / cookie-octet. A name or value carrying a control character,
// whitespace or a separator would let a page smuggle a second header through the
// hand-off. The native host validates again; a malformed pair there costs the
// whole header batch, so drop it here first.
const COOKIE_NAME_PATTERN = /^[A-Za-z0-9!#$%&'*+\-.^_`|~]+$/;
const COOKIE_VALUE_REJECT_PATTERN = /[\u0000-\u0020\u007f;,"\\]/;

function requestId() {
  if (globalThis.crypto?.randomUUID) {
    return crypto.randomUUID();
  }
  return `req-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

export function sendNative(message) {
  return new Promise((resolve, reject) => {
    try {
      chrome.runtime.sendNativeMessage(HOST_NAME, message, (response) => {
        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
          return;
        }
        resolve(response);
      });
    } catch (error) {
      reject(error);
    }
  });
}

export function cookieHeaderValue(cookies) {
  const parts = [];
  for (const cookie of cookies || []) {
    const name = cookie?.name;
    const value = cookie?.value;
    if (typeof name !== "string" || !COOKIE_NAME_PATTERN.test(name)) {
      continue;
    }
    if (typeof value !== "string" || COOKIE_VALUE_REJECT_PATTERN.test(value)) {
      continue;
    }
    parts.push(`${name}=${value}`);
  }
  return parts.join("; ");
}

async function cookiesEnabled() {
  const stored = await chrome.storage.local.get(COOKIES_KEY);
  return Boolean(stored[COOKIES_KEY]);
}

async function cookieHeaderFor(url) {
  if (!(await cookiesEnabled())) {
    return "";
  }
  try {
    const granted = await chrome.permissions.contains({
      permissions: ["cookies"],
      origins: [url]
    });
    if (!granted) {
      return "";
    }
    return cookieHeaderValue(await chrome.cookies.getAll({ url }));
  } catch {
    return "";
  }
}

// Reproduce the request context the browser itself would have sent. Cookies ride
// along only for a single URL: the engine applies one header set to the whole
// batch, so a mixed batch would replay one site's session against every other
// host in the list.
function originFor(url) {
  try {
    return new URL(url).origin;
  } catch {
    return "";
  }
}

export async function buildHeaders(urls, referer) {
  const headers = [];
  if (typeof referer === "string" && /^https?:\/\//i.test(referer)) {
    headers.push({ name: "Referer", value: referer });
  }
  if (urls.length === 1) {
    const origin = originFor(urls[0]);
    if (origin) {
      headers.push({ name: "Origin", value: origin });
    }
  }
  if (typeof navigator?.userAgent === "string" && navigator.userAgent.length > 0) {
    headers.push({ name: "User-Agent", value: navigator.userAgent });
  }
  if (urls.length === 1) {
    const cookie = await cookieHeaderFor(urls[0]);
    if (cookie) {
      headers.push({ name: "Cookie", value: cookie });
    }
  }
  return headers;
}

export async function enqueueURLs(urls, displayName, headers) {
  const message = {
    protocolVersion: PROTOCOL_VERSION,
    requestID: requestId(),
    command: "enqueueURLs",
    urls,
    displayName: displayName ?? null
  };
  if (headers?.length) {
    message.headers = headers;
  }
  const response = await sendNative(message);
  if (response?.ok === false && response?.errorCode === "unsupportedProtocolVersion") {
    // Older host installed alongside a newer extension — retry without headers.
    return sendNative({
      protocolVersion: LEGACY_PROTOCOL_VERSION,
      requestID: requestId(),
      command: "enqueueURLs",
      urls,
      displayName: displayName ?? null
    });
  }
  return response;
}

export async function sendLinks(urls, displayName, referer) {
  return enqueueURLs(urls, displayName, await buildHeaders(urls, referer));
}

export async function pingHost() {
  const response = await sendNative({
    protocolVersion: PROTOCOL_VERSION,
    requestID: requestId(),
    command: "ping"
  });
  if (response?.ok === false && response?.errorCode === "unsupportedProtocolVersion") {
    return sendNative({
      protocolVersion: LEGACY_PROTOCOL_VERSION,
      requestID: requestId(),
      command: "ping"
    });
  }
  return response;
}

function extractURLsFromText(text) {
  if (!text) {
    return [];
  }
  const matches = text.match(/\bhttps?:\/\/[^\s<>"']+/gi) || [];
  return [...new Set(matches.map((u) => u.replace(/[),.;]+$/g, "")))];
}

function ensureContextMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: "dm-send-link",
      title: "Send link to Flow DM",
      contexts: ["link"]
    });
    chrome.contextMenus.create({
      id: "dm-send-page",
      title: "Send page URL to Flow DM",
      contexts: ["page"]
    });
    chrome.contextMenus.create({
      id: "dm-send-selection",
      title: "Send links in selection to Flow DM",
      contexts: ["selection"]
    });
  });
}

chrome.runtime.onInstalled.addListener((details) => {
  ensureContextMenus();
  if (details.reason === "install") {
    chrome.storage.local.set({ [TAKEOVER_KEY]: false });
  }
});

chrome.runtime.onStartup.addListener(() => {
  ensureContextMenus();
});

ensureContextMenus();

// "Handed to the app" is neither success nor failure: the download is sitting in
// Flow's Add sheet waiting for a click, and the user has to be told.
export function statusForResponse(response) {
  if (!response || response.ok === false) {
    return "error";
  }
  return response.route === "appHandoff" ? "handoff" : "ok";
}

const STATUS_PRESENTATION = {
  ok: { text: "", color: "#0a0", title: "Flow DM" },
  handoff: {
    text: "…",
    color: "#c60",
    title: "Opened in Flow — click Add in Flow to start the download"
  },
  error: {
    text: "!",
    color: "#c00",
    title: "Flow unavailable — open Flow Download Manager, then reinstall the host manifest"
  }
};

async function markHostStatus(state) {
  const presentation = STATUS_PRESENTATION[state] || STATUS_PRESENTATION.error;
  await chrome.action.setBadgeText({ text: presentation.text });
  await chrome.action.setBadgeBackgroundColor({ color: presentation.color });
  await chrome.action.setTitle({ title: presentation.title });
}

chrome.contextMenus.onClicked.addListener(async (info) => {
  let urls = [];
  if (info.menuItemId === "dm-send-selection") {
    urls = extractURLsFromText(info.selectionText || "");
  } else {
    const url = info.linkUrl || info.pageUrl;
    if (url) {
      urls = [url];
    }
  }
  if (urls.length === 0) {
    await markHostStatus("error");
    return;
  }
  try {
    const response = await sendLinks(urls, null, info.pageUrl);
    await markHostStatus(statusForResponse(response));
  } catch {
    await markHostStatus("error");
  }
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "ping") {
    pingHost()
      .then((response) => {
        markHostStatus(response?.ok === false ? "error" : "ok");
        sendResponse({ ok: response?.ok !== false, response });
      })
      .catch((error) => {
        markHostStatus("error");
        sendResponse({ ok: false, error: String(error) });
      });
    return true;
  }
  if (message?.type !== "enqueueURLs" || !Array.isArray(message.urls)) {
    return false;
  }
  sendLinks(message.urls, message.displayName ?? null, message.referer ?? null)
    .then((response) => {
      markHostStatus(statusForResponse(response));
      sendResponse({ ok: response?.ok !== false, response });
    })
    .catch((error) => {
      markHostStatus("error");
      sendResponse({ ok: false, error: String(error) });
    });
  return true;
});

// FR-BRW-004: takeover stays off unless explicitly enabled in storage.
chrome.downloads?.onCreated?.addListener(async (item) => {
  const stored = await chrome.storage.local.get(TAKEOVER_KEY);
  if (!stored[TAKEOVER_KEY]) {
    return;
  }
  if (!item.url || item.url.startsWith("blob:") || item.url.startsWith("filesystem:")) {
    return;
  }
  try {
    const response = await sendLinks([item.url], item.filename || null, item.referrer || null);
    if (!response || response.ok === false) {
      // Leave Chrome's own download running rather than cancelling into nothing.
      await markHostStatus("error");
      return;
    }
    if (item.id != null) {
      await chrome.downloads.cancel(item.id);
    }
    await markHostStatus(statusForResponse(response));
  } catch {
    await markHostStatus("error");
  }
});
