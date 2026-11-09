import path from "node:path";
import { lstat, rename } from "node:fs/promises";
import { runMachO, type BundleInspection } from "./macho/run";
import { log } from "./logger";
import { execute } from "./process";
import type { InjectedLibrary } from "./inject";
import { outputFilename } from "./filenames";

export async function pack(app: string, workspace: string, identity: string | undefined, injections: InjectedLibrary[] = []): Promise<string> {
  const inspection = await runMachO<BundleInspection>("inspect-bundle", ["--app", app]);
  if (inspection.encrypted.length) throw new Error(`Encrypted files remain before packaging: ${inspection.encrypted.join(", ")}`);
  if (inspection.universal.length) throw new Error(`Universal binaries remain before packaging: ${inspection.universal.join(", ")}`);

  if (identity !== undefined) {
    log.info(`Signing (${identity === "-" ? "ad-hoc" : identity})…`);
    for (const library of injections) {
      const binary = path.join(app, library.binary);
      await execute(["/usr/bin/codesign", "--force", "--sign", identity, binary]);
      await execute(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", binary]);
    }
    await execute(["/usr/bin/codesign", "--force", "--deep", "--sign", identity, app]);
    await execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app]);
    log.success("Signature verified");
  }

  // ditto includes payload itself and retains symlinks and executable modes
  const pending = path.join(workspace, "archive.pending.zip");
  const output = path.join(workspace, outputFilename(inspection.name, "-patched.ipa"));
  log.info("Creating IPA…");
  await execute(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", path.join(workspace, "Payload"), pending]);

  await execute(["/usr/bin/unzip", "-tq", pending]);
  if ((await lstat(pending)).size === 0) throw new Error("IPA archive is empty");

  await rename(pending, output);
  return output;
}
