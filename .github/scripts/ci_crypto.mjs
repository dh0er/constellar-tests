#!/usr/bin/env node
/**
 * Streaming hybrid log & artifact encryptor for public CI runners (CENC1).
 *
 * Uses only Node.js built-ins (RSA-OAEP-SHA256 + AES-256-GCM + gzip).
 * The runner holds ONLY the public key (CI_LOG_PUBLIC_KEY) and fails closed
 * if the key is missing or invalid so plaintext logs/artifacts are never
 * emitted to a public repository by accident.
 *
 * Usage:
 *   node ci_crypto.mjs wrap [--cwd DIR] [--public-key-file PATH] -- <cmd> [args...]
 *   node ci_crypto.mjs encrypt-artifact --out FILE [--base-dir DIR] [--public-key-file PATH] <path...>
 */

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { spawn, spawnSync } from "node:child_process";

const CHUNK_BYTES = 16 * 1024;
const IDLE_FLUSH_MS = 500;
const MAX_FLUSH_MS = 2000;
const FILE_CHUNK_BYTES = 64 * 1024;
const GZIP_MIN_BYTES = 64;
const FLAG_GZIP = 0x01;
const FLAG_FINAL = 0x02;
const FILE_MAGIC = Buffer.from("CENC1\0", "ascii");
const AAD_PREFIX = Buffer.from("CENC1:", "ascii");

function writeStdoutSync(text) {
  const buf = Buffer.from(text, "utf8");
  let offset = 0;
  while (offset < buf.length) {
    try {
      const written = fs.writeSync(1, buf, offset, buf.length - offset);
      if (written <= 0) break;
      offset += written;
    } catch (err) {
      if (err && (err.code === "EAGAIN" || err.code === "EWOULDBLOCK")) {
        // Brief spin-sleep via Atomics.wait on a temporary buffer for non-blocking stdout pipes.
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
        continue;
      }
      throw err;
    }
  }
}

function loadPublicKey(keyFile) {
  let raw = "";
  if (keyFile) {
    raw = fs.readFileSync(keyFile, "utf8");
  } else {
    raw = process.env.CI_LOG_PUBLIC_KEY || "";
  }
  const trimmed = raw.trim();
  if (!trimmed) {
    throw new Error(
      "CI_LOG_PUBLIC_KEY is not set; refusing to emit plaintext logs or artifacts.",
    );
  }
  let pem = trimmed;
  if (!pem.includes("BEGIN PUBLIC KEY") && !pem.includes("BEGIN RSA PUBLIC KEY")) {
    const decoded = Buffer.from(trimmed.replace(/\s+/g, ""), "base64").toString("utf8").trim();
    if (decoded.includes("BEGIN PUBLIC KEY") || decoded.includes("BEGIN RSA PUBLIC KEY")) {
      pem = decoded;
    }
  }
  return crypto.createPublicKey(pem);
}

function createStreamSession(publicKey) {
  const sessionKey = crypto.randomBytes(32);
  const noncePrefix = crypto.randomBytes(8);
  const keyMaterial = Buffer.concat([sessionKey, noncePrefix]);
  const wrappedKey = crypto.publicEncrypt(
    {
      key: publicKey,
      padding: crypto.constants.RSA_PKCS1_OAEP_PADDING,
      oaepHash: "sha256",
    },
    keyMaterial,
  );
  return { sessionKey, noncePrefix, wrappedKey };
}

function encryptChunk(sessionKey, noncePrefix, seq, flags, aadTagBuf, plaintext) {
  const seqBuf = Buffer.alloc(4);
  seqBuf.writeUInt32BE(seq, 0);
  const nonce = Buffer.concat([noncePrefix, seqBuf]);
  const flagsBuf = Buffer.from([flags]);
  const aad = Buffer.concat([AAD_PREFIX, seqBuf, flagsBuf, aadTagBuf]);

  const cipher = crypto.createCipheriv("aes-256-gcm", sessionKey, nonce);
  cipher.setAAD(aad);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return { ciphertext, authTag };
}

