#!/usr/bin/env node
/**
 * 寒霜破甲工具 · macOS 构建脚本
 *
 *   node scripts/build.mjs            # 按当前机器架构构建
 *   node scripts/build.mjs --arch=x64 # 指定架构
 *   node scripts/build.mjs --skip-download   # 用 vendor/ 里已有的包
 *
 * 产物：dist/寒霜破甲工具.app
 *
 * 依赖包（自动下载，落在 vendor/）：
 *   - Electron 33.4.11 darwin-<arch>      （原 Windows 版同版本）
 *   - PowerShell 7.6.6 osx-<arch>         （随包自带，用户无需另装）
 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");
const VENDOR = path.join(ROOT, "vendor");
const DIST = path.join(ROOT, "dist");

const APP_NAME = "寒霜破甲工具";
const BUNDLE_ID = "com.hanshuang.pojia.desktop";
// 版本号只维护一处：package.json 的 version 写进 Info.plist，避免两边漂移
const VERSION = JSON.parse(
  fs.readFileSync(path.join(ROOT, "package.json"), "utf8"),
).version;
const ELECTRON_VERSION = "33.4.11";
const PWSH_VERSION = "7.6.6";

const argv = process.argv.slice(2);
const arg = (k, d) => {
  const hit = argv.find((a) => a.startsWith(`--${k}=`));
  return hit ? hit.split("=")[1] : d;
};
const has = (k) => argv.includes(`--${k}`);
const ARCH = arg("arch", process.arch === "arm64" ? "arm64" : "x64");

function log(...a) {
  console.log("[build]", ...a);
}
function needDir(d) {
  fs.mkdirSync(d, { recursive: true });
}
function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: "utf8", ...opts });
  if (r.status !== 0) {
    throw new Error(`${cmd} ${args.join(" ")} 失败: ${r.stdout || ""}${r.stderr || ""}`);
  }
  return r.stdout || "";
}

// ---------------------------------------------------------------- 下载依赖
/**
 * GitHub 在本机常被本地代理挡成 502，npmmirror 镜像又不收 PowerShell，
 * 所以这里做成「直连 -> 代理 -> 镜像」三级回退 + 断点续传重试。
 */
const ELECTRON_URLS = [
  `https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-darwin-${ARCH}.zip`,
  `https://npmmirror.com/mirrors/electron/${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-darwin-${ARCH}.zip`,
];
const PWSH_URLS = [
  `https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-osx-${ARCH}.tar.gz`,
];

function download(urls, out, verify) {
  if (fs.existsSync(out)) {
    try {
      verify(out);
      log("已存在，跳过下载:", path.basename(out));
      return;
    } catch {
      log("已存在但校验失败，重新下载:", path.basename(out));
    }
  }
  needDir(path.dirname(out));
  const tries = [["--noproxy", "*"], [], ["--proxy", process.env.HTTPS_PROXY || ""]].filter(
    (t) => t.length === 0 || t[1],
  );
  for (const url of urls) {
    for (const extra of tries) {
      for (let i = 0; i < 4; i++) {
        const args = ["-sSL", "--http1.1", "--max-time", "1800", "-C", "-", "-o", out, ...extra, url];
        spawnSync("curl", args, { encoding: "utf8" });
        try {
          verify(out);
          log("下载完成:", path.basename(out), `(${(fs.statSync(out).size / 1048576).toFixed(1)} MB)`);
          return;
        } catch {
          /* 续传重试 */
        }
      }
    }
  }
  throw new Error(`下载失败: ${urls[0]}`);
}

const zipOk = (f) => {
  const r = spawnSync("unzip", ["-t", f], { encoding: "utf8" });
  if (r.status !== 0) throw new Error("zip 损坏");
};
const tgzOk = (f) => {
  const r = spawnSync("gzip", ["-t", f], { encoding: "utf8" });
  if (r.status !== 0) throw new Error("tar.gz 损坏");
};

if (!has("skip-download")) {
  download(ELECTRON_URLS, path.join(VENDOR, `electron-darwin-${ARCH}.zip`), zipOk);
  download(PWSH_URLS, path.join(VENDOR, `pwsh-${ARCH}.tar.gz`), tgzOk);
}

