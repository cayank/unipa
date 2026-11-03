import { unlink } from "node:fs/promises";
import { log } from "./logger";
import { forceCloseApp } from "./process";

type CleanupOptions = {
  executable: string;
  pid?: number;
  generatedCore?: string;
};

type CleanupResult = {
  appClosed: boolean | null;
  coreDeleted: boolean;
  errors: string[];
};

export async function cleanupRun({ executable, pid, generatedCore }: CleanupOptions): Promise<CleanupResult> {
  const result: CleanupResult = { appClosed: null, coreDeleted: false, errors: [] };

  if (pid !== undefined) {
    try {
      const killed = await forceCloseApp(executable, pid);
      result.appClosed = true;
      killed ? log.success(`Force-closed app (PID ${pid})`) : log.info(`App already closed (PID ${pid})`);
    } catch (error) {
      result.appClosed = false;
      const message = `Could not close the app: ${error instanceof Error ? error.message : String(error)}`;
      result.errors.push(message);
      log.warn(message);
    }
  }

  if (generatedCore) {
    try {
      await unlink(generatedCore);
      result.coreDeleted = true;
      log.success(`Deleted core dump: ${generatedCore}`);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        result.coreDeleted = true;
      } else {
        const message = `Could not delete ${generatedCore}: ${error instanceof Error ? error.message : String(error)}`;
        result.errors.push(message);
        log.warn(message);
      }
    }
  }

  return result;
}
