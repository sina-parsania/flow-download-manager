// SPDX-License-Identifier: GPL-3.0-or-later

const statusEl = document.getElementById("status");
const button = document.getElementById("send");

button.addEventListener("click", async () => {
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
    statusEl.textContent = result?.ok ? "Queued." : "Failed.";
  });
});
