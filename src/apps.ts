import path from "node:path";
import { readdir, realpath } from "node:fs/promises";
import { select, Separator } from "@inquirer/prompts";
import { log } from "./logger";
import { execute } from "./process";
import { runMachO, type Bundle } from "./macho/run";

type Application = {
  _name: string;
  path: string;
  obtained_from?: string;
};

export async function selectApp(): Promise<string> {
  log.info("Searching for installed iOS apps…");

  const output = await execute(["/usr/sbin/system_profiler", "SPApplicationsDataType", "-json"]);
  const data = JSON.parse(output) as { SPApplicationsDataType: Application[] };

  const appsByPath = new Map<string, Application>();
  for (const app of data.SPApplicationsDataType) {
    if (app.obtained_from === "ios_app_store" && app.path.startsWith("/Applications/")) {
      appsByPath.set(app.path, app);
    }
  }

  const apps = [...appsByPath.values()].sort((first, second) => first._name.localeCompare(second._name));
  if (!apps.length) throw new Error("No iOS App Store apps found in /Applications; use --app /path/App.app");

  return select({
    message: "Which app should be packaged as an IPA?",
    pageSize: 10,
    choices: [
      new Separator(),
      ...apps.map((app) => ({
        name: `${app._name} | ${app.path}`,
        value: app.path,
      })),
    ],
  });
}

export async function resolveApp(selected: string): Promise<Bundle> {
  const root = await realpath(selected);
  const wrapper = path.join(root, "Wrapper");
  let children: string[] = [];

  try {
    children = (await readdir(wrapper, { withFileTypes: true }))
      .filter((entry) => entry.isDirectory() && entry.name.endsWith(".app"))
      .map((entry) => path.join(wrapper, entry.name));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }

  if (children.length > 1) throw new Error("Multiple apps inside Wrapper; select the inner app with --app");
  return runMachO<Bundle>("bundle-info", ["--app", children[0] ?? root]);
}
