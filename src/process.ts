import path from "node:path";
import { createReadStream } from "node:fs";
import { chmod, realpath, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { log } from "./logger";

type ExecuteOptions = {
  cwd?: string;
  interactive?: boolean;
};

export async function execute(command: string[], { cwd, interactive = false }: ExecuteOptions = {}): Promise<string> {
  const child = Bun.spawn(command, {
    cwd,
    stdin: interactive ? "inherit" : "ignore",
    stdout: interactive ? "inherit" : "pipe",
    stderr: interactive ? "inherit" : "pipe",
  });

  const [stdout, stderr, exitCode] = await Promise.all([
    child.stdout instanceof ReadableStream ? new Response(child.stdout).text() : Promise.resolve(""),
    child.stderr instanceof ReadableStream ? new Response(child.stderr).text() : Promise.resolve(""),
    child.exited,
  ]);

  if (exitCode !== 0) {
    let message = `${command[0]} exited with ${exitCode}`;
    if (stderr.trim()) message += `: ${stderr.trim()}`;
    throw new Error(message);
  }

  return stdout;
}

export type ProcessEntry = { pid: number; executable: string };
export type MatchedProcess = ProcessEntry & { matchedBy: "path" | "sha256" };

const digestCache = new Map<string, { signature: string; digest: string }>();

async function executableDigest(executable: string): Promise<string> {
  const info = await stat(executable);
  const signature = [info.dev, info.ino, info.size, info.mtimeMs, info.ctimeMs].join(":");

  const cached = digestCache.get(executable);
  if (cached?.signature === signature) return cached.digest;

  const hash = createHash("sha256");
  for await (const chunk of createReadStream(executable)) hash.update(chunk);

  const digest = hash.digest("hex");
  digestCache.set(executable, { signature, digest });

  return digest;
}

export function parseProcessList(output: string): ProcessEntry[] {
  const processes: ProcessEntry[] = [];

  for (const line of output.split("\n")) {
    const match = /^\s*(\d+)\s+(.+?)\s*$/.exec(line);
    if (!match) continue;
    processes.push({ pid: Number(match[1]), executable: match[2]! });
  }

  return processes;
}

export async function findMatchingProcesses(executable: string, processes: ProcessEntry[]): Promise<MatchedProcess[]> {
  const target = await realpath(executable);
  const targetInfo = await stat(target);
  const matches: MatchedProcess[] = [];

  for (const entry of processes) {
    if (!path.isAbsolute(entry.executable)) continue;

    try {
      const candidate = await realpath(entry.executable);
      if (candidate === target) {
        matches.push({ ...entry, executable: candidate, matchedBy: "path" });
        continue;
      }

      if (path.basename(candidate) !== path.basename(target)) continue;

      const info = await stat(candidate);
      if (!info.isFile() || info.size !== targetInfo.size) continue;

      const candidateHash = await executableDigest(candidate);
      const targetHash = await executableDigest(target);
      if (candidateHash === targetHash) {
        matches.push({ ...entry, executable: candidate, matchedBy: "sha256" });
      }
    } catch {
      // pass
    }
  }
  return matches;
}

type DumpOptions = {
  appPath: string;
  executable: string;
  outputPath: string;
  pid?: number;
  waitMs: number;
};

export async function dumpCore(options: DumpOptions): Promise<number> {
  const { appPath, executable, outputPath, pid, waitMs } = options;
  const existing = await matchingProcesses(executable);
  if (pid === undefined && existing.length === 0) {
    log.info("Launching app…");
    await execute(["/usr/bin/open", "-a", appPath]);
  }

  const targetPid = await waitForPid(executable, pid);
  const runtime = (await matchingProcesses(executable)).find((entry) => entry.pid === targetPid);
  if (runtime?.matchedBy === "sha256") {
    log.info(`Verified relocated executable (SHA256): ${runtime.executable}`);
  }

  log.info(`PID ${targetPid}; waiting ${waitMs} ms before dumping…`);
  await Bun.sleep(waitMs);
  await waitForPid(executable, targetPid);

  log.info("Dumping core (sudo may request your password)…");
  await execute(["/usr/bin/sudo", "/usr/bin/gcore", "-v", "-o", outputPath, String(targetPid)], { interactive: true });
  await execute(["/usr/bin/sudo", "/usr/sbin/chown", `${process.getuid!()}:${process.getgid!()}`, outputPath], { interactive: true });
  await chmod(outputPath, 0o600);
  log.success(`Core dump saved: ${outputPath}`);
  return targetPid;
}

export async function forceCloseApp(executable: string, pid: number): Promise<boolean> {
  const matches = await matchingPids(executable);
  if (!matches.includes(pid)) {
    try {
      process.kill(pid, 0);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
      throw error;
    }

    throw new Error(`Refusing to close PID ${pid}: it no longer runs the selected app`);
  }

  try {
    process.kill(pid, "SIGKILL");
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
    throw error;
  }
}

export async function matchingProcesses(executable: string): Promise<MatchedProcess[]> {
  const output = await execute(["/bin/ps", "-axo", "pid=,comm="]);
  return findMatchingProcesses(executable, parseProcessList(output));
}

export async function matchingPids(executable: string): Promise<number[]> {
  return (await matchingProcesses(executable)).map((entry) => entry.pid);
}

export async function waitForPid(executable: string, requested?: number): Promise<number> {
  const deadline = Date.now() + 15_000;

  do {
    const pids = await matchingPids(executable);
    if (requested !== undefined) {
      if (pids.includes(requested)) return requested;
      throw new Error(`PID ${requested} does not run the selected bundle executable`);
    }

    if (pids.length === 1) return pids[0]!;
    if (pids.length > 1) throw new Error(`Multiple matching processes (${pids.join(", ")}); select --pid`);

    await Bun.sleep(250);
  } while (Date.now() < deadline);

  throw new Error(
    `No verified process found within 15 seconds for ${executable}. ` +
      "Try opening the app manually, then retry with --pid <PID>. " +
      "Relocated executables must have identical SHA256 contents.",
  );
}
