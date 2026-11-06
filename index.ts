#!/usr/bin/env bun
import { chmod, copyFile, lstat, mkdir, mkdtemp, readdir, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";
import { version } from "./package.json";
import {
  log,
  pack,
  resolveApp,
  selectApp,
  dumpCore,
  execute,
  cleanupRun,
  checkCatalystTools,
  checkCatalystRuntime,
  createCatalystApp,
  configureBundle,
  runDirectoryPrefix,
  prepareInjection,
  injectLibraries,
  runMachO,
  type InjectionPlan,
  type BundleConfiguration,
  type BundleInspection,
  type Recovery,
} from "./src";

const HELP_MESSAGE = `unipa: dump a running iOS app, recover its decrypted binaries, build an IPA

Usage:
  unipa [options]
  unipa --app /Applications/Example.app
  unipa --app /Applications/Example.app --core /tmp/example.core

Options:
  --app <path>                Reference app to process (default: choose from a list)
  --pid <pid>                 Use an existing process of the selected app
  --core <file>               Use an existing core instead of taking a new dump
  --wait-ms <ms>              Delay before dumping (default: 2000)
  --work-dir <dir>            Parent directory for runs (default: project's output directory)
  --base <0xaddress>          Select one verified runtime base for the main executable
  --core-for <path=core>      Core for another binary in the bundle (repeatable)
  --keep-extensions           Keep PlugIns/*.appex (default: removed from the output)
  --exclude-extension <name>  Remove one extension, e.g. Name.appex (repeatable)
  --inject <file>             Embed a local iOS dylib (repeatable; .gz and .xz supported)
  --identity <name>           codesign identity (default: ad-hoc)
  --bundle-id [id]            Set the output bundle ID (random generates a suffix)
  --bundle-name [name]        Set the output app name (random generates a suffix)
  --isolated-keychain         Use independent Keychain storage for --macos output
  --keychain-instance <name>  Select <name>.db (default: default.db)
  --macos                     Also build a standalone Mac Catalyst .app (experimental)
  --no-sign                   Skip signing (patching invalidates the original signature)
  --version                   Show version
  --help                      Show this help

sudo is used only for gcore and for changing ownership of the core file.
macOS only. Requires Python 3.10+. Set UNIPA_PYTHON to choose the interpreter.
`;

function readNonNegativeInteger(value: string | undefined, fallback: number, name: string): number {
  if (value === undefined) return fallback;
  const number = Number(value);
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(number)) throw new Error(`${name} must be a non-negative integer`);
  return number;
}

