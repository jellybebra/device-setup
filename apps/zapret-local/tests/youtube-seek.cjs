// Live regression: exercise a real player outside its buffer without altering the Mac's network.
const { chromium } = require("playwright");
const { createConnection } = require("node:net");
const { once } = require("node:events");
const { setTimeout: delay } = require("node:timers/promises");

async function requireCudy() {
  const sock = createConnection("/var/run/com.jellybebra.zapret-cudy.sock");
  sock.setTimeout(3000, () => sock.destroy(new Error("Cudy status timed out")));
  try {
    await once(sock, "connect");
    sock.write('{"command":"status"}\n');
    let line = "";
    for await (const chunk of sock) {
      line += chunk;
      if (line.includes("\n")) {
        if (!JSON.parse(line.split("\n")[0]).running) throw new Error("Enable Cudy before testing");
        return;
      }
    }
    throw new Error("No Cudy status");
  } finally { sock.destroy(); }
}

// Seeks create a fresh playback session and can skip a stall near the first minute.
async function watchFirstMinute(page, media, quality) {
  let lastTime = 0, lastProgress = Date.now(), lastFrames = 0;
  const started = Date.now();
  while (Date.now() - started < 150000) {
    const state = await page.locator("video").evaluate(v => ({
      time: v.currentTime, frames: v.getVideoPlaybackQuality().totalVideoFrames,
      ready: v.readyState, height: v.videoHeight, duration: v.duration,
      buffered: Array.from({length: v.buffered.length}, (_, i) => [v.buffered.start(i), v.buffered.end(i)])
    }));
    if (state.duration > 0 && state.duration < 95) throw Error("Choose a video at least 95 seconds long");
    if (state.time > lastTime + 0.2 && state.frames > lastFrames) {
      lastTime = state.time;
      lastFrames = state.frames;
      lastProgress = Date.now();
    }
    if (Date.now() - lastProgress > 18000) {
      throw Error("Continuous playback stalled: " + JSON.stringify({state, ...media()}));
    }
    if (state.time >= 90 && state.ready >= 3 && Date.now() - lastProgress < 2000 &&
        media().bytes > 0 && (!quality || state.height === Number.parseInt(quality, 10))) {
      console.log("Continuous playback passed:", JSON.stringify({state, ...media()}));
      return;
    }
    await delay(500);
  }
  throw Error("Player did not reach 90 seconds at the requested quality");
}

async function trial() {
  const url = new URL(process.argv[2]);
  if (url.origin !== "https://www.youtube.com" || url.pathname !== "/watch")
    throw new Error("Expected a YouTube watch URL for a long non-live video");
  await requireCudy();
  // Use Playwright's separate Chrome for Testing, never the user's Chrome bundle or profile.
  const executablePath = process.env.CHROME_FOR_TESTING || chromium.executablePath();
  if (!executablePath.endsWith("/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"))
    throw new Error("Use a separate Chrome for Testing installation");
  const browser = await chromium.launch({ executablePath, headless: false, ignoreDefaultArgs: ["--enable-automation"], args: ["--no-proxy-server", "--mute-audio",
    "--autoplay-policy=no-user-gesture-required", "--disable-blink-features=AutomationControlled"] });
  try {
    const page = await browser.newPage({locale: "en-US"});
    const session = await page.context().newCDPSession(page);
    await session.send("Network.enable");
    await session.send("Network.setCacheDisabled", {cacheDisabled: true});
    const inflight = new Map();
    const mediaHosts = new Set();
    let generation = 0, mediaBytes = 0;
    session.on("Network.responseReceived", ({requestId, response}) => {
      const peer = new URL(response.url);
      if (peer.hostname.endsWith(".googlevideo.com") && peer.pathname === "/videoplayback" &&
          [200, 206].includes(response.status) && !response.fromDiskCache) {
        inflight.set(requestId, {generation, protocol: response.protocol});
        mediaHosts.add(peer.hostname);
      }
    });
    const protocols = new Set();
    session.on("Network.loadingFailed", ({requestId}) => inflight.delete(requestId));
    session.on("Network.loadingFinished", ({requestId, encodedDataLength}) => {
      const req = inflight.get(requestId);
      inflight.delete(requestId);
      if (req?.generation === generation && encodedDataLength > 16384) {
        mediaBytes += encodedDataLength;
        protocols.add(req.protocol);
      }
    });
    await page.goto(url.href, {waitUntil:"commit",timeout:30000});
    await page.waitForFunction(() => document.querySelector("video")?.currentTime > 1,
      null, {timeout:25000});
    const watch = process.argv.includes("--watch");
    const quality = process.argv.slice(3).find(arg => arg !== "--watch");
    if (quality) {
      if (!/^\d+p$/.test(quality)) throw new Error("Expected a quality label such as 1440p");
      await page.locator(".ytp-settings-button").click();
      await page.getByRole("menuitem").filter({hasText:/Quality/}).click();
      await page.getByRole("menuitemradio").filter({hasText:quality}).first().click();
    }
    if (watch) {
      await watchFirstMinute(page, () => ({bytes: mediaBytes, protocols: [...protocols], hosts: [...mediaHosts]}), quality);
      return;
    }
    for (const key of ["6","9","2"]) {
      const before = await page.locator("video").evaluate((v, digit) => ({
        target: v.duration * Number(digit) / 10,
        frames: v.getVideoPlaybackQuality().totalVideoFrames,
        buffered: Array.from({length:v.buffered.length}, (_, i) =>
          [v.buffered.start(i), v.buffered.end(i)])
      }), key);
      if (!Number.isFinite(before.target) || before.buffered.some(([a,b]) => a <= before.target && before.target <= b))
        throw new Error("Choose a longer video: seek must leave the current buffer");
      await page.locator("#movie_player").focus();
      generation++; mediaBytes = 0; protocols.clear();
      const started = Date.now();
      await page.keyboard.press(key);
      for (;;) {
        const state = await page.locator("video").evaluate(v => ({
          time:v.currentTime, frames:v.getVideoPlaybackQuality().totalVideoFrames, ready:v.readyState
        }));
        if (state.time >= before.target + 2 && state.time < before.target + 25 &&
            state.ready >= 3 && state.frames > before.frames + 12 && mediaBytes > 0) {
          console.log("Seek to %ds: resumed in %ss, %d media bytes (%s)",
            Math.floor(before.target), ((Date.now()-started)/1000).toFixed(1), mediaBytes, [...protocols]);
          break;
        }
        if (Date.now()-started > 25000) throw new Error(
          "Seek to " + before.target.toFixed(1) + "s stalled: " + JSON.stringify({state, mediaBytes}));
        await delay(250);
      }
    }
  } finally { await browser.close(); }
}
trial().catch(e => { console.error(e.message); process.exitCode = 1; });
