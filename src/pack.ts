import path from "node:path";
import { lstat, rename } from "node:fs/promises";
import { runMachO, type BundleInspection } from "./macho/run";
import { log } from "./logger";
import { execute } from "./process";

export async function pack(app: string, workspace: string, identity: string | undefined): Promise<string> {
  const inspection = await runMachO<BundleInspection>("inspect-bundle", ["--app", app]);
  if (inspection.encrypted.length) throw new Error(`Encrypted files remain before packaging: ${inspection.encrypted.join(", ")}`);

  if (identity !== undefined) {
    log.info(`Signing (${identity === "-" ? "ad-hoc" : identity})…`);
    await execute(["/usr/bin/codesign", "--force", "--deep", "--sign", identity, app]);
    await execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app]);
    log.success("Signature verified");
  }

  // ditto includes payload itself and retains symlinks and executable modes
  const pending = path.join(workspace, "archive.pending.zip");
  const output = path.join(workspace, `${path.basename(app, ".app")}-patched.ipa`);
  log.info("Creating IPA…");
  await execute(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", path.join(workspace, "Payload"), pending]);

  await execute(["/usr/bin/unzip", "-tq", pending]);
  if ((await lstat(pending)).size === 0) throw new Error("IPA archive is empty");

  await rename(pending, output);
  return output;
}
