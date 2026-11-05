import { execute } from "./process";
import { runMachO } from "./macho/run";

type CatalystBinary = {
  binary: string;
  original_platform: number | null;
  platform: number;
  swift_uikit_fixed: boolean;
};

export type CatalystConversion = {
  status: "ready";
  app: string;
  original_bundle_id: string;
  name: string;
  bundle_id: string;
  identity: string;
  keychain: {
    backend: "sqlite";
    bundle_id: string;
    instance: string;
    directory: string;
    database: string;
  } | null;
  binaries: CatalystBinary[];
  signed_targets: string[];
  runtime: {
    working_directory: string;
    library: string;
  };
  compatibility_sandbox: {
    deny_process_fork: boolean;
    denied_files: string[];
    denied_directories: string[];
  };
  window_geometry: {
    width: number;
    height: number;
    resizable: boolean;
    lock_aspect_ratio: boolean;
    library: string;
  };
};

export async function checkCatalystTools(): Promise<void> {
  if (process.arch !== "arm64") throw new Error("--macos requires an Apple Silicon Mac");
  try {
    await execute(["/usr/bin/xcrun", "--find", "vtool"]);
    await execute(["/usr/bin/xcrun", "--find", "install_name_tool"]);
    await execute(["/usr/bin/xcrun", "--find", "clang"]);
  } catch (error) {
    throw new Error("--macos requires Xcode Command Line Tools; install them with xcode-select --install", { cause: error });
  }
}

export async function createCatalystApp(
  app: string,
  outputDir: string,
  identity: string,
  keychainInstance?: string,
  bundle: { id?: string; name?: string } = {},
): Promise<CatalystConversion> {
  const args = ["--app", app, "--output-dir", outputDir, "--identity", identity];
  if (keychainInstance !== undefined) {
    args.push("--keychain-instance", keychainInstance);
  }
  if (bundle.id !== undefined) args.push(`--bundle-id=${bundle.id}`);
  if (bundle.name !== undefined) args.push(`--bundle-name=${bundle.name}`);
  return runMachO<CatalystConversion>("convert-macos", args);
}
