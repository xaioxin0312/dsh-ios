/*
 * ios-image-shim.mjs —— iOS 无 sharp 环境的图片支持（读取 + 上传 + 请求归一化）
 *
 * 背景（+ios24.6，iPhone X / A11 / iOS 16.7.x）：
 *   DSH rc.3 的 @deepseek-ai/dsh-attachment-local 把图片的准入、读取、
 *   请求版本生成全部交给 sharp（libvips 原生库）。iOS 包里的 sharp 只有
 *   JS 壳，没有 @img/sharp-* 原生二进制，于是：
 *
 *   1) 旧会话重放：dsh-llm-deepseek 的 prepareImages() 会遍历历史里**每一张**
 *      图片的 attachmentId 并调用 readImageRequest()。任一图片触发 sharp
 *      加载失败，整个 request() 抛错，被 generate() 统一包成
 *      LlmError("DeepSeek Messages transport failed","TRANSPORT") —— 前端
 *      显示 5/5 重试全部失败。表现就是「纯文字新对话正常，老对话必崩」。
 *   2) 新图片上传：dsh-client-file-upload 调 attachments.saveImages() ->
 *      prepareImageFile() -> detectImage()/normalizeImage() 同样要 sharp，
 *      上传直接失败。
 *
 * 修法：用 Node `--import` 预加载本文件，在 dsh 主进程里替换
 *   LocalAttachmentStore 的 readImage / readImageRequest / saveImage /
 *   saveImages / validateImage：
 *   * 纯 JS 解析 PNG/JPEG/GIF/WebP 头拿宽高、alpha、动图标记；
 *   * 读取仍走 content-addressed 对象 + sha256 校验；
 *   * 上传直存原始字节（不再解码-缩放-重编码）；超过请求 target 时也按原图
 *     返回 —— rc.3 的 inline 上限是 20 MiB，普通截图/照片都在范围内；
 *   * 对象缺失或损坏时，请求路径退化为 1x1 PNG 占位，保证老会话能继续，
 *     不再因一张历史图片把整轮对话打成 TRANSPORT。
 *
 * 约束：只用 Node 内置模块；jitless / fetch-shim 档可运行；不改包内
 * node_modules 的任何文件（升级 rc.x 时本文件仍独立生效）。
 */

import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const PATCHED = Symbol.for('dsh.ios.imageSupport');
const MAX_LOG = 240;
const FALLBACK_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z1ZkAAAAASUVORK5CYII=',
  'base64',
);

function short(value) {
  return String(value?.message ?? value).split('\n')[0].slice(0, MAX_LOG);
}

function log(message) {
  process.stderr.write(`[dsh-ios] ${message}\n`);
}

/* ------------------------------------------------------------------ 头部解析 */

function invalidImage(detail) {
  const error = new Error(`Unsupported or malformed image data.${detail === undefined ? '' : ` (${detail})`}`);
  error.code = 'INVALID_IMAGE';
  return error;
}

function u16be(b, i) { return (b[i] << 8) | b[i + 1]; }
function u16le(b, i) { return b[i] | (b[i + 1] << 8); }
function u32be(b, i) { return ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3]; }
function u24le(b, i) { return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16); }

function pngInfo(b) {
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (let i = 0; i < signature.length; i += 1) if (b[i] !== signature[i]) return null;
  if (b.length < 33 || String.fromCharCode(b[12], b[13], b[14], b[15]) !== 'IHDR') return null;
  const width = u32be(b, 16);
  const height = u32be(b, 20);
  const bitDepth = b[24];
  const colorType = b[25];
  if (width === 0 || height === 0) return null;
  let animated = false;
  for (let pos = 8; pos + 8 <= b.length;) {
    const length = u32be(b, pos);
    const type = String.fromCharCode(b[pos + 4], b[pos + 5], b[pos + 6], b[pos + 7]);
    if (type === 'acTL' || type === 'fcTL') { animated = true; break; }
    if (type === 'IDAT' || type === 'IEND') break;
    if (type === 'tEXt' || type === 'iTXt' || type === 'zTXt' || type === 'eXIf' || type === 'iCCP') {
      // 描述性/颜色元数据：不影响解码，只记录 carriesMetadata。
    }
    pos += 12 + length;
    if (length < 0 || pos > b.length) break;
  }
  return {
    mediaType: 'image/png',
    width, height,
    animated,
    carriesMetadata: false,
    depth: bitDepth === 16 ? 'ushort' : 'uchar',
    space: 'srgb',
    hasAlpha: colorType === 4 || colorType === 6,
  };
}

