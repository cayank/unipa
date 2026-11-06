import { lstat, readFile, readdir, unlink } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";
import { log } from "../src/logger";
import { runDirectoryPrefix } from "../src/filenames";

const HELP_MESSAGE = `Delete generated core dumps while keeping IPAs and recovery reports.

Usage:
  bun run clean:cores
  bun run clean:cores --dry-run
  bun run clean:cores --work-dir /path/to/output

Only regular process.core files directly inside recognized run folders are removed.
Symlinks are skipped. The default directory is this project's output folder.`;

async function isAppRun(folder: string): Promise<boolean> {
  const name = path.basename(folder);
  if (!/^.+-[A-Za-z0-9]{6}$/.test(name)) return false;

  const sourceFile = path.join(folder, "source.json");
  if (!(await lstat(sourceFile)).isFile()) return false;

  let source;
  try {
    source = JSON.parse(await readFile(sourceFile, "utf-8"));
  } catch (error) {
    if (error instanceof SyntaxError) return false;
    throw error;
  }

  if (typeof source?.path !== "string" || typeof source.name !== "string" || !source.name.trim()) return false;
  const prefix = runDirectoryPrefix(source.name);
  return name.startsWith(prefix) && /^[A-Za-z0-9]{6}$/.test(name.slice(prefix.length));
}

function formatSize(bytes: number): string {
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];

  let unit = 0;
  while (bytes >= 1024 && unit < units.length - 1) {
    bytes /= 1024;
    unit++;
  }

  return `${bytes.toFixed(unit === 0 ? 0 : 2)} ${units[unit]}`;
}

async function main(): Promise<void> {
  if (process.platform !== "darwin") throw new Error("unipa is only supported on macOS.");

  const { values: options } = parseArgs({
    args: Bun.argv.slice(2),
    strict: true,
    options: {
      "work-dir": { type: "string" },
      "dry-run": { type: "boolean" },
      help: { type: "boolean", short: "h" },
    },
  });

  if (options.help) {
    console.log(HELP_MESSAGE);
    return;
  }

  const outputDir = path.resolve(options["work-dir"] ?? path.join(import.meta.dir, "../output"));
  const dryRun = options["dry-run"] ?? false;

  let runFolders;
  try {
    runFolders = await readdir(outputDir, { withFileTypes: true });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    log.info(`No output directory found: ${outputDir}`);
    return;
  }

  let fileCount = 0;
  let totalBytes = 0;
  let errorCount = 0;
  const action = dryRun ? "Would delete" : "Deleted";

  for (const folder of runFolders) {
    if (!folder.isDirectory()) continue;

    const runPath = path.join(outputDir, folder.name);
    const corePath = path.join(runPath, "process.core");
    try {
      if (!(await isAppRun(runPath))) continue;
      const info = await lstat(corePath);
      if (!info.isFile()) continue;

      if (!dryRun) await unlink(corePath);

      log.info(`${action}: ${corePath} (${formatSize(info.size)})`);
      fileCount++;
      totalBytes += info.size;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
      log.warn(`${corePath}: ${error instanceof Error ? error.message : String(error)}`);
      errorCount++;
    }
  }

  if (fileCount > 0) {
    const label = `core file${fileCount === 1 ? "" : "s"}`;
    const summary = `${fileCount} ${label}, ${formatSize(totalBytes)}`;

    if (dryRun) {
      log.info(`Dry run: ${summary}. No files deleted.`);
    } else {
      log.success(`Deleted ${summary}.`);
    }
  } else if (errorCount === 0) {
    log.info("No generated core files found.");
  }

  if (errorCount > 0) {
    const label = `run${errorCount === 1 ? "" : "s"}`;
    log.warn(`Could not clean ${errorCount} ${label}; check the errors above.`);
    process.exitCode = 1;
  }
}

if (import.meta.main) {
  main().catch((error) => {
    log.error(error);
    process.exitCode = 1;
  });
}
