// Resolve "Download latest" to the newest release's macOS zip.
// Asset names carry the version, so a fixed /latest/download/<name> URL would break on the next release.
// Falls back to the releases/latest page if the API is unreachable or rate limited.
(() => {
  const REPO = "promptclickrun/bigvoice";
  const buttons = document.querySelectorAll("#download, [data-download]");
  const meta = document.getElementById("release-meta");

  const fmtSize = (bytes) => `${(bytes / 1e6).toFixed(1)} MB`;

  fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((release) => {
      const assets = release.assets || [];
      const zip = assets.find((a) => /macos.*\.zip$/i.test(a.name)) || assets.find((a) => /\.(zip|dmg)$/i.test(a.name));
      if (!zip) return;
      buttons.forEach((b) => {
        b.href = zip.browser_download_url;
        b.setAttribute("download", "");
        b.title = `${zip.name} · ${fmtSize(zip.size)}`;
      });
      if (meta) meta.textContent = `${release.tag_name} · ${fmtSize(zip.size)} · macOS 14+ · Apple Silicon`;
    })
    .catch(() => { /* keep the releases/latest fallback */ });

  // The mark is still unless sound is present. Here, "sound" is the cursor: the hero mark
  // opens into bars on hover over the download button, the one action that starts it.
  const mark = document.querySelector("[data-mark]");
  const primary = document.getElementById("download");
  // Arrival: the closed dot opens into the five-bar profile once, then holds still.
  if (mark) setTimeout(() => mark.classList.add("is-open"), 350);
  if (mark && primary) {
    const on = () => mark.classList.add("is-listening");
    const off = () => mark.classList.remove("is-listening");
    primary.addEventListener("mouseenter", on);
    primary.addEventListener("focus", on);
    primary.addEventListener("mouseleave", off);
    primary.addEventListener("blur", off);
  }
})();
