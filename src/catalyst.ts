import type { InjectedLibrary } from "./inject";
import { runMachO } from "./macho/run";
import { execute } from "./process";

type CatalystBinary = {
  binary: string;
  original_platform: number | null;
  platform: number;
  sdk: string;
  swift_uikit_fixed: boolean;
};

export type CatalystConversion = {
  status: "ready";
  app: string;
  original_bundle_id: string;
  name: string;
  bundle_id: string;
  identity: string;
  incoming_network: boolean;
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
    ipad?: { width: number; height: number };
    library: string;
  };
};

export const checkCatalystTools = async (): Promise<void> => {
  if (process.arch !== "arm64") throw new Error("--macos requires an Apple Silicon Mac");
  try {
    await execute(["/usr/bin/xcrun", "--find", "vtool"]);
    await execute(["/usr/bin/xcrun", "--find", "install_name_tool"]);
    await execute(["/usr/bin/xcrun", "--find", "clang"]);
  } catch (error) {
    throw new Error("--macos requires Xcode Command Line Tools; install them with xcode-select --install", { cause: error });
  }
};

export const checkCatalystRuntime = async (app: string, libraries: InjectedLibrary[] = [], force = false): Promise<void> => {
  const args = ["--app", app];
  for (const library of libraries) args.push("--dylib", library.load_command);
  if (force) args.push("--force");
  await runMachO("check-macos-runtime", args);
};

export const createCatalystApp = async (
  app: string,
  outputDir: string,
  identity: string,
  keychainInstance?: string,
  bundle: { id?: string; name?: string } = {},
  incomingNetwork = false,
  force = false,
  bypassJailbreak = false,
  bypassPinning = false,
  stubFrameworks?: string,
): Promise<CatalystConversion> => {
  const args = ["--app", app, "--output-dir", outputDir, "--identity", identity];
  if (incomingNetwork) args.push("--incoming-network");
  if (force) args.push("--force");
  if (bypassJailbreak) args.push("--bypass-jailbreak");
  if (bypassPinning) args.push("--bypass-pinning");
  if (stubFrameworks) args.push("--stub-frameworks", stubFrameworks);
  if (keychainInstance !== undefined) {
    args.push("--keychain-instance", keychainInstance);
  }
  if (bundle.id !== undefined) args.push(`--bundle-id=${bundle.id}`);
  if (bundle.name !== undefined) args.push(`--bundle-name=${bundle.name}`);
  return runMachO<CatalystConversion>("convert-macos", args);
};