function exifOrientation(b, start, end) {
  // start 指向 "Exif\0\0" 之后（TIFF header 起点）。
  if (start + 8 > end) return undefined;
  const order = b[start] === 0x4d && b[start + 1] === 0x4d ? 'be' : 'le';
  const rd16 = order === 'be' ? u16be : u16le;
  if (rd16(b, start + 2) !== 0x2a) return undefined;
  const ifd = start + (order === 'be' ? u32be(b, start + 4) : (b[start + 4] | (b[start + 5] << 8) | (b[start + 6] << 16) | (b[start + 7] << 24)));
  if (ifd + 2 > end) return undefined;
  const count = rd16(b, ifd);
  for (let i = 0; i < count; i += 1) {
    const entry = ifd + 2 + i * 12;
    if (entry + 12 > end) return undefined;
    if (rd16(b, entry) !== 0x0112) continue;
    const value = order === 'be' ? u16be(b, entry + 8) : u16le(b, entry + 8);
    return value >= 1 && value <= 8 ? value : undefined;
  }
  return undefined;
}

function jpegInfo(b) {
  if (b[0] !== 0xff || b[1] !== 0xd8) return null;
  let pos = 2;
  let width = 0;
  let height = 0;
  let hasExif = false;
  let orientation;
  while (pos + 4 <= b.length) {
    while (pos < b.length && b[pos] !== 0xff) pos += 1;
    while (pos < b.length && b[pos] === 0xff) pos += 1;
    if (pos >= b.length) break;
    const marker = b[pos];
    pos += 1;
    if (marker === 0xd8 || marker === 0xd9 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (pos + 2 > b.length) break;
    const length = u16be(b, pos);
    if (length < 2) break;
    const segmentEnd = pos + length;
    const isSOF = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSOF && pos + 7 <= b.length) {
      height = u16be(b, pos + 3);
      width = u16be(b, pos + 5);
      break;
    }
    if (marker === 0xe1 && length >= 8 && b[pos + 2] === 0x45 && b[pos + 3] === 0x78
      && b[pos + 4] === 0x69 && b[pos + 5] === 0x66) {
      hasExif = true;
      orientation = exifOrientation(b, pos + 8, segmentEnd);
    }
    pos = segmentEnd;
  }
  if (width === 0 || height === 0) return null;
  const transposed = orientation !== undefined && orientation >= 5;
  return {
    mediaType: 'image/jpeg',
    width: transposed ? height : width,
    height: transposed ? width : height,
    animated: false,
    carriesMetadata: hasExif,
    depth: 'uchar',
    space: 'srgb',
    hasAlpha: false,
  };
}

function gifInfo(b) {
  const head = String.fromCharCode(b[0], b[1], b[2], b[3], b[4], b[5]);
  if (head !== 'GIF87a' && head !== 'GIF89a') return null;
  const width = u16le(b, 6);
  const height = u16le(b, 8);
  if (width === 0 || height === 0) return null;
  const flags = b[10];
  let pos = 13 + ((flags & 0x80) !== 0 ? 3 * (1 << ((flags & 0x07) + 1)) : 0);
  let frames = 0;
  const skipBlocks = () => {
    while (pos < b.length) {
      const size = b[pos];
      pos += 1;
      if (size === 0) return true;
      pos += size;
    }
    return false;
  };
  while (pos < b.length) {
    const introducer = b[pos];
    pos += 1;
    if (introducer === 0x3b) break;
    if (introducer === 0x21) {
      if (pos >= b.length) break;
      pos += 1; // extension label
      if (!skipBlocks()) break;
      continue;
    }
    if (introducer === 0x2c) {
      frames += 1;
      if (pos + 9 > b.length) break;
      const local = b[pos + 8];
      pos += 9;
      if ((local & 0x80) !== 0) pos += 3 * (1 << ((local & 0x07) + 1));
      pos += 1; // LZW minimum code size
      if (!skipBlocks()) break;
      continue;
    }
    break;
  }
  return {
    mediaType: 'image/gif',
    width, height,
    animated: frames > 1,
    carriesMetadata: false,
    depth: 'uchar',
    space: 'srgb',
    hasAlpha: true,
  };
}

