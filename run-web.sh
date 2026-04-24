#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT_DIR}/build-emscripten"
PORT="${1:-8000}"

if [[ ! -f "${BUILD_DIR}/gzdoom.js" || ! -f "${BUILD_DIR}/gzdoom.wasm" ]]; then
  echo "Missing wasm build output. Run ${ROOT_DIR}/build-emscripten.sh first." >&2
  exit 1
fi

cat > "${BUILD_DIR}/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>GZDoom WebAssembly</title>
  <style>
    html, body { margin: 0; height: 100%; background: #111; color: #ddd; font-family: monospace; }
    #app { display: flex; flex-direction: column; height: 100%; }
    #toolbar {
      padding: 8px;
      border-bottom: 1px solid #333;
      display: flex;
      gap: 8px;
      align-items: center;
      flex-wrap: wrap;
      background: #171717;
    }
    #toolbar input[type="file"] { color: #ddd; }
    #toolbar button {
      background: #2a2a2a;
      color: #ddd;
      border: 1px solid #444;
      padding: 6px 10px;
      cursor: pointer;
    }
    #toolbar button:disabled { opacity: 0.5; cursor: default; }
    #toolbar .field-label { color: #9eb0c7; }
    #launch-cmd { min-width: 420px; flex: 1 1 420px; background: #101316; color: #d8e1ec; border: 1px solid #3c4958; padding: 6px; }
    #iwad-status { color: #8fc3ff; }
    #canvas {
      display: block;
      background: #000;
      width: 1280px;
      height: 720px;
      align-self: center;
      margin: 8px auto 0 auto;
    }
    #log {
      overflow: auto;
      padding: 8px;
      border-top: 1px solid #333;
      font-size: 12px;
      white-space: pre-wrap;
      min-height: 140px;
      flex: 1 1 auto;
    }
  </style>