// ---------------------------------------------------------------- 图标
function buildIcon() {
  const icns = path.join(ROOT, "assets", "icon.icns");
  if (fs.existsSync(icns)) return icns;
  const png = path.join(ROOT, "assets", "icon.png");
  if (!fs.existsSync(png)) throw new Error("缺少 assets/icon.png");
  const set = path.join(ROOT, "build", "icon.iconset");
  fs.rmSync(set, { recursive: true, force: true });
  needDir(set);
  for (const s of [16, 32, 64, 128, 256, 512, 1024]) {
    run("sips", ["-z", String(s), String(s), png, "--out", path.join(set, `icon_${s}x${s}.png`)]);
    if (s <= 512) {
      run("sips", [
        "-z", String(s * 2), String(s * 2), png,
        "--out", path.join(set, `icon_${s}x${s}@2x.png`),
      ]);
    }
  }
  run("iconutil", ["-c", "icns", set, "-o", icns]);
  log("生成图标:", icns);
  return icns;
}

// ---------------------------------------------------------------- app.asar
async function buildAsar() {
  const asar = require("@electron/asar");
  const src = path.join(ROOT, "app");
  const out = path.join(ROOT, "build", "app.asar");
  fs.rmSync(out, { force: true });
  needDir(path.dirname(out));
  await asar.createPackage(src, out);
  log("生成 app.asar:", `${(fs.statSync(out).size / 1048576).toFixed(1)} MB`);
  return out;
}

