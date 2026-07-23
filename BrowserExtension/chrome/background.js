// SPDX-License-Identifier: GPL-3.0-or-later

const HOST_NAME = "org.downloadmanager.local.ChromeNativeHost";

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

export async function enqueueURLs(urls, displayName) {
  return sendNative({
    protocolVersion: 1,
    requestID: requestId(),
    command: "enqueueURLs",
    urls,
    displayName: displayName ?? null
  });
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "dm-send-link",
    title: "Send link to Download Manager",
    contexts: ["link"]
  });
  chrome.contextMenus.create({
    id: "dm-send-page",
    title: "Send page URL to Download Manager",
    contexts: ["page"]
  });
});

chrome.contextMenus.onClicked.addListener(async (info) => {
  const url = info.linkUrl || info.pageUrl;
  if (!url) {
    return;
  }
  try {
    await enqueueURLs([url], null);
  } catch {
    // Surface failures via badge only — never log full URLs.
    await chrome.action.setBadgeText({ text: "!" });
  }
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "enqueueURLs" || !Array.isArray(message.urls)) {
    return false;
  }
  enqueueURLs(message.urls, message.displayName ?? null)
    .then((response) => sendResponse({ ok: true, response }))
    .catch((error) => sendResponse({ ok: false, error: String(error) }));
  return true;
});
