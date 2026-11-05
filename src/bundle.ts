import { runMachO } from "./macho/run";

export type BundleOverrides = { id?: string; name?: string };

export type BundleConfiguration = {
  app: string;
  original_bundle_id: string;
  bundle_id: string;
  name: string;
  nested_bundles: { bundle: string; bundle_id: string }[];
};

export async function configureBundle(app: string, overrides: BundleOverrides): Promise<BundleConfiguration> {
  const args = ["--app", app];
  if (overrides.id !== undefined) args.push(`--bundle-id=${overrides.id}`);
  if (overrides.name !== undefined) args.push(`--bundle-name=${overrides.name}`);
  return runMachO<BundleConfiguration>("configure-bundle", args);
}
