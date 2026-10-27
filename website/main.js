// Detects the visitor's OS to highlight the right download and show the right modifier keys.
(function () {
  var RELEASE = "https://github.com/Meet-1010/SnapPaste/releases/latest/download/";
  var platforms = {
    mac: { label: "Download for macOS", meta: "Free · macOS 14+ · Apple silicon & Intel · 2 MB", file: "SnapPaste-macOS.dmg",
      icon: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M16.4 12.6c0-2.5 2-3.6 2.1-3.7-1.2-1.7-3-1.9-3.6-2-1.5-.2-3 .9-3.8.9-.8 0-2-.9-3.3-.9-1.7 0-3.3 1-4.2 2.6-1.8 3.1-.5 7.6 1.3 10.1.9 1.2 1.9 2.6 3.2 2.5 1.3-.1 1.8-.8 3.3-.8 1.6 0 2 .8 3.3.8 1.4 0 2.3-1.2 3.1-2.5 1-1.4 1.4-2.8 1.4-2.9-.1 0-2.8-1-2.8-4.1zM13.9 5.1c.7-.9 1.2-2 1-3.2-1 0-2.3.7-3 1.6-.7.8-1.2 2-1.1 3.1 1.2.1 2.3-.6 3.1-1.5z"/></svg>') },
    windows: { label: "Download for Windows", meta: "Free · Windows 10/11 · 64-bit · Beta", file: "SnapPaste-Windows-x64.exe",
      icon: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M3 5.5l7.4-1v7.1H3V5.5zm8.3-1.1L21 3v8.6h-9.7V4.4zM3 12.4h7.4v7.1L3 18.5v-6.1zm8.3 0H21V21l-9.7-1.4v-7.2z"/></svg>') },
    linux: { label: "Download for Linux", meta: "Free · x86_64 · Beta", file: "SnapPaste-Linux-x86_64.tar.gz",
      icon: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 2c-2.2 0-3.6 1.9-3.6 4.6 0 1.4.4 2.4.2 3.6-.3 1.6-2.6 3.3-3.3 5.9-.4 1.4.1 2.4.9 2.9-.2.7.1 1.4.9 1.7 1.2.5 2.3.1 3.3-.4.7-.3 1.4-.3 2.3-.3s1.6 0 2.3.3c1 .5 2.1.9 3.3.4.8-.3 1.1-1 .9-1.7.8-.5 1.3-1.5.9-2.9-.7-2.6-3-4.3-3.3-5.9-.2-1.2.2-2.2.2-3.6C15.6 3.9 14.2 2 12 2z"/></svg>') }
  };

  function detect() {
    var uaData = navigator.userAgentData && navigator.userAgentData.platform;
    var source = (uaData || navigator.platform || "") + " " + navigator.userAgent;
    if (/android|iphone|ipad|ipod/i.test(navigator.userAgent)) return null;
    if (/mac/i.test(source)) return "mac";
    if (/win/i.test(source)) return "windows";
    if (/linux|x11|cros/i.test(source)) return "linux";
    return null;
  }

  var os = detect();
  var isMac = os === "mac" || (!os && /mac|iphone|ipad/i.test(navigator.userAgent));

  // Show Ctrl-based shortcuts in prose for non-Mac visitors.
  if (!isMac) {
    document.querySelectorAll("kbd[data-mod]").forEach(function (k) { k.textContent = "Ctrl"; });
    document.querySelectorAll("kbd[data-mod-shift]").forEach(function (k) { k.textContent = "Ctrl+Shift+"; });
  }

  var button = document.getElementById("primary-download");
  var label = document.getElementById("primary-label");
  var meta = document.getElementById("primary-meta");
  if (os && platforms[os]) {
    var p = platforms[os];
    button.href = RELEASE + p.file;
    label.textContent = p.label;
    meta.textContent = p.meta;
    var icon = button.querySelector(".os-icon");
    icon.setAttribute("style", "--os-mask:url(\"" + p.icon + "\")");
    var card = document.querySelector('.dl[data-os="' + os + '"]');
    if (card) card.classList.add("current");
  } else {
    label.textContent = "Download SnapPaste";
    meta.textContent = "A desktop app for macOS, Windows and Linux. Open this page on your computer to download.";
  }
})();
