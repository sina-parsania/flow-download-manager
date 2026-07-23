// SPDX-License-Identifier: GPL-3.0-or-later

const statusEl = document.getElementById("status");
const sendButton = document.getElementById("send");
const pingButton = document.getElementById("ping");
const takeover = document.getElementById("takeover");

chrome.storage.local.get("downloadTakeoverEnabled").then((stored) => {
  takeover.checked = Boolean(stored.downloadTakeoverEnabled);
});

takeover.addEventListener("change", () => {
  chrome.storage.local.set({ downloadTakeoverEnabled: takeover.checked });
});

pingButton.addEventListener("click", () => {
  statusEl.textContent = "Checking…";
  chrome.runtime.sendMessage({ type: "ping" }, (result) => {
    if (chrome.runtime.lastError || !result?.ok) {
      statusEl.textContent =
        "Host unavailable. Build/open Download Manager, then run make install-chrome-native-host.";
      return;
    }
    statusEl.textContent = "Host OK.";
  });
});

sendButton.addEventListener("click", async () => {
  statusEl.textContent = "Sending…";
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.url) {
    statusEl.textContent = "No active tab URL.";
    return;
  }
  chrome.runtime.sendMessage({ type: "enqueueURLs", urls: [tab.url] }, (result) => {
    if (chrome.runtime.lastError) {
      statusEl.textContent = "Host unavailable.";
      return;
    }
    statusEl.textContent = result?.ok ? "Queued." : "Failed — host missing or rejected request.";
  });
});