function parseOptions() {
  const argv = Bun.argv.slice(2);
  const args = argv.map((argument, index) => {
    const optionalValue = argument === "--bundle-id" || argument === "--bundle-name";
    const next = argv[index + 1];
    return optionalValue && (next === undefined || next.startsWith("-")) ? `${argument}=` : argument;
  });

  const { values } = parseArgs({
    args,
    strict: true,
    options: {
      app: { type: "string" },
      core: { type: "string" },
      pid: { type: "string" },
      "work-dir": { type: "string" },
      "wait-ms": { type: "string" },
      base: { type: "string" },
      identity: { type: "string" },
      inject: { type: "string", multiple: true },
      "core-for": { type: "string", multiple: true },
      "keep-extensions": { type: "boolean" },
      "exclude-extension": { type: "string", multiple: true },
      "no-sign": { type: "boolean" },
      macos: { type: "boolean" },
      "bundle-id": { type: "string" },
      "bundle-name": { type: "string" },
      "isolated-keychain": { type: "boolean" },
      "keychain-instance": { type: "string" },
      version: { type: "boolean" },
      help: { type: "boolean", short: "h" },
    },
  });

  if (values.help) {
    console.log(HELP_MESSAGE);
    return;
  }

  if (values.version) {
    console.log(`unipa ${version}`);
    return;
  }

  const waitMs = readNonNegativeInteger(values["wait-ms"], 2000, "--wait-ms");
  const pid = values.pid === undefined ? undefined : readNonNegativeInteger(values.pid, 0, "--pid");
  if (pid === 0) throw new Error("--pid cannot be zero");
  if (values.core && pid !== undefined) throw new Error("--core and --pid cannot be combined");
  if (values.base && !/^(0x[0-9a-f]+|\d+)$/i.test(values.base)) throw new Error("--base must be a valid address");
  if (values["no-sign"] && values.identity) throw new Error("--no-sign and --identity cannot be combined");
  if (values.macos && values["no-sign"]) throw new Error("--macos requires signing; remove --no-sign");
  if (values.macos && values["keep-extensions"]) throw new Error("--macos does not support retained iOS extensions; remove --keep-extensions");

  const bundleId = values["bundle-id"];
  if (bundleId && (bundleId.length > 255 || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$/.test(bundleId))) {
    throw new Error("--bundle-id must contain letters, digits, hyphens, and nonempty dot-separated components (maximum 255 characters)");
  }

  const bundleName = values["bundle-name"];
  if (bundleName && (!bundleName.trim() || bundleName.startsWith(".") || /[/\\:\x00-\x1f\x7f]/.test(bundleName))) {
    throw new Error("--bundle-name must be an app name without path separators or control characters");
  }

  const isolatedKeychain = values["isolated-keychain"] || values["keychain-instance"] !== undefined;
  if (isolatedKeychain && !values.macos) throw new Error("Isolated Keychain requires --macos");

  const keychainInstance = isolatedKeychain ? (values["keychain-instance"] ?? "default") : undefined;
  if (keychainInstance !== undefined && !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(keychainInstance)) {
    throw new Error("--keychain-instance must be 1–64 letters, digits, dots, underscores, or hyphens, starting with a letter or digit");
  }

  return {
    keychainInstance,
    bundleId: values["bundle-id"],
    bundleName: values["bundle-name"],
    appPath: values.app,
    corePath: values.core,
    pid,
    waitMs,
    workDir: values["work-dir"] ?? path.join(import.meta.dir, "output"),
    base: values.base,
    identity: values["no-sign"] ? undefined : (values.identity ?? "-"),
    macos: values.macos ?? false,
    keepExtensions: values["keep-extensions"] ?? false,
    excludedExtensions: values["exclude-extension"] ?? [],
    coreOverrides: values["core-for"] ?? [],
    injectedLibraries: values.inject ?? [],
  };
}

