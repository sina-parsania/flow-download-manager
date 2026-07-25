// SPDX-License-Identifier: GPL-3.0-or-later

const COOKIES_KEY = "includeCookiesEnabled";
const COOKIE_PERMISSION = { permissions: ["cookies"], origins: ["<all_urls>"] };

const statusEl = document.getElementById("status");
const sendButton = document.getElementById("send");
const pingButton = document.getElementById("ping");
const takeover = document.getElementById("takeover");
const cookies = document.getElementById("cookies");

function setStatus(text, kind) {
  statusEl.textContent = text;
  statusEl.classList.remove("ok", "error", "busy");
  if (kind) {
    statusEl.classList.add(kind);
  }
}

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
    setStatus("Cookies will not be sent.", null);
    return;
  }
  const granted = await chrome.permissions.request(COOKIE_PERMISSION);
  cookies.checked = granted;
  await chrome.storage.local.set({ [COOKIES_KEY]: granted });
  setStatus(
    granted ? "Cookies will be sent with single links." : "Permission declined — cookies off.",
    granted ? "ok" : "error"
  );
});

pingButton.addEventListener("click", () => {
  setStatus("Checking…", "busy");
  chrome.runtime.sendMessage({ type: "ping" }, (result) => {
    if (chrome.runtime.lastError) {
      setStatus(chrome.runtime.lastError.message, "error");
      return;
    }
    if (!result?.ok) {
      setStatus(result?.error || result?.response?.message || "Host unavailable.", "error");
      return;
    }
    setStatus("Connected to Flow.", "ok");
  });
});

function describe(result) {
  const response = result?.response;
  if (chrome.runtime.lastError) {
    return { text: chrome.runtime.lastError.message, kind: "error" };
  }
  if (!result?.ok || !response || response.ok === false) {
    return {
      text: result?.error || response?.message || "Failed — Flow is not reachable.",
      kind: "error"
    };
  }
  if (response.route === "appHandoff") {
    return {
      text: response.message || "Opened in Flow — click Add to start.",
      kind: "ok"
    };
  }
  return {
    text: response.message || "Queued in Flow.",
    kind: "ok"
  };
}

sendButton.addEventListener("click", async () => {
  setStatus("Sending…", "busy");
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.url) {
    setStatus("No active tab URL.", "error");
    return;
  }
  chrome.runtime.sendMessage(
    { type: "enqueueURLs", urls: [tab.url], referer: tab.url },
    (result) => {
      const outcome = describe(result);
      setStatus(outcome.text, outcome.kind);
    }
  );
});
