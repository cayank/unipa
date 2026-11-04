import path from "node:path";
import { runMachO } from "./macho/run";

export type InjectedLibrary = {
  source: string;
  binary: string;
  load_command: string;
  source_sha256: string;
  prepared_sha256: string;
  thinned: boolean;
  config: string | null;
  config_sha256: string | null;
};

export type InjectionPlan = {
  directory: string;
  libraries: InjectedLibrary[];
};

export async function prepareInjection(app: string, libraries: string[], workspace: string): Promise<InjectionPlan> {
  const args = ["--app", app, "--output-dir", path.join(workspace, "injection")];
  for (const library of libraries) {
    args.push("--dylib", library);
  }

  return runMachO<InjectionPlan>("prepare-injection", args);
}

export async function injectLibraries(app: string, plan: InjectionPlan): Promise<InjectedLibrary[]> {
  const result = await runMachO<{ libraries: InjectedLibrary[] }>("inject", ["--app", app, "--prepared", plan.directory]);
  return result.libraries;
}