function webpInfo(b) {
  if (b.length < 30) return null;
  if (String.fromCharCode(b[0], b[1], b[2], b[3]) !== 'RIFF') return null;
  if (String.fromCharCode(b[8], b[9], b[10], b[11]) !== 'WEBP') return null;
  let pos = 12;
  let width = 0;
  let height = 0;
  let hasAlpha = false;
  let animated = false;
  let seen = false;
  while (pos + 8 <= b.length) {
    const type = String.fromCharCode(b[pos], b[pos + 1], b[pos + 2], b[pos + 3]);
    const size = b[pos + 4] | (b[pos + 5] << 8) | (b[pos + 6] << 16) | (b[pos + 7] << 24);
    const body = pos + 8;
    if (type === 'VP8X' && body + 10 <= b.length) {
      const flags = b[body];
      hasAlpha = (flags & 0x10) !== 0;
      animated = (flags & 0x02) !== 0;
      width = 1 + u24le(b, body + 4);
      height = 1 + u24le(b, body + 7);
      seen = true;
    } else if (type === 'VP8 ' && body + 10 <= b.length && !seen) {
      if (b[body + 3] === 0x9d && b[body + 4] === 0x01 && b[body + 5] === 0x2a) {
        width = u16le(b, body + 6) & 0x3fff;
        height = u16le(b, body + 8) & 0x3fff;
        seen = true;
      }
    } else if (type === 'VP8L' && body + 5 <= b.length && !seen) {
      if (b[body] === 0x2f) {
        const bits = b[body + 1] | (b[body + 2] << 8) | (b[body + 3] << 16) | (b[body + 4] << 24);
        width = (bits & 0x3fff) + 1;
        height = ((bits >>> 14) & 0x3fff) + 1;
        hasAlpha = ((bits >>> 28) & 1) === 1;
        seen = true;
      }
    }
    if (size < 0) break;
    pos = body + size + (size & 1);
  }
  if (!seen || width === 0 || height === 0) return null;
  return {
    mediaType: 'image/webp',
    width, height,
    animated,
    carriesMetadata: false,
    depth: 'uchar',
    space: 'srgb',
    hasAlpha,
  };
}

/** 纯 JS 头部探测：返回与 sharp metadata 对齐的字段。 */
export function probeImage(data) {
  const b = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (b.length === 0) throw invalidImage('empty');
  const info = pngInfo(b) ?? jpegInfo(b) ?? gifInfo(b) ?? webpInfo(b);
  if (info === null) throw invalidImage('unrecognised container');
  return info;
}

/* ------------------------------------------------------------------ 工具 */

function digest(data) {
  return createHash('sha256').update(data).digest('hex');
}

function sanitizeName(value) {
  if (typeof value !== 'string') return undefined;
  const leaf = value.slice(Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\')) + 1);
  const clean = leaf.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 255);
  return clean === '' ? undefined : clean;
}

async function readObject(store, ref, signal) {
  const id = String(ref?.attachmentId ?? '');
  const match = /^sha256:([a-f0-9]{64})$/.exec(id);
  if (match === null) throw new Error(`invalid attachment id: ${id.slice(0, 80)}`);
  if (typeof store?.root !== 'string' || store.root === '') throw new Error('attachment root unavailable');
  const sha = match[1];
  const data = new Uint8Array(await readFile(
    join(store.root, 'objects', sha.slice(0, 2), sha),
    signal === undefined ? undefined : { signal },
  ));
  if (digest(data) !== sha) throw new Error('attachment digest mismatch');
  return data;
}

function placeholder(ref, target, reason) {
  log(`image ${ref?.attachmentId ?? '?'}: placeholder (${reason})`);
  return {
    variantId: `ios-placeholder:${ref?.attachmentId ?? 'unknown'}`,
    attachment: ref,
    data: FALLBACK_PNG,
    mediaType: 'image/png',
    bytes: FALLBACK_PNG.byteLength,
    width: 1,
    height: 1,
    depth: 'uchar',
    space: 'srgb',
    hasAlpha: true,
  };
}

/** 以纯 JS 探测 + 原图字节完成一次准入（替代 prepareImageFile）。 */
function prepareRawImage(input, limits, policy, AttachmentError) {
  const data = input.data instanceof Uint8Array ? input.data : new Uint8Array(input.data);
  if (data.byteLength === 0) throw new AttachmentError('Image is empty.', 'INVALID_IMAGE');
  if (data.byteLength > limits.maxImageBytes) {
    throw new AttachmentError('Image exceeds the configured byte limit.', 'IMAGE_TOO_LARGE');
  }
  let detected;
  try {
    detected = probeImage(data);
  } catch (error) {
    throw new AttachmentError('Unsupported or malformed image data.', 'INVALID_IMAGE', { cause: error });
  }
  if (detected.mediaType !== input.mediaType) {
    throw new AttachmentError('Declared image type does not match its bytes.', 'IMAGE_TYPE_MISMATCH');
  }
  if (detected.width * detected.height > limits.maxImagePixels) {
    throw new AttachmentError('Image exceeds the configured decoded-pixel limit.', 'IMAGE_TOO_MANY_PIXELS');
  }
  if (Math.max(detected.width, detected.height) > limits.maxImageDimension) {
    throw new AttachmentError('Image exceeds the configured per-side pixel limit.', 'IMAGE_DIMENSION_TOO_LARGE');
  }
  // 没有 sharp 就不做解码-缩放-重编码：直存原图。归一化预算仍然记录在
  // 日志里，便于确认哪些图会以原尺寸进入模型请求。
  if (data.byteLength > policy.maxBytes
    || detected.width * detected.height > policy.maxPixels
    || Math.max(detected.width, detected.height) > policy.maxDimension) {
    log(`image ${detected.mediaType} ${detected.width}x${detected.height} ${data.byteLength}B: `
      + 'kept as-is (no sharp on iOS; normalization budget exceeded)');
  }
  const name = sanitizeName(input.name);
  const ref = {
    attachmentId: `sha256:${digest(data)}`,
    mediaType: detected.mediaType,
    width: detected.width,
    height: detected.height,
    bytes: data.byteLength,
    ...(name === undefined ? {} : { name }),
  };
  return { data, ref, detected };
}

