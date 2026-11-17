(() => {
  const stallTimeoutMs = 6500;
  const emptyBufferGraceMs = 500;
  const seekObservationMs = 75000;
  let pointerOnTimeline = false;
  let inputUntil = 0;
  let timer;
  const stopWatching = () => {
    clearInterval(timer);
    timer = undefined;
  };
  document.addEventListener("pointerdown", event => {
    pointerOnTimeline = event.isTrusted && Boolean(event.target.closest?.("#movie_player .ytp-progress-bar"));
    if (pointerOnTimeline) inputUntil = Date.now() + 3000;
  }, true);
  const release = () => {
    if (pointerOnTimeline) inputUntil = Date.now() + 3000;
    pointerOnTimeline = false;
  };
  document.addEventListener("pointerup", release, true);
  document.addEventListener("pointercancel", release, true);
  document.addEventListener("keydown", event => {
    if (!event.isTrusted || event.altKey || event.ctrlKey || event.metaKey ||
        event.target.closest?.("input,textarea,[contenteditable=true]")) return;
    if (/^[0-9jl]$|^(ArrowLeft|ArrowRight|Home|End)$/.test(event.key)) inputUntil = Date.now() + 3000;
  }, true);
  function reset() {
    pointerOnTimeline = false;
    inputUntil = 0;
    stopWatching();
  }
  function hasBufferedPosition(video) {
    const ranges = video.buffered;
    for (let i = 0; i < ranges.length; i++) {
      if (ranges.start(i) <= video.currentTime && video.currentTime < ranges.end(i)) return true;
    }
    return false;
  }
  function resumeAtPosition(player, videoId, seconds, url) {
    if (player.getVideoData?.()?.video_id !== videoId) return;
    // Keep an open comment editor intact when YouTube updates the watch view.
    if (document.activeElement?.closest("input,textarea,[contenteditable=true]") ||
        document.querySelector('ytd-commentbox [contenteditable="true"]')?.textContent.trim()) {
      player.loadVideoById?.({videoId, startSeconds: seconds});
      return;
    }
    const startTimeSeconds = Math.floor(seconds);
    const watchEndpoint = {videoId, startTimeSeconds};
    const playlistId = url.searchParams.get("list");
    if (playlistId) {
      watchEndpoint.playlistId = playlistId;
      const index = player.getPlaylistIndex?.();
      if (Number.isInteger(index) && index >= 0) watchEndpoint.index = index;
    }
    url.searchParams.set("t", startTimeSeconds + "s");
    const endpoint = {
      watchEndpoint,
      commandMetadata: {webCommandMetadata: {
        url: url.pathname + url.search,
        webPageType: "WEB_PAGE_TYPE_WATCH",
        rootVe: 3832
      }}
    };
    // Use the site's own timestamp navigation so the current watch document stays open.
    document.querySelector("ytd-app")?.dispatchEvent(new CustomEvent("yt-navigate", {
      bubbles: true, composed: true, detail: {endpoint}
    }));
  }
  document.addEventListener("yt-navigate-start", reset);
  window.addEventListener("pagehide", reset);
  document.addEventListener("seeking", event => {
    const video = event.target;
    if (!(video instanceof HTMLVideoElement) || (!pointerOnTimeline && Date.now() > inputUntil)) return;
    stopWatching();
    const player = video.closest("#movie_player");
    if (!player || location.pathname !== "/watch" || player.classList.contains("ad-showing") ||
        player.classList.contains("ytp-live") || !Number.isFinite(video.duration)) return;
    const url = new URL(location.href);
    const videoId = url.searchParams.get("v");
    if (!videoId) return;
    let lastTime = video.currentTime;
    // A short piece of buffered video can play before the first missing segment.
    const target = lastTime;
    let lastProgress = Date.now();
    const until = lastProgress + seekObservationMs;
    timer = setInterval(() => {
      if (location.href !== url.href || !video.isConnected || video.error || video.ended ||
          player.classList.contains("ad-showing") || Date.now() > until || video.currentTime > target + 25) {
        stopWatching();
        return;
      }
      if (video.paused || document.hidden || pointerOnTimeline || video.currentTime > lastTime + 0.15) {
        lastProgress = Date.now();
        lastTime = video.currentTime;
        return;
      }
      if (video.readyState >= HTMLMediaElement.HAVE_FUTURE_DATA) return;
      const waitMs = hasBufferedPosition(video) ? stallTimeoutMs : emptyBufferGraceMs;
      if (Date.now() - lastProgress < waitMs) return;
      reset();
      resumeAtPosition(player, videoId, video.currentTime, url);
    }, 250);
  }, true);
})();