class EncryptedLogWriter {
  constructor(publicKey) {
    const { sessionKey, noncePrefix, wrappedKey } = createStreamSession(publicKey);
    this.sessionKey = sessionKey;
    this.noncePrefix = noncePrefix;
    this.sid = crypto.randomBytes(4).toString("hex");
    this.sidBuf = Buffer.from(this.sid, "ascii");
    this.seq = 0;
    this.finalized = false;
    this.pendingChunks = [];
    this.pendingBytes = 0;
    this.idleTimer = null;
    this.maxTimer = null;

    writeStdoutSync(`[CENC1:H:${this.sid}:${wrappedKey.toString("base64")}]\n`);
  }

  push(chunk) {
    if (this.finalized || !chunk || chunk.length === 0) return;
    this.pendingChunks.push(chunk);
    this.pendingBytes += chunk.length;

    if (this.pendingBytes >= CHUNK_BYTES) {
      this._drainFullChunks();
    }
    this._scheduleTimers();
  }

  _clearTimers() {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
    if (this.maxTimer) {
      clearTimeout(this.maxTimer);
      this.maxTimer = null;
    }
  }

  _scheduleTimers() {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
    if (this.pendingBytes === 0 || this.finalized) {
      if (this.maxTimer) {
        clearTimeout(this.maxTimer);
        this.maxTimer = null;
      }
      return;
    }
    this.idleTimer = setTimeout(() => {
      this.idleTimer = null;
      this.flush(false);
    }, IDLE_FLUSH_MS);
    this.idleTimer.unref();

    if (!this.maxTimer) {
      this.maxTimer = setTimeout(() => {
        this.maxTimer = null;
        this.flush(false);
      }, MAX_FLUSH_MS);
      this.maxTimer.unref();
    }
  }

  _drainFullChunks() {
    let combined = Buffer.concat(this.pendingChunks, this.pendingBytes);
    let offset = 0;
    while (combined.length - offset >= CHUNK_BYTES) {
      this._emitFrame(combined.subarray(offset, offset + CHUNK_BYTES), false);
      offset += CHUNK_BYTES;
    }
    if (offset < combined.length) {
      const rest = Buffer.from(combined.subarray(offset));
      this.pendingChunks = [rest];
      this.pendingBytes = rest.length;
    } else {
      this.pendingChunks = [];
      this.pendingBytes = 0;
    }
  }

  _emitFrame(rawBuf, isFinal) {
    let payload = rawBuf;
    let flags = isFinal ? FLAG_FINAL : 0;
    if (rawBuf.length >= GZIP_MIN_BYTES) {
      const zipped = zlib.gzipSync(rawBuf, { level: 6 });
      if (zipped.length < rawBuf.length) {
        payload = zipped;
        flags |= FLAG_GZIP;
      }
    }
    const { ciphertext, authTag } = encryptChunk(
      this.sessionKey,
      this.noncePrefix,
      this.seq,
      flags,
      this.sidBuf,
      payload,
    );
    const body = Buffer.concat([ciphertext, authTag]).toString("base64");
    writeStdoutSync(
      `[CENC1:D:${this.sid}:${this.seq}:${flags.toString(16)}:${body}]\n`,
    );
    this.seq += 1;
  }

  flush(isFinal) {
    if (this.finalized) return;
    if (isFinal) {
      this._clearTimers();
      this.finalized = true;
      if (this.pendingBytes > CHUNK_BYTES) {
        this._drainFullChunks();
      }
      const remaining =
        this.pendingBytes > 0
          ? Buffer.concat(this.pendingChunks, this.pendingBytes)
          : Buffer.alloc(0);
      this.pendingChunks = [];
      this.pendingBytes = 0;
      this._emitFrame(remaining, true);
      return;
    }
    if (this.pendingBytes === 0) return;
    this._clearTimers();
    const data = Buffer.concat(this.pendingChunks, this.pendingBytes);
    this.pendingChunks = [];
    this.pendingBytes = 0;
    let offset = 0;
    while (offset < data.length) {
      const slice = data.subarray(offset, Math.min(offset + CHUNK_BYTES, data.length));
      this._emitFrame(slice, false);
      offset += slice.length;
    }
  }
}