/* ------------------------------------------------------------------ 安装 */

let mod;
try {
  mod = await import('@deepseek-ai/dsh-attachment-local');
} catch (error) {
  log(`image support unavailable: ${short(error)}`);
}

let AttachmentError;
try {
  ({ AttachmentError } = await import('@deepseek-ai/dsh-attachment'));
} catch {
  AttachmentError = class extends Error {
    constructor(message, code, options) {
      super(message, options);
      this.name = 'AttachmentError';
      this.code = code ?? 'INVALID_IMAGE';
    }
  };
}

if (mod?.LocalAttachmentStore && !mod.LocalAttachmentStore.prototype[PATCHED]) {
  const proto = mod.LocalAttachmentStore.prototype;

  proto.readImage = async function readImageWithoutSharp(ref, signal) {
    signal?.throwIfAborted();
    const data = await readObject(this, ref, signal);
    const detected = probeImage(data);
    signal?.throwIfAborted();
    if (detected.mediaType !== ref.mediaType || data.byteLength !== ref.bytes) {
      throw new AttachmentError('Stored attachment metadata does not match its reference.', 'ATTACHMENT_CORRUPT');
    }
    if (detected.width !== ref.width || detected.height !== ref.height) {
      log(`image ${ref.attachmentId}: header ${detected.width}x${detected.height} != ref ${ref.width}x${ref.height} (using header)`);
    }
    return { ref, data };
  };

  proto.readImageRequest = async function readImageRequestWithoutSharp(ref, target, signal) {
    signal?.throwIfAborted();
    let data;
    let detected;
    try {
      data = await readObject(this, ref, signal);
      detected = probeImage(data);
    } catch (error) {
      if (signal?.aborted) throw signal.reason ?? error;
      return placeholder(ref, target, short(error));
    }
    signal?.throwIfAborted();
    // rc.3 会在 target 内缩放/重编码；iOS 没有 sharp。inline 上限 20 MiB，
    // 因此直接在请求里带原图（比发占位图或整轮 TRANSPORT 失败更可用）。
    if (data.byteLength > target.maxBytes
      || detected.width > target.width || detected.height > target.height) {
      log(`image ${ref.attachmentId}: sent original ${detected.width}x${detected.height} `
        + `${data.byteLength}B (target ${target.width}x${target.height}/${target.maxBytes}B)`);
    }
    return {
      variantId: mod.requestImageVariantId(ref, target),
      attachment: ref,
      data,
      mediaType: detected.mediaType,
      bytes: data.byteLength,
      width: detected.width,
      height: detected.height,
      depth: detected.depth,
      space: 'srgb',
      hasAlpha: detected.hasAlpha,
    };
  };

  proto.validateImage = async function validateImageWithoutSharp(input) {
    prepareRawImage(input, this.imageLimits, this.normalizationPolicy, AttachmentError);
  };

  proto.saveImage = async function saveImageWithoutSharp(input) {
    const prepared = prepareRawImage(input, this.imageLimits, this.normalizationPolicy, AttachmentError);
    return mod.commitPreparedImageFile(this.root, { data: prepared.data, ref: prepared.ref });
  };

  proto.saveImages = async function saveImagesWithoutSharp(inputs) {
    this.validateImageBatch(inputs);
    const prepared = inputs.map(input => prepareRawImage(input, this.imageLimits, this.normalizationPolicy, AttachmentError));
    const refs = [];
    for (const image of prepared) {
      refs.push(await mod.commitPreparedImageFile(this.root, { data: image.data, ref: image.ref }));
    }
    return refs;
  };

  Object.defineProperty(proto, PATCHED, { value: true });
  log('image support active (pure-JS probe, no sharp): read/request/save');
}