async function getExcludedExtensions(appPath: string, keepExtensions: boolean, requested: string[]): Promise<string[]> {
  let defaultExclusions: string[] = [];

  if (!keepExtensions) {
    try {
      defaultExclusions = (await readdir(path.join(appPath, "PlugIns"), { withFileTypes: true }))
        .filter((entry) => entry.isDirectory() && entry.name.endsWith(".appex"))
        .map((entry) => entry.name);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }

  const excluded = [...new Set([...defaultExclusions, ...requested])].sort();
  for (const extension of excluded) {
    if (path.basename(extension) !== extension || !extension.endsWith(".appex")) {
      throw new Error("--exclude-extension accepts only an .appex name inside PlugIns");
    }

    const info = await lstat(path.join(appPath, "PlugIns", extension));
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error(`Invalid extension: ${extension}`);
  }

  return excluded;
}

async function getCoreOverrides(appPath: string, encrypted: string[], excluded: string[], entries: string[]): Promise<Map<string, string>> {
  const extraCores = new Map<string, string>();

  for (const entry of entries) {
    const split = entry.indexOf("=");
    if (split < 1) throw new Error("--core-for expects bundle-relative-file=/path/dump.core");

    const relative = entry.slice(0, split);
    if (path.isAbsolute(relative) || relative !== path.normalize(relative) || relative.split(path.sep).includes("..")) {
      throw new Error("--core-for binary path must be relative and inside the bundle");
    }

    if (excluded.some((extension) => relative.startsWith(path.join("PlugIns", extension) + path.sep))) {
      throw new Error(`--core-for targets an excluded extension: ${relative}; use --keep-extensions to preserve it`);
    }

    if (!encrypted.includes(path.join(appPath, relative))) throw new Error(`Encrypted binary not found: ${relative}`);
    if (extraCores.has(relative)) throw new Error(`Duplicate --core-for: ${relative}`);

    const extra = await realpath(entry.slice(split + 1));
    if (!(await stat(extra)).isFile()) throw new Error(`Core path is not a file: ${extra}`);
    extraCores.set(relative, extra);
  }

  return extraCores;
}

async function createWorkspace(selected: string, sourcePath: string, workDir: string): Promise<string> {
  let outputRoot = path.resolve(workDir);
  const selectedRoot = await realpath(selected);
  const insideSource = (candidate: string) => [sourcePath, selectedRoot].some((root) => candidate === root || candidate.startsWith(root + path.sep));
  if (insideSource(outputRoot)) {
    throw new Error("Working directory cannot be inside the source .app");
  }

  let ancestor = outputRoot;
  const missing: string[] = [];
  while (true) {
    try {
      ancestor = await realpath(ancestor);
      break;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      missing.unshift(path.basename(ancestor));
      const parent = path.dirname(ancestor);
      if (parent === ancestor) throw error;
      ancestor = parent;
    }
  }

  outputRoot = path.join(ancestor, ...missing);
  if (insideSource(outputRoot)) throw new Error("Working directory resolves inside the source .app");
  await mkdir(outputRoot, { recursive: true, mode: 0o700 });
  const appName = path.basename(sourcePath, ".app");
  const workspace = await mkdtemp(path.join(outputRoot, runDirectoryPrefix(appName)));
  await chmod(workspace, 0o700);
  return workspace;
}

async function saveManifest(file: string, manifest: unknown): Promise<void> {
  const pending = `${file}.pending`;
  await writeFile(pending, JSON.stringify(manifest, null, 2) + "\n", { mode: 0o600 });
  await rename(pending, file);
}

async function getHostInfo() {
  const [version, build] = await Promise.all([execute(["/usr/bin/sw_vers", "-productVersion"]), execute(["/usr/bin/sw_vers", "-buildVersion"])]);
  return {
    platform: process.platform,
    version: version.trim(),
    build: build.trim(),
    arch: process.arch,
  };
}

async function main() {
  if (process.platform !== "darwin") {
    throw new Error("unipa is only supported on macOS.");
  }

  const options = parseOptions();
  if (!options) return;
  if (process.stdout.isTTY) console.clear();
  if (options.macos) await checkCatalystTools();

  const host = await getHostInfo();
  log.info(`Host: macOS ${host.version} (${host.build}), ${host.arch}`);

  const selected = options.appPath ? path.resolve(options.appPath) : await selectApp();
  const source = await resolveApp(selected);
  const excluded = await getExcludedExtensions(source.path, options.keepExtensions, options.excludedExtensions);
  const inspectionArgs = ["--app", source.path];
  for (const extension of excluded) {
    inspectionArgs.push("--exclude-extension", extension);
  }
  const sourceInspection = await runMachO<BundleInspection>("inspect-bundle", inspectionArgs);
  const encrypted = sourceInspection.encrypted;
  const extraCores = await getCoreOverrides(source.path, encrypted, excluded, options.coreOverrides);
  const workspace = await createWorkspace(selected, source.path, options.workDir);

  log.info(`Working directory: ${workspace}`);
  log.info(`App: ${source.name} (${source.bundle_id})`);

  let injection: InjectionPlan | undefined;
  if (options.injectedLibraries.length) {
    log.info("Preparing injected libraries…");
    injection = await prepareInjection(source.path, options.injectedLibraries, workspace);
  }

  if (options.macos) await checkCatalystRuntime(source.path, injection?.libraries);

  let app = path.join(workspace, "Payload", path.basename(source.path));
  await mkdir(path.dirname(app), { mode: 0o700 });
  await execute(["/usr/bin/ditto", source.path, app]);

  for (const extension of excluded) {
    log.warn(`Removing extension from the output copy: ${extension}`);
    await rm(path.join(app, "PlugIns", extension), { recursive: true });
  }

  await writeFile(
    path.join(workspace, "source.json"),
    JSON.stringify({ ...sourceInspection, selected, host, excluded_extensions: excluded }, null, 2),
    { mode: 0o600 },
  );

  let core: string | undefined;
  let generatedCore: string | undefined;
  let dumpPid: number | undefined;
  if (options.corePath) {
    core = await realpath(options.corePath);
    if (!(await stat(core)).isFile()) throw new Error("--core must be a file");
  } else if (encrypted.some((binary) => !extraCores.has(path.relative(source.path, binary)))) {
    core = path.join(workspace, "process.core");
    dumpPid = await dumpCore({
      appPath: selected,
      executable: source.executable,
      outputPath: core,
      pid: options.pid,
      waitMs: options.waitMs,
    });
    generatedCore = core;
  }

  const recoveries = [];
  for (const [index, binary] of encrypted.entries()) {
    const relative = path.relative(source.path, binary);
    const binaryCore = extraCores.get(relative) ?? core;
    if (!binaryCore) throw new Error(`Core dump required for encrypted binary: ${relative}`);

    const staged = path.join(app, relative);
    const artifacts = path.join(workspace, "recovery", String(index).padStart(3, "0"));
    log.info(`Check → extract → patch: ${relative}`);

    const args = ["--binary", staged, "--core", binaryCore, "--output-dir", artifacts];
    if (options.base && binary === source.executable) args.push("--base", options.base);

    let result: Recovery;
    try {
      result = await runMachO<Recovery>("recover", args);
    } catch (error) {
      throw new Error(
        `${relative}: ${error instanceof Error ? error.message : String(error)}\n` +
          `Analysis: ${path.join(artifacts, "analysis.json")}\n` +
          "For an extension in another process, provide --core-for or explicitly use --exclude-extension.",
      );
    }

    log.info(`Base ${result.selected.base}; region ${result.selected.address}`);
    log.info(`Disk SHA256: ${result.disk_sha256}`);
    log.info(`RAM  SHA256: ${result.selected.sha256}`);
    await copyFile(result.output, staged);
    log.success(`Recovered ${relative}`);
    recoveries.push({ ...result, binary: relative, core: binaryCore, artifacts });
  }

  if (!encrypted.length) {
    log.info("No encrypted Mach-O files found; no dump needed.");
  }

  let bundle: BundleConfiguration | null = null;
  if (options.bundleId !== undefined || options.bundleName !== undefined) {
    bundle = await configureBundle(app, { id: options.bundleId, name: options.bundleName });
    app = bundle.app;
    log.info(`Output app: ${bundle.name} (${bundle.bundle_id})`);
  }

  const identity = options.identity;
  const injections = injection ? await injectLibraries(app, injection) : [];
  for (const library of injections) {
    log.success(`Injected ${library.binary}`);
  }
  const ipa = await pack(app, workspace, identity, injections);
  let macos = null;
  if (options.macos) {
    log.info("Converting a separate copy to Mac Catalyst…");
    macos = await createCatalystApp(
      app,
      path.join(workspace, "macos"),
      identity!,
      options.keychainInstance,
      { id: options.bundleId !== undefined ? bundle!.bundle_id : undefined },
      injections.length > 0,
    );
    log.info(`Mac app: ${macos.name} (${macos.bundle_id})`);
    const count = macos.binaries.length;
    const label = count === 1 ? "binary" : "binaries";
    log.success(`Prepared and signed ${count} ${label}`);
  }

  const manifestPath = path.join(workspace, "manifest.json");
  const manifest = {
    source,
    host,
    core: core ?? null,
    dump_pid: dumpPid ?? null,
    cleanup: {
      status: "pending",
      app_closed: null,
      core_deleted: false,
      errors: [],
    },
    recoveries,
    excluded_extensions: excluded,
    injections,
    bundle,
    identity: identity ?? null,
    ipa,
    macos,
    created_at: new Date().toISOString(),
  };
  await saveManifest(manifestPath, manifest);

  const cleanup = await cleanupRun({ executable: source.executable, pid: dumpPid, generatedCore });
  await saveManifest(manifestPath, {
    ...manifest,
    cleanup: {
      status: cleanup.errors.length ? "failed" : "complete",
      app_closed: cleanup.appClosed,
      core_deleted: cleanup.coreDeleted,
      errors: cleanup.errors,
    },
  });

  if (cleanup.errors.length > 0) {
    process.exitCode = 1;
  }

  log.success(`IPA ready: ${ipa}`);
  macos && log.success(`macOS app ready: ${macos.app}`);
}

if (import.meta.main) {
  main().catch((error) => {
    log.error(error);
    process.exitCode = 1;
  });
}
