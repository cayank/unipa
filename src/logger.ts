type Level = "info" | "success" | "warn" | "error";

const colors: Record<Level, string | null> = {
  info: Bun.color("cyan", "ansi-16"),
  success: Bun.color("green", "ansi-16"),
  warn: Bun.color("yellow", "ansi-16"),
  error: Bun.color("red", "ansi-16"),
};

function useColors(stream: NodeJS.WriteStream): boolean {
  if (process.env.FORCE_COLOR === "1") return true;
  if (process.env.NO_COLOR !== undefined || process.env.FORCE_COLOR === "0") return false;
  return Boolean(stream.isTTY) && process.env.TERM !== "dumb";
}

function write(level: Level, message: string, stream = level === "warn" || level === "error" ? process.stderr : process.stdout): void {
  const label = `[${level.toUpperCase()}]`.padEnd(9);
  const prefix = useColors(stream) ? `${colors[level] ?? ""}${label}\x1b[0m` : label;
  const lines = message.split(/\r?\n/).map((line) => `${prefix} ${line}`);
  stream.write(lines.join("\n") + "\n");
}

export const log = {
  output(command: string, message: string, stream: "stdout" | "stderr"): void {
    write("info", `[${command}] ${message}`, process[stream]);
  },
  info(message: string): void {
    write("info", message);
  },
  success(message: string): void {
    write("success", message);
  },
  warn(message: string): void {
    write("warn", message);
  },
  error(error: unknown): void {
    write("error", error instanceof Error ? error.message : String(error));
  },
};