function runWrap(args) {
  let cwd = process.cwd();
  let keyFile = null;
  let cmdIndex = -1;

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--") {
      cmdIndex = i + 1;
      break;
    } else if (arg === "--cwd") {
      cwd = args[++i];
    } else if (arg === "--public-key-file") {
      keyFile = args[++i];
    } else {
      throw new Error(`Unknown wrap option: ${arg}`);
    }
  }
  if (cmdIndex < 0 || cmdIndex >= args.length) {
    throw new Error("wrap requires `-- <command> [args...]`");
  }

  const publicKey = loadPublicKey(keyFile);
  const cmd = args[cmdIndex];
  const cmdArgs = args.slice(cmdIndex + 1);

  const writer = new EncryptedLogWriter(publicKey);
  const childEnv = { ...process.env, PYTHONUNBUFFERED: "1" };
  delete childEnv.CI_LOG_PUBLIC_KEY;

  const child = spawn(cmd, cmdArgs, {
    cwd,
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });

  let closed = false;
  let forcedExitTimer = null;

  child.stdout.on("data", (chunk) => writer.push(chunk));
  child.stderr.on("data", (chunk) => writer.push(chunk));

  const handleSignal = (signal) => {
    writer.push(Buffer.from(`\n[ci_crypto] received ${signal}; flushing encrypted log...\n`, "utf8"));
    writer.flush(false);
    try {
      child.kill(signal);
    } catch {
      // Child may already have exited.
    }
    if (!forcedExitTimer) {
      forcedExitTimer = setTimeout(() => {
        if (!closed) {
          writer.push(Buffer.from(`\n[ci_crypto] timed out waiting for child after ${signal}\n`, "utf8"));
          writer.flush(true);
          process.exit(signal === "SIGINT" ? 130 : 143);
        }
      }, 4000);
      forcedExitTimer.unref();
    }
  };

  process.on("SIGINT", () => handleSignal("SIGINT"));
  process.on("SIGTERM", () => handleSignal("SIGTERM"));

  child.on("error", (err) => {
    closed = true;
    if (forcedExitTimer) clearTimeout(forcedExitTimer);
    writer.push(Buffer.from(`\n[ci_crypto] failed to spawn ${cmd}: ${err.message}\n`, "utf8"));
    writer.flush(true);
    process.exit(127);
  });

  child.on("close", (code, signal) => {
    closed = true;
    if (forcedExitTimer) clearTimeout(forcedExitTimer);
    if (signal) {
      writer.push(Buffer.from(`\n[ci_crypto] child terminated by signal ${signal}\n`, "utf8"));
    }
    writer.flush(true);
    if (typeof code === "number") {
      process.exit(code);
    }
    process.exit(signal === "SIGINT" ? 130 : 143);
  });
}

function hasAnyFile(targetPath) {
  if (!fs.existsSync(targetPath)) return false;
  const stat = fs.lstatSync(targetPath);
  if (stat.isFile() || stat.isSymbolicLink()) return true;
  if (!stat.isDirectory()) return false;
  for (const entry of fs.readdirSync(targetPath)) {
    if (hasAnyFile(path.join(targetPath, entry))) return true;
  }
  return false;
}

