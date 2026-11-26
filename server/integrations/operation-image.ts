import { crc32 } from "node:zlib";
import type { OperationImage, OperationResult } from "../../shared/types.ts";

const MAX_BYTES = 2 * 1024 * 1024;
const MAX_SIDE = 2048;
const PNG_SIGNATURE = Buffer.from("89504e470d0a1a0a", "hex");

/** Accepts one inline PNG. The model harness never has to fetch an app-supplied URL. */
export function operationImage(value: unknown): OperationImage | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return;
  const { mimeType, base64 } = value as Record<string, unknown>;
  if (mimeType !== "image/png" || typeof base64 !== "string" ||
      base64.length > Math.ceil(MAX_BYTES / 3) * 4 || base64.length % 4 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(base64)) return;
  const bytes = Buffer.from(base64, "base64");
  if (bytes.length < 33 || bytes.length > MAX_BYTES ||
      !bytes.subarray(0, 8).equals(PNG_SIGNATURE) || bytes.readUInt32BE(8) !== 13 || bytes.toString("ascii", 12, 16) !== "IHDR") return;
  const width = bytes.readUInt32BE(16), height = bytes.readUInt32BE(20);
  if (width && height && width <= MAX_SIDE && height <= MAX_SIDE && hasImageData(bytes)) return { mimeType, base64 };
}

function hasImageData(png: Buffer) {
  let data = false;
  for (let offset = 8; offset + 12 <= png.length;) {
    const length = png.readUInt32BE(offset);
    const end = offset + 12 + length;
    if (end > png.length || crc32(png.subarray(offset + 4, end - 4)) !== png.readUInt32BE(end - 4)) return false;
    const type = png.toString("ascii", offset + 4, offset + 8);
    if (type === "IDAT" && length) data = true;
    if (type === "IEND") return data && length === 0 && end === png.length;
    offset = end;
  }
  return false;
}

/** Separates the recordable result from the attachment sent to the model. */
export function operationToolResult(result: unknown) {
  const value = result as OperationResult | null;
  if (!value?.image) return { output: result };
  const { image, ...rest } = value;
  return { output: { ...rest, image: { mimeType: image.mimeType } }, image };
}


// OpenCode can send a file as media rather than encoding it into the result text.
export function operationToolContent(result: unknown, imageInput: boolean) {
  const { output, image } = operationToolResult(result);
  const text = JSON.stringify(output);
  if (!image) return text;
  if (!imageInput) return text + "\nThe active provider cannot view PNG attachments.";
  return [
    { type: "text", text },
    { type: "file", uri: `data:${image.mimeType};base64,${image.base64}`, mime: image.mimeType, name: "capture.png" },
  ] as const;
}