</head>
<body>
  <div id="app">
    <div id="toolbar">
      <label class="field-label" for="iwad-file">IWAD:</label>
      <input id="iwad-file" type="file" accept=".wad,.WAD,.iwad,.IWAD,application/octet-stream" />
      <label class="field-label" for="mod-files">Mods:</label>
      <input id="mod-files" type="file" accept=".pk3,.PK3,.wad,.WAD,.zip,.ZIP,application/octet-stream" multiple />
      <label class="field-label" for="launch-cmd">Launch:</label>
      <input id="launch-cmd" type="text" value="-width 1280 -height 720 " />
      <button id="start-btn" disabled>Start</button>
      <span id="iwad-status">Pick a WAD file to start.</span>
    </div>
    <canvas id="canvas" width="1280" height="720"></canvas>
    <div id="log"></div>
  </div>
  <script>
    const appEl = document.getElementById("app");
    const toolbarEl = document.getElementById("toolbar");
    const logEl = document.getElementById("log");
    const canvasEl = document.getElementById("canvas");
    const iwadInput = document.getElementById("iwad-file");
    const modInput = document.getElementById("mod-files");
    const launchCmdInput = document.getElementById("launch-cmd");
    const startBtn = document.getElementById("start-btn");
    const iwadStatus = document.getElementById("iwad-status");

    const appendLog = (msg) => {
      const line = String(msg)
        .replace(/\x1b(?:\[[0-?]*[ -/]*[@-~]|[@-Z\\-_]|\][^\x07]*(?:\x07|\x1b\\))/g, "")
        .replace(/\x1b[78]/g, "")
        .replace(/\x07/g, "");
      
      // Strip progress bar pattern: [=====...]
      const filtered = line.replace(/\[[=.\s%\d/]*\]/g, "");
      const trimmed = filtered.trim();
      if (!trimmed) return;

      if (trimmed.includes("emscripten_set_main_loop_timing: Cannot set timing mode for main loop since a main loop does not exist!")) return;
      logEl.textContent += trimmed + "\n";
      logEl.scrollTop = logEl.scrollHeight;
      console.log(trimmed);
    };
    const setIwadStatus = (msg) => { iwadStatus.textContent = msg; appendLog(msg); };
    const IWAD_MOUNT_PATH = "/iwads/uploaded.wad";
    const MODS_MOUNT_DIR = "/mods";
    const PERSIST_ROOT = "/home/web_user";
    const LOG_MIN_HEIGHT = 140;

    const query = new URLSearchParams(location.search);
    const iwadFromQuery = query.get("iwad");
    const resetFs = query.get("resetfs") === "1";
    const baseAssets = [
      "gzdoom.pk3",
      "game_support.pk3",
      "game_widescreen_gfx.pk3",
      "lights.pk3",
      "brightmaps.pk3",
      "soundfonts/gzdoom.sf2",
      "fm_banks/GENMIDI.GS.wopl",
      "fm_banks/gs-by-papiezak-and-sneakernets.wopn"
    ];

    let selectedFile = null;
    let selectedMods = [];
    let launchReady = false;
    let runtimeReady = false;
    let gameStarted = false;
    let desiredCanvasWidth = 1280;
    let desiredCanvasHeight = 720;
    let pendingLaunchArgs = null;
    let startWithUploadedIwad = null;
    let persistSyncInFlight = false;
    let persistDirty = false;
    let persistAvailable = false;
    let persistInterval = null;
    let persistMounted = false;
    let persistInitialized = false;
    const updateStartButton = () => {
      startBtn.disabled = !(launchReady && selectedFile);
    };
    const applyCanvasLayout = () => {
      const availW = Math.max(1, window.innerWidth - 16);
      const reserved = toolbarEl.offsetHeight + LOG_MIN_HEIGHT + 16;
      const availH = Math.max(1, window.innerHeight - reserved);
      const scale = Math.min(1, availW / desiredCanvasWidth, availH / desiredCanvasHeight);
      const cssW = Math.max(1, Math.floor(desiredCanvasWidth * scale));
      const cssH = Math.max(1, Math.floor(desiredCanvasHeight * scale));
      canvasEl.style.width = String(cssW) + "px";
      canvasEl.style.height = String(cssH) + "px";
      canvasEl.style.aspectRatio = String(desiredCanvasWidth) + " / " + String(desiredCanvasHeight);
    };
    const updateDesiredCanvasSize = (w, h) => {
      if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) return;
      desiredCanvasWidth = w;
      desiredCanvasHeight = h;
      canvasEl.width = w;
      canvasEl.height = h;
      applyCanvasLayout();
    };
    const rmTreeSafe = (path) => {
      const node = FS.analyzePath(path);
      if (!node.exists) return;
      if (FS.isDir(node.object.mode)) {
        for (const name of FS.readdir(path)) {
          if (name === "." || name === "..") continue;
          rmTreeSafe(path + "/" + name);
        }
        try { FS.rmdir(path); } catch (_) {}
      } else {
        try { FS.unlink(path); } catch (_) {}
      }
    };
    const syncPersistentFs = (populate, reason) => new Promise((resolve) => {
      if (!persistAvailable) {
        resolve();
        return;
      }
      if (persistSyncInFlight) {
        if (!populate) persistDirty = true;
        resolve();
        return;
      }
      persistSyncInFlight = true;
      FS.syncfs(!!populate, (err) => {
        persistSyncInFlight = false;
        if (err) appendLog("Persistent FS sync failed (" + reason + "): " + err);
        const rerun = persistDirty;
        persistDirty = false;
        if (rerun && !populate) {
          syncPersistentFs(false, "queued-writeback").finally(resolve);
        } else {
          resolve();
        }
      });
    });
    const setupPersistentFs = async () => {
      if (typeof FS === "undefined" || typeof IDBFS === "undefined") {
        appendLog("Persistent FS unavailable (FS/IDBFS missing).");
        persistAvailable = false;
        return;
      }
      FS.mkdirTree(PERSIST_ROOT);
      if (!persistMounted) {
        try {
          FS.mount(IDBFS, {}, PERSIST_ROOT);
        } catch (_) {
          // Already mounted in this runtime.
        }
        persistMounted = true;
      }
      persistAvailable = true;
      await syncPersistentFs(true, "startup-load");

      ENV.HOME = PERSIST_ROOT;    // Saves and config go to IndexedDB (/home/web_user)
      ENV.DOOMWADDIR = "/";       // Engine looks for .pk3 files in the root

      FS.mkdirTree(PERSIST_ROOT + "/.config");
      FS.mkdirTree(PERSIST_ROOT + "/.local");
      FS.mkdirTree(PERSIST_ROOT + "/.local/share");
      if (resetFs && !persistInitialized) {
        rmTreeSafe(PERSIST_ROOT + "/.config/gzdoom");
        rmTreeSafe(PERSIST_ROOT + "/.local/share/gzdoom");
        await syncPersistentFs(false, "resetfs");
        appendLog("Reset requested: cleared persisted config/save paths.");
      }
      persistInitialized = true;
      if (!persistInterval) {
        persistInterval = setInterval(() => { syncPersistentFs(false, "periodic"); }, 3000);
      }
      addEventListener("beforeunload", () => { syncPersistentFs(false, "beforeunload"); });
      addEventListener("pagehide", () => { syncPersistentFs(false, "pagehide"); });
      addEventListener("visibilitychange", () => {
        if (document.visibilityState === "hidden") syncPersistentFs(false, "hidden");
      });
    };
    const tryStartGame = () => {
      if (gameStarted || !runtimeReady || !Array.isArray(pendingLaunchArgs)) return;
      gameStarted = true;
      appendLog("Starting GZDoom...");
      Module.callMain(pendingLaunchArgs);
    };
    const parseArgs = (line) => {
      const args = [];
      let cur = "";
      let quote = "";
      let escaping = false;
      for (let i = 0; i < line.length; i++) {
        const ch = line[i];
        if (escaping) {
          cur += ch;
          escaping = false;
          continue;
        }
        if (ch === "\\") {
          escaping = true;
          continue;
        }
        if (quote) {
          if (ch === quote) quote = "";
          else cur += ch;
          continue;
        }
        if (ch === "\"" || ch === "'") {
          quote = ch;
          continue;
        }
        if (/\s/.test(ch)) {
          if (cur.length) {
            args.push(cur);
            cur = "";
          }
          continue;
        }
        cur += ch;
      }
      if (escaping) cur += "\\";
      if (cur.length) args.push(cur);
      return args;
    };
    const stripArgWithValue = (args, opt) => {
      const out = [];
      for (let i = 0; i < args.length; i++) {
        if (args[i] === opt) {
          i++;
          continue;
        }
        out.push(args[i]);
      }
      return out;
    };
    const launchArgsWithFiles = (iwadPath, modPaths) => {
      let args = parseArgs(launchCmdInput.value || "");
      args = stripArgWithValue(args, "-iwad");
      const widthIndex = args.indexOf("-width");
      const heightIndex = args.indexOf("-height");
      if (widthIndex >= 0 && heightIndex >= 0 && args[widthIndex + 1] && args[heightIndex + 1]) {
        const w = parseInt(args[widthIndex + 1], 10);
        const h = parseInt(args[heightIndex + 1], 10);
        updateDesiredCanvasSize(w, h);
      }
      const full = ["-iwad", iwadPath, ...args];
      for (const modPath of modPaths) {
        full.push("-file", modPath);
      }
      appendLog("Launch args: " + full.join(" "));
      return full;
    };
    const sanitizeName = (name) => name.replace(/[^a-zA-Z0-9._-]/g, "_");
    appendLog("crossOriginIsolated=" + String(globalThis.crossOriginIsolated));
    addEventListener("resize", applyCanvasLayout);
    applyCanvasLayout();
    if (!globalThis.crossOriginIsolated) {
      setIwadStatus("Warning: crossOriginIsolated=false. Threaded wasm builds will abort. Use run-web.sh to serve with COOP/COEP headers.");
    }

    iwadInput.addEventListener("change", () => {
      selectedFile = iwadInput.files && iwadInput.files.length ? iwadInput.files[0] : null;
      if (selectedFile) {
        setIwadStatus("Selected upload: " + selectedFile.name);
      } else {
        setIwadStatus("Pick a WAD file to start.");
      }
      updateStartButton();
    });

    modInput.addEventListener("change", () => {
      selectedMods = modInput.files ? Array.from(modInput.files) : [];
      if (selectedMods.length > 0) {
        appendLog("Selected mods: " + selectedMods.map((f) => f.name).join(", "));
      }
    });

    startBtn.addEventListener("click", async () => {
      if (!startWithUploadedIwad || !selectedFile) return;
      startBtn.disabled = true;
      try {
        await startWithUploadedIwad(selectedFile);
      } catch (err) {
        const getExcMsg =
          (typeof getExceptionMessage === "function" && getExceptionMessage) ||
          (typeof Module !== "undefined" && Module && typeof Module.getExceptionMessage === "function" && Module.getExceptionMessage) ||
          null;
        const decExcRef =
          (typeof decrementExceptionRefcount === "function" && decrementExceptionRefcount) ||
          (typeof Module !== "undefined" && Module && typeof Module.decrementExceptionRefcount === "function" && Module.decrementExceptionRefcount) ||
          null;
        let detail = (err && (err.stack || err.message)) ? (err.stack || err.message) : String(err);
        try {
          if (getExcMsg) {
            const info = getExcMsg(err);
            if (Array.isArray(info)) {
              const typeName = info[0] || "CppException";
              const whatMsg = info[1] || "";
              detail += "\n" + typeName + (whatMsg ? (": " + whatMsg) : "");
            }
          }
        } catch (_) {}
        try {
          if (decExcRef) {
            decExcRef(err);
          }
        } catch (_) {}
        setIwadStatus("Failed to use uploaded IWAD: " + detail);
        startBtn.disabled = false;
      }
    });

    var Module = {
      canvas: canvasEl,
      locateFile: (path) => path,
      print: appendLog,
      printErr: appendLog,
      onAbort: (what) => appendLog("ABORT: " + what),
      webglContextAttributes: {
        alpha: false,
        premultipliedAlpha: false,
        antialias: false,
        depth: true,
        stencil: true,
        preserveDrawingBuffer: false
      },
      noInitialRun: true,
      arguments: [],
      preRun: [function () {
        FS.mkdirTree("/soundfonts");
        FS.mkdirTree("/fm_banks");
        FS.mkdirTree("/iwads");
        FS.mkdirTree(MODS_MOUNT_DIR);

        const dep = "fetch-gzdoom-assets-and-iwad";
        let depReleased = false;
        const releaseDep = () => {
          if (!depReleased) {
            depReleased = true;
            removeRunDependency(dep);
          }
        };
        addRunDependency(dep);

        const writeIwadBytes = (bytes) => {
          FS.writeFile(IWAD_MOUNT_PATH, bytes);
          return IWAD_MOUNT_PATH;
        };

        const fetchBaseAssets = Promise.all(baseAssets.map((path) =>
          fetch(path, { cache: "no-store" }).then((res) => {
            if (!res.ok) throw new Error(path + " -> HTTP " + res.status);
            return res.arrayBuffer();
          }).then((buf) => {
            FS.writeFile("/" + path, new Uint8Array(buf));
            appendLog("Loaded " + path);
          })
        ));

        startWithUploadedIwad = async (file) => {
          const bytes = new Uint8Array(await file.arrayBuffer());
          writeIwadBytes(bytes);
          rmTreeSafe(MODS_MOUNT_DIR);
          FS.mkdirTree(MODS_MOUNT_DIR);
          const modPaths = [];
          for (let i = 0; i < selectedMods.length; i++) {
            const mod = selectedMods[i];
            const safe = String(i).padStart(2, "0") + "_" + sanitizeName(mod.name || ("mod" + i + ".pk3"));
            const modPath = MODS_MOUNT_DIR + "/" + safe;
            FS.writeFile(modPath, new Uint8Array(await mod.arrayBuffer()));
            modPaths.push(modPath);
            appendLog("Loaded mod " + mod.name + " -> " + modPath);
          }
          pendingLaunchArgs = launchArgsWithFiles(IWAD_MOUNT_PATH, modPaths);
          setIwadStatus("Starting with uploaded IWAD (" + file.name + ") at " + IWAD_MOUNT_PATH);
          await syncPersistentFs(false, "launcher-write");
          releaseDep();
          tryStartGame();
        };

        Promise.all([fetchBaseAssets, setupPersistentFs()]).then(async () => {
          appendLog("Base assets loaded.");
          launchReady = true;

          if (iwadFromQuery) {
            try {
              const res = await fetch(iwadFromQuery, { cache: "no-store" });
              if (!res.ok) throw new Error("HTTP " + res.status);
              const bytes = new Uint8Array(await res.arrayBuffer());
              writeIwadBytes(bytes);
              pendingLaunchArgs = launchArgsWithFiles(IWAD_MOUNT_PATH, []);
              setIwadStatus("Starting with IWAD from URL query (?iwad=" + iwadFromQuery + ")");
              await syncPersistentFs(false, "launcher-write");
              releaseDep();
              tryStartGame();
              return;
            } catch (err) {
              setIwadStatus("Could not fetch ?iwad=" + iwadFromQuery + " (" + err.message + "). Upload a WAD file.");
            }
          } else {
            setIwadStatus("Base assets ready. Upload an IWAD and click Start.");
          }

          updateStartButton();
        }).catch((err) => {
          setIwadStatus("Asset load failed: " + err.message);
        });
      }],
      onRuntimeInitialized: function () {
        appendLog("Runtime initialized.");
        runtimeReady = true;
        applyCanvasLayout();
        if (typeof Module._gzdoom_autoseg_count === "function") {
          const buckets = ["areg", "creg", "freg", "greg", "yreg", "vreg"];
          const counts = buckets.map((name, idx) => name + "=" + Module._gzdoom_autoseg_count(idx));
          appendLog("AutoSeg counts: " + counts.join(", "));
        }
        tryStartGame();
      }
    };
  </script>
  <script src="gzdoom.js"></script>
</body>
</html>
HTML

echo "Serving ${BUILD_DIR} at http://127.0.0.1:${PORT}/index.html"
echo "Example with IWAD: http://127.0.0.1:${PORT}/index.html?iwad=doom2.wad"
BUILD_DIR_ENV="${BUILD_DIR}" PORT_ENV="${PORT}" python3 - <<'PY'
import os
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

build_dir = os.environ["BUILD_DIR_ENV"]
port = int(os.environ["PORT_ENV"])

class COIHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        # Required for SharedArrayBuffer / Emscripten pthreads.
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store, max-age=0, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

handler = partial(COIHandler, directory=build_dir)
httpd = ThreadingHTTPServer(("127.0.0.1", port), handler)
httpd.serve_forever()
PY
