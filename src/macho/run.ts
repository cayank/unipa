import path from "node:path";
import { execute } from "../process";

const cliPath = path.join(import.meta.dir, "cli.py");

export async function runMachO<T>(command: string, args: string[]): Promise<T> {
  const pyEnv = process.env.UNIPA_PYTHON || "python3";
  const output = await execute([pyEnv, "-B", cliPath, command, ...args]);

  try {
    return JSON.parse(output) as T;
  } catch {
    throw new Error(`Invalid JSON from Mach-O command (${command})`);
  }
}

export type Bundle = {
  path: string;
  name: string;
  executable: string;
  bundle_id: string;
};

export type BundleInspection = Bundle & {
  binaries: string[];
  encrypted: string[];
};

export type Recovery = {
  output: string;
  region: string;
  disk_sha256: string;
  patched_sha256: string;
  selected: { base: string; slide: string; address: string; sha256: string };
};