function encryptFileBinary(publicKey, inputPath, outputPath) {
  const { sessionKey, noncePrefix, wrappedKey } = createStreamSession(publicKey);
  const aadTag = Buffer.from("FILE", "ascii");

  fs.mkdirSync(path.dirname(path.resolve(outputPath)), { recursive: true });
  const inFd = fs.openSync(inputPath, "r");
  const outFd = fs.openSync(outputPath, "w");

  try {
    const keyLenBuf = Buffer.alloc(2);
    keyLenBuf.writeUInt16BE(wrappedKey.length, 0);
    fs.writeSync(outFd, FILE_MAGIC);
    fs.writeSync(outFd, keyLenBuf);
    fs.writeSync(outFd, wrappedKey);

    const readBuf = Buffer.alloc(FILE_CHUNK_BYTES);
    let seq = 0;
    let bytesRead = fs.readSync(inFd, readBuf, 0, FILE_CHUNK_BYTES, null);
    while (bytesRead > 0) {
      const current = Buffer.from(readBuf.subarray(0, bytesRead));
      const nextRead = fs.readSync(inFd, readBuf, 0, FILE_CHUNK_BYTES, null);
      const isFinal = nextRead === 0;
      const flags = isFinal ? FLAG_FINAL : 0;

      const { ciphertext, authTag } = encryptChunk(
        sessionKey,
        noncePrefix,
        seq,
        flags,
        aadTag,
        current,
      );
      const header = Buffer.alloc(9);
      header.writeUInt32BE(seq, 0);
      header.writeUInt8(flags, 4);
      header.writeUInt32BE(ciphertext.length, 5);
      fs.writeSync(outFd, header);
      fs.writeSync(outFd, ciphertext);
      fs.writeSync(outFd, authTag);

      seq += 1;
      bytesRead = nextRead;
    }

    if (seq === 0) {
      const { ciphertext, authTag } = encryptChunk(
        sessionKey,
        noncePrefix,
        0,
        FLAG_FINAL,
        aadTag,
        Buffer.alloc(0),
      );
      const header = Buffer.alloc(9);
      header.writeUInt32BE(0, 0);
      header.writeUInt8(FLAG_FINAL, 4);
      header.writeUInt32BE(ciphertext.length, 5);
      fs.writeSync(outFd, header);
      fs.writeSync(outFd, ciphertext);
      fs.writeSync(outFd, authTag);
    }
  } finally {
    fs.closeSync(inFd);
    fs.closeSync(outFd);
  }
}

function runEncryptArtifact(args) {
  let outFile = null;
  let baseDir = process.cwd();
  let keyFile = null;
  const inputs = [];

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--out") {
      outFile = args[++i];
    } else if (arg === "--base-dir") {
      baseDir = args[++i];
    } else if (arg === "--public-key-file") {
      keyFile = args[++i];
    } else {
      inputs.push(arg);
    }
  }
  if (!outFile) {
    throw new Error("encrypt-artifact requires --out <path>");
  }
  if (inputs.length === 0) {
    throw new Error("encrypt-artifact requires at least one input path");
  }

  const publicKey = loadPublicKey(keyFile);
  const absBase = path.resolve(baseDir);
  const existingRel = [];
  for (const input of inputs) {
    const resolved = path.isAbsolute(input) ? input : path.resolve(absBase, input);
    if (hasAnyFile(resolved)) {
      const rel = path.relative(absBase, resolved);
      if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) {
        throw new Error(`Artifact path escapes base-dir: ${input}`);
      }
      existingRel.push(rel.split(path.sep).join("/"));
    }
  }

  if (existingRel.length === 0) {
    console.log("No artifact files found; skipping encrypted archive.");
    return;
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "cenc1-art-"));
  const tmpTarGz = path.join(tmpDir, "payload.tar.gz");
  try {
    const tarResult = spawnSync(
      "tar",
      ["-czf", tmpTarGz, "-C", absBase, ...existingRel],
      { encoding: "utf8", windowsHide: true },
    );
    if (tarResult.error) {
      throw new Error(`tar failed to start: ${tarResult.error.message}`);
    }
    if (tarResult.status !== 0) {
      throw new Error(`tar exited with code ${tarResult.status}: ${tarResult.stderr || tarResult.stdout}`);
    }
    encryptFileBinary(publicKey, tmpTarGz, outFile);
    console.log(`Encrypted artifact archive written (${path.basename(outFile)}).`);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

try {
  const [subcommand, ...rest] = process.argv.slice(2);
  if (subcommand === "wrap") {
    runWrap(rest);
  } else if (subcommand === "encrypt-artifact") {
    runEncryptArtifact(rest);
  } else {
    console.error("Usage: ci_crypto.mjs <wrap|encrypt-artifact> ...");
    process.exit(2);
  }
} catch (err) {
  console.error(`[ci_crypto] ${err.message}`);
  process.exit(1);
}
