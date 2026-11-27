import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
} from "node:crypto";
import { readFileSync } from "node:fs";

export function readKey(path: string | undefined): Buffer {
  if (!path) throw new Error("secret_file_required");
  const key = readFileSync(path);
  if (key.length !== 32) throw new Error("secret_must_be_32_bytes");
  return key;
}

export function seal(value: string, key: Buffer, scope: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(Buffer.from(scope));
  const ciphertext = Buffer.concat([
    cipher.update(value, "utf8"),
    cipher.final(),
  ]);
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString(
    "base64url",
  );
}

export function open(value: string, key: Buffer, scope: string): string {
  const packed = Buffer.from(value, "base64url");
  if (packed.length < 28) throw new Error("invalid_envelope");
  const decipher = createDecipheriv("aes-256-gcm", key, packed.subarray(0, 12));
  decipher.setAAD(Buffer.from(scope));
  decipher.setAuthTag(packed.subarray(12, 28));
  return Buffer.concat([
    decipher.update(packed.subarray(28)),
    decipher.final(),
  ]).toString("utf8");
}

export function sha256(value: string) {
  return createHash("sha256").update(value).digest("hex");
}
export function randomToken() {
  return randomBytes(32).toString("base64url");
}
