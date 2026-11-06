const maxFilenameBytes = 255;
const runSuffixLength = 6;

function truncateUtf8(value: string, maxBytes: number): string {
  let result = "";
  let bytes = 0;
  for (const character of value) {
    const length = Buffer.byteLength(character.normalize("NFD"));
    if (bytes + length > maxBytes) break;
    result += character;
    bytes += length;
  }
  return result;
}

export function outputFilename(name: string, suffix: string): string {
  return truncateUtf8(name, maxFilenameBytes - Buffer.byteLength(suffix)) + suffix;
}

export function runDirectoryPrefix(appName: string): string {
  const name = truncateUtf8(appName.toLowerCase(), maxFilenameBytes - runSuffixLength - 1);
  return `${name}-`;
}
