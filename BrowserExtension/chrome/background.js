// SPDX-License-Identifier: GPL-3.0-or-later

const HOST_NAME = "org.downloadmanager.local.ChromeNativeHost";
const TAKEOVER_KEY = "downloadTakeoverEnabled";

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

export async function pingHost() {
  return sendNative({
    protocolVersion: 1,
    requestID: requestId(),
    command: "ping"
  });
}

function extractURLsFromText(text) {
  if (!text) {
    return [];
  }
  const matches = text.match(/\bhttps?:\/\/[^\s<>"']+/gi) || [];
  return [...new Set(matches.map((u) => u.replace(/[),.;]+$/g, "")))];
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
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
    chrome.contextMenus.create({
      id: "dm-send-selection",
      title: "Send links in selection to Download Manager",
      contexts: ["selection"]
    });
  });
  chrome.storage.local.set({ [TAKEOVER_KEY]: false });
});

async function markHostStatus(ok) {
  await chrome.action.setBadgeText({ text: ok ? "" : "!" });
  await chrome.action.setBadgeBackgroundColor({ color: ok ? "#0a0" : "#c00" });
  await chrome.action.setTitle({
    title: ok
      ? "Download Manager Companion"
      : "Native host missing — open Download Manager, then reinstall host manifest"
  });
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
    await markHostStatus(false);
    return;
  }
  try {
    const response = await enqueueURLs(urls, null);
    await markHostStatus(response?.ok !== false);
  } catch {
    await markHostStatus(false);
  }
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "ping") {
    pingHost()
      .then((response) => {
        markHostStatus(true);
        sendResponse({ ok: true, response });
      })
      .catch((error) => {
        markHostStatus(false);
        sendResponse({ ok: false, error: String(error) });
      });
    return true;
  }
  if (message?.type !== "enqueueURLs" || !Array.isArray(message.urls)) {
    return false;
  }
  enqueueURLs(message.urls, message.displayName ?? null)
    .then((response) => {
      markHostStatus(true);
      sendResponse({ ok: true, response });
    })
    .catch((error) => {
      markHostStatus(false);
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
    await enqueueURLs([item.url], item.filename || null);
    if (item.id != null) {
      await chrome.downloads.cancel(item.id);
    }
  } catch {
    await markHostStatus(false);
  }
});
