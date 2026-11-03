import { lstat, readdir, unlink } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";
import { log } from "../src/logger";

const HELP_MESSAGE = `Delete generated core dumps while keeping IPAs and recovery reports.

Usage:
  bun run clean:cores
  bun run clean:cores --dry-run
  bun run clean:cores --work-dir /path/to/output

Only regular files matching machkit-*/process.core are removed.
Symlinks are skipped. The default directory is this project's output folder.`;

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
  if (process.platform !== "darwin") throw new Error("machkit is only supported on macOS.");

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
    if (!folder.isDirectory() || !folder.name.startsWith("machkit-")) continue;

    const corePath = path.join(outputDir, folder.name, "process.core");
    try {
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
    const label = fileCount === 1 ? "core file" : "core files";
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
    const label = errorCount === 1 ? "run" : "runs";
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
