/**
 * Logs NSFileManager file-existence checks without changing their results
 *
 * frida -H 127.0.0.1:27042 -n Gadget -l frida/file-checks.js
 *
 * pathIncludes: path fragments to match, an empty list logs all paths
 * mainExecutableOnly: excludes calls made by frameworks when enabled
 */

const pathIncludes = [];
const mainExecutableOnly = false;

if (!ObjC.available) throw new Error('Objective-C runtime is unavailable');

const app = Process.mainModule;
const selectors = ['- fileExistsAtPath:', '- fileExistsAtPath:isDirectory:'];

for (const selector of selectors) {
  const method = ObjC.classes.NSFileManager[selector];
  if (!method) continue;

  Interceptor.attach(method.implementation, {
    onEnter(args) {
      this.path = null;
      const caller = this.returnAddress;
      const module = Process.findModuleByAddress(caller);
      if (mainExecutableOnly && (!module || !module.base.equals(app.base))) return;
      if (args[2].isNull()) return;

      const path = new ObjC.Object(args[2]).toString();
      if (pathIncludes.length && !pathIncludes.some((text) => path.includes(text))) return;

      this.path = path;
      this.caller = module ? `${module.name}+${caller.sub(module.base)}` : caller.toString();
    },
    onLeave(result) {
      if (this.path === null) return;
      console.log(`[PATH-CHECK] exists=${!result.isNull()} path=${JSON.stringify(this.path)} caller=${this.caller}`);
    },
  });
}

console.log('Tracing NSFileManager path checks. Results are unchanged.');
