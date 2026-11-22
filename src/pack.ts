import { lstat, mkdtemp, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { outputFilename } from "./filenames";
import type { InjectedLibrary } from "./inject";
import { log } from "./logger";
import { runMachO, type BundleInspection } from "./macho/run";
import { execute } from "./process";

const MAC_CATALYST = 6;

const allowIncomingConnections = async (app: string, identity: string): Promise<void> => {
  const entitlements = await execute(["/usr/bin/codesign", "-d", "--entitlements", ":-", app]);
  if (!entitlements.trim()) return;

  const directory = await mkdtemp(path.join(tmpdir(), "unipa-sign-"));
  try {
    const file = path.join(directory, "entitlements.plist");
    await writeFile(file, entitlements, { mode: 0o600 });
    const profile = JSON.parse(await execute(["/usr/bin/plutil", "-convert", "json", "-o", "-", file]));
    if (profile["com.apple.security.app-sandbox"] !== true || profile["com.apple.security.network.server"] === true) return;

    profile["com.apple.security.network.server"] = true;
    await writeFile(file, JSON.stringify(profile));
    await execute(["/usr/bin/plutil", "-convert", "xml1", file]);
    await execute(["/usr/bin/codesign", "--force", "--sign", identity, "--entitlements", file, app]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
};

const signBundle = async (app: string, identity: string, injections: InjectedLibrary[], preserveEntitlements: boolean): Promise<void> => {
  log.info(`Signing (${identity === "-" ? "ad-hoc" : identity})…`);
  for (const library of injections) {
    const binary = path.join(app, library.binary);
    await execute(["/usr/bin/codesign", "--force", "--sign", identity, binary]);
    await execute(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", binary]);
  }
  const preserve = preserveEntitlements ? ["--preserve-metadata=entitlements"] : [];
  await execute(["/usr/bin/codesign", "--force", "--deep", ...preserve, "--sign", identity, app]);
  if (preserveEntitlements && injections.length) await allowIncomingConnections(app, identity);
  await execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app]);
  log.success("Signature verified");
};

export const packApp = async (app: string, workspace: string, identity: string | undefined, injections: InjectedLibrary[] = []): Promise<string> => {
  const inspection = await runMachO<BundleInspection>("inspect-bundle", ["--app", app]);
  if (inspection.encrypted.length) throw new Error(`Encrypted files remain before packaging: ${inspection.encrypted.join(", ")}`);
  if (inspection.universal.length) throw new Error(`Universal binaries remain before packaging: ${inspection.universal.join(", ")}`);

  if (identity !== undefined) await signBundle(app, identity, injections, true);

  const output = path.join(workspace, outputFilename(inspection.name, ".app"));
  await rm(output, { recursive: true, force: true });
  await rename(app, output);
  return output;
};

export const pack = async (app: string, workspace: string, identity: string | undefined, injections: InjectedLibrary[] = []): Promise<string> => {
  const inspection = await runMachO<BundleInspection>("inspect-bundle", ["--app", app]);
  if (inspection.encrypted.length) throw new Error(`Encrypted files remain before packaging: ${inspection.encrypted.join(", ")}`);
  if (inspection.universal.length) throw new Error(`Universal binaries remain before packaging: ${inspection.universal.join(", ")}`);

  if (identity !== undefined) await signBundle(app, identity, injections, inspection.platform === MAC_CATALYST);

  // ditto includes payload itself and retains symlinks and executable modes
  const pending = path.join(workspace, "archive.pending.zip");
  const output = path.join(workspace, outputFilename(inspection.name, "-patched.ipa"));
  log.info("Creating IPA…");
  await execute(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", path.join(workspace, "Payload"), pending]);

  await execute(["/usr/bin/unzip", "-tq", pending]);
  if ((await lstat(pending)).size === 0) throw new Error("IPA archive is empty");

  await rename(pending, output);
  return output;
};