// ---------------------------------------------------------------- 组装 .app
function assemble(appAsar, icns) {
  const stage = path.join(ROOT, "build", `stage-${ARCH}`);
  fs.rmSync(stage, { recursive: true, force: true });
  needDir(stage);

  // 1) 解包 Electron
  run("unzip", ["-q", "-o", path.join(VENDOR, `electron-darwin-${ARCH}.zip`), "-d", stage]);
  const srcApp = path.join(stage, "Electron.app");
  if (!fs.existsSync(srcApp)) throw new Error("Electron 包结构异常：找不到 Electron.app");
  const app = path.join(stage, `${APP_NAME}.app`);
  fs.renameSync(srcApp, app);

  const contents = path.join(app, "Contents");
  const res = path.join(contents, "Resources");

  // 2) 换成我们的 asar（Electron 默认会加载 default_app.asar）
  fs.rmSync(path.join(res, "default_app.asar"), { force: true });
  fs.copyFileSync(appAsar, path.join(res, "app.asar"));

  // 3) 随包资源：安装脚本、提示词、技能库
  //
  // 守卫：resources/ 下若残留 app.asar / app-update.yml / elevate.exe（从上游 Windows
  // 便携版直接拷过来时会有），绝不能带进包里 —— 它会覆盖掉刚构建的 app.asar，
  // 表现为「改了主进程代码但界面行为一点没变」。直接删掉并告警。
  for (const junk of ["app.asar", "app-update.yml", "elevate.exe"]) {
    const jp = path.join(ROOT, "resources", junk);
    if (fs.existsSync(jp)) {
      fs.rmSync(jp, { force: true });
      log("已清除 resources/ 下的上游残留:", junk);
    }
  }
  const srcRes = path.join(ROOT, "resources");
  for (const e of fs.readdirSync(srcRes, { withFileTypes: true })) {
    if (e.name === "app.asar" || e.name === "app-update.yml" || e.name === "elevate.exe") continue;
    const from = path.join(srcRes, e.name);
    const to = path.join(res, e.name);
    if (e.isDirectory()) {
      fs.rmSync(to, { recursive: true, force: true });
      fs.cpSync(from, to, { recursive: true });
    } else {
      fs.copyFileSync(from, to);
    }
  }

  // 4) 随包 PowerShell（install*.ps1 的执行者；没有它用户得自己 brew install powershell）
  const pwshDir = path.join(res, "pwsh");
  fs.rmSync(pwshDir, { recursive: true, force: true });
  needDir(pwshDir);
  run("tar", ["-xzf", path.join(VENDOR, `pwsh-${ARCH}.tar.gz`), "-C", pwshDir]);
  try {
    fs.chmodSync(path.join(pwshDir, "pwsh"), 0o755);
  } catch {
    /* ignore */
  }
  // 清掉 macOS 的隔离属性，否则 Gatekeeper 会把每个 dylib 都拦一次
  spawnSync("xattr", ["-cr", pwshDir]);

  // 5) 图标
  for (const name of ["electron.icns", "app.icns"]) {
    fs.copyFileSync(icns, path.join(res, name));
  }

  // 6) Info.plist
  const plistPath = path.join(contents, "Info.plist");
  let plist = fs.readFileSync(plistPath, "utf8");
  const set = (key, val) => {
    const re = new RegExp(`(<key>${key}</key>\\s*<string>)[^<]*(</string>)`);
    plist = re.test(plist) ? plist.replace(re, `$1${val}$2`) : plist;
  };
  set("CFBundleDisplayName", APP_NAME);
  set("CFBundleName", APP_NAME);
  set("CFBundleIdentifier", BUNDLE_ID);
  set("CFBundleExecutable", APP_NAME);
  set("CFBundleIconFile", "electron.icns");
  set("CFBundleShortVersionString", VERSION);
  set("CFBundleVersion", VERSION);
  // 中文界面 + 简体中文优先
  plist = plist.replace(
    /(<key>CFBundleDevelopmentRegion<\/key>\s*<string>)[^<]*(<\/string>)/,
    "$1zh_CN$2",
  );
  if (!/CFBundleLocalizations/.test(plist)) {
    plist = plist.replace(
      "</dict>",
      "  <key>CFBundleLocalizations</key>\n  <array>\n    <string>zh_CN</string>\n    <string>en</string>\n  </array>\n</dict>",
    );
  }
  fs.writeFileSync(plistPath, plist);

  // 7) 可执行文件改名（与 CFBundleExecutable 对齐）
  const macos = path.join(contents, "MacOS");
  const oldBin = path.join(macos, "Electron");
  const newBin = path.join(macos, APP_NAME);
  if (fs.existsSync(oldBin)) fs.renameSync(oldBin, newBin);

  // 8) 去隔离 + ad-hoc 签名（不然 pwsh / Electron 的嵌套二进制会被 Gatekeeper 逐个拦）
  spawnSync("xattr", ["-cr", app]);
  const sign = spawnSync("codesign", ["--force", "--deep", "--sign", "-", app], {
    encoding: "utf8",
  });
  if (sign.status !== 0) log("警告：签名失败（不影响本地运行）:", sign.stderr?.trim());
  else log("ad-hoc 签名完成");

  // 9) 落到 dist/
  needDir(DIST);
  // 产物按架构命名。之前固定叫 <AppName>.app，连续构建 arm64/x64 会互相覆盖 ——
  // 实测构建 x64 时把刚做好的 arm64 产物整个盖掉了。
  const finalApp = path.join(DIST, `${APP_NAME}-${ARCH}.app`);
  fs.rmSync(finalApp, { recursive: true, force: true });
  /*
    必须用 ditto，不能用 fs.cpSync。
    macOS 的 .framework 里有一套标准相对符号链接（Foo.framework/Foo -> Versions/Current/Foo、
    Versions/Current -> A 等）。fs.cpSync 默认 verbatimSymlinks=false，会把相对链接
    「解析成绝对路径」—— 链接就指向了 build/stage-<arch>/…，一旦删掉 build/ 整个 app 就废；
    而且绝对链接指向 bundle 外，codesign 会报
    "unsealed contents present in the root directory of an embedded framework"。
    ditto 按原样保留符号链接，是 Apple 自己的拷贝工具。
  */
  const d = spawnSync("ditto", [app, finalApp], { encoding: "utf8" });
  if (d.status !== 0) throw new Error("ditto 拷贝失败: " + (d.stderr || ""));
  // 复核：不允许有任何符号链接指向构建暂存目录
  const links = spawnSync("bash", [
    "-c",
    `find ${JSON.stringify(finalApp)} -type l -exec sh -c 'printf "%s -> %s\\n" "$1" "$(readlink "$1")"' _ {} \\; 2>/dev/null | grep -c "build/stage" || true`,
  ], { encoding: "utf8" });
  const bad = Number((links.stdout || "0").trim());
  if (bad > 0) throw new Error(`产物里有 ${bad} 个符号链接指向构建暂存目录，ditto 未生效`);
  return finalApp;
}

// ---------------------------------------------------------------- main
log(`架构: ${ARCH}`);
const icns = buildIcon();
const asar = await buildAsar();
const out = assemble(asar, icns);
log("构建完成:", out);
log(`提示：产物按架构命名（${APP_NAME}-${ARCH}.app），arm64 与 x64 可共存于 dist/`);
log(`体积: ${(Number(run("du", ["-sk", out]).split(/\s+/)[0]) / 1024).toFixed(0)} MB`);
