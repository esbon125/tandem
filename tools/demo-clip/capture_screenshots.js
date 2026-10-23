#!/usr/bin/env node
// Capturas de la página de la demo para el informe: Chrome headless, tema claro,
// 2x de densidad, estados de la demo en vivo forzados (red lenta para mostrar el
// buffer, pausa en un cuadro fijo) para que salgan iguales cada vez.
//
//   npm install puppeteer-core@23.11.1          (en un directorio aparte)
//   NODE_PATH=.../node_modules node capture_screenshots.js OUTDIR \
//       [--url https://esbon125.github.io/tandem/] [--resolve HOST=IP] [--upload VIDEO]
//
// --resolve hace falta solo desde la PC del relay: ahí *.ts.net resuelve a la
// tailnet y Chrome bloquea que una página pública le hable a una dirección local
// (Local Network Access). Con la IP pública del Funnel (dig @8.8.8.8 HOST) el
// tráfico va además por el mismo camino que el de un visitante.
// --upload agrega la captura de un video propio pasando por la normalización.
//
// Cada captura decodifica en la placa: la demo en vivo tiene que estar en línea.

const puppeteer = require("puppeteer-core");
const path = require("path");

const args = process.argv.slice(2);
const out = args[0];
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : dflt;
};
const URL = opt("--url", "https://esbon125.github.io/tandem/");
const RESOLVE = opt("--resolve");
const UPLOAD = opt("--upload");
const CHROME = opt("--chrome", "/usr/bin/google-chrome");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function open(browser, { width = 1100, height = 1400, scale = 2, kbps = 0 } = {}) {
  const page = await browser.newPage();
  await page.setViewport({ width, height, deviceScaleFactor: scale });
  await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: "light" }]);
  page.on("pageerror", (e) => console.error("pageerror:", e.message));
  await page.goto(URL, { waitUntil: "networkidle2" });
  await page.waitForFunction(() => document.querySelectorAll("#presets button").length > 0,
                             { timeout: 30000 });
  if (kbps) {
    const cdp = await page.target().createCDPSession();
    await cdp.send("Network.emulateNetworkConditions", { offline: false, latency: 80,
      downloadThroughput: kbps * 125, uploadThroughput: 10e6 });
  }
  return page;
}

const clickPreset = (page, i) => page.$$("#presets button").then((b) => b[i].click());
const waitStatus = (page, re, timeout = 120000) =>
  page.waitForFunction((src) => new RegExp(src).test(document.querySelector("#status").textContent),
                       { timeout, polling: 100 }, re.source);

async function pauseAt(page, seconds) {
  // freeze on a known frame so the capture is the same every time
  await page.evaluate(async (t) => {
    userPaused = true;
    $("play").textContent = "Reproducir";
    video.pause();
    video.currentTime = t;
    await new Promise((r) => video.addEventListener("seeked", r, { once: true }));
    const i = Math.floor(t * fps());
    $("seek").value = i;
    $("counter").textContent = `${i + 1} / ${frames.length}`;
    updateStats();
  }, seconds);
  await sleep(300);
}

async function shot(page, selector, name) {
  const el = await page.$(selector);
  const file = path.join(out, name);
  await el.screenshot({ path: file });
  console.log("wrote", file);
}

(async () => {
  const browser = await puppeteer.launch({
    executablePath: CHROME, headless: "new",
    args: ["--no-sandbox", "--autoplay-policy=no-user-gesture-required",
           ...(RESOLVE ? [`--host-resolver-rules=MAP ${RESOLVE.replace("=", " ")}`] : [])],
  });
  try {
    // 1. the page as a visitor first sees it
    let page = await open(browser);
    await page.screenshot({ path: path.join(out, "demo_vista_general.png") });
    console.log("wrote demo_vista_general.png");
    await page.close();

    // 2. a slow connection: the decoder keeps its pace, the page buffers
    page = await open(browser, { kbps: 500 });
    await clickPreset(page, 1);
    await page.waitForFunction(() => /cargando \d+ s de buffer/.test($("status").textContent) &&
                               avail() > 40 && board.fps, { timeout: 60000, polling: 200 });
    await sleep(1500);
    await shot(page, "#live", "demo_buffer_red_lenta.png");
    await page.close();

    // 3. playing in real time while frames still arrive, and 4. the finished run
    page = await open(browser);
    await clickPreset(page, 1);
    await page.waitForFunction(() => !waiting && video.currentTime > 4, { timeout: 60000 });
    await shot(page, "#live", "demo_reproduciendo.png");
    await waitStatus(page, /^Listo/);
    await sleep(500);
    await pauseAt(page, 10.0);
    await shot(page, "#live", "demo_resultado.png");
    await shot(page, "#livestats", "demo_metricas.png");
    await shot(page, "#madchart", "demo_grafico_mad.png");
    await page.close();

    // 5. an uploaded video through the normalization
    if (UPLOAD) {
      page = await open(browser);
      const input = await page.$("#file");
      await input.uploadFile(UPLOAD);
      await waitStatus(page, /^Listo/);
      await sleep(500);
      await pauseAt(page, 6.0);
      // the start message (source -> normalized) is replaced by the summary at the
      // end; put both in the caption area for the capture
      await page.evaluate(() => {
        const s = meta.source;
        $("status").textContent = `${s.width}×${s.height} ${s.codec} a ${s.frame_rate} fps → ` +
          `MPEG-2 352×288 a ${meta.frame_rate} fps, ${meta.pictures} cuadros. ` + $("status").textContent;
      });
      await shot(page, "#live", "demo_video_subido.png");
      await page.close();
    }

    // 6. the recorded, verified result: comparison video on a fixed frame
    page = await open(browser);
    await page.evaluate(async () => {
      // headless Chrome paints nothing for a <video> with controls that never
      // played: drop the controls, play an instant, then seek to the frame
      for (const v of document.querySelectorAll("figure video")) {
        v.controls = false; v.muted = true;
        await v.play(); v.pause();
        v.currentTime = 14;
        await new Promise((r) => v.addEventListener("seeked", r, { once: true }));
      }
    });
    await sleep(500);
    const figs = await page.$$("figure");
    await figs[1].screenshot({ path: path.join(out, "demo_comparacion_referencia.png") });
    console.log("wrote demo_comparacion_referencia.png");
    await page.close();

    // 7. phone width, mid-playback
    page = await open(browser, { width: 390, height: 1500, scale: 3 });
    await clickPreset(page, 0);
    await page.waitForFunction(() => !waiting && video.currentTime > 4, { timeout: 60000 });
    await page.screenshot({ path: path.join(out, "demo_movil.png"),
                            clip: { x: 0, y: 200, width: 390, height: 1250 } });
    console.log("wrote demo_movil.png");
    await page.close();
  } finally {
    await browser.close();
  }
})().catch((e) => { console.error(e); process.exit(1); });
