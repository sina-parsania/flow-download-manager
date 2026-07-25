// SPDX-License-Identifier: GPL-3.0-or-later

const COOKIES_KEY = "includeCookiesEnabled";
const COOKIE_PERMISSION = { permissions: ["cookies"], origins: ["<all_urls>"] };

const statusEl = document.getElementById("status");
const sendButton = document.getElementById("send");
const pingButton = document.getElementById("ping");
const takeover = document.getElementById("takeover");
const cookies = document.getElementById("cookies");

chrome.storage.local.get("downloadTakeoverEnabled").then((stored) => {
  takeover.checked = Boolean(stored.downloadTakeoverEnabled);
});

Promise.all([
  chrome.storage.local.get(COOKIES_KEY),
  chrome.permissions.contains(COOKIE_PERMISSION)
]).then(([stored, granted]) => {
  cookies.checked = Boolean(stored[COOKIES_KEY]) && granted;
});

takeover.addEventListener("change", () => {
  chrome.storage.local.set({ downloadTakeoverEnabled: takeover.checked });
});

// The permission is requested from this click so Chrome sees a user gesture.
// Unchecking gives it back rather than leaving read-site-data granted forever.
cookies.addEventListener("change", async () => {
  if (!cookies.checked) {
    await chrome.storage.local.set({ [COOKIES_KEY]: false });
    await chrome.permissions.remove(COOKIE_PERMISSION);
    statusEl.textContent = "Cookies will not be sent.";
    return;
  }
  const granted = await chrome.permissions.request(COOKIE_PERMISSION);
  cookies.checked = granted;
  await chrome.storage.local.set({ [COOKIES_KEY]: granted });
  statusEl.textContent = granted
    ? "Cookies will be sent with single links."
    : "Permission declined — cookies will not be sent.";
});

pingButton.addEventListener("click", () => {
  statusEl.textContent = "Checking…";
  chrome.runtime.sendMessage({ type: "ping" }, (result) => {
    if (chrome.runtime.lastError || !result?.ok) {
      statusEl.textContent =
          "Host unavailable. Open Flow → Settings → Open Chrome with Companion, then try again.";
      return;
    }
    statusEl.textContent = "Host OK.";
  });
});

function describe(result) {
  const response = result?.response;
  if (chrome.runtime.lastError || !result?.ok || !response || response.ok === false) {
    return response?.message || "Failed — Flow is not reachable.";
  }
  if (response.message) {
    return response.message;
  }
  return "Queued.";
}

sendButton.addEventListener("click", async () => {
  statusEl.textContent = "Sending…";
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.url) {
    statusEl.textContent = "No active tab URL.";
    return;
  }
  chrome.runtime.sendMessage(
    { type: "enqueueURLs", urls: [tab.url], referer: tab.url },
    (result) => {
      statusEl.textContent = describe(result);
    }
  );
});
