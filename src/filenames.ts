const maxFilenameBytes = 255;
const runSuffixLength = 6;

const filenameStem = (name: string, maxLength: number): string => {
  const stem = name
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .replace(/ı/g, "i")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

  return stem.slice(0, maxLength).replace(/-+$/, "") || "app";
}

export const outputFilename = (name: string, suffix: string): string => {
  return filenameStem(name, maxFilenameBytes - Buffer.byteLength(suffix)) + suffix;
};

export const runDirectoryPrefix = (appName: string): string => {
  return `${filenameStem(appName, maxFilenameBytes - runSuffixLength - 1)}-`;
};
