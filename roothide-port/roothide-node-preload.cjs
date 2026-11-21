'use strict';

const fs = require('node:fs');
const cp = require('node:child_process');
const mod = require('node:module');
const util = require('node:util');
const { fileURLToPath, pathToFileURL, URL } = require('node:url');
const path = require('node:path').posix;

const root = process.env.DSH_JBROOT;
if (typeof root !== 'string' || root === '/' || !root.startsWith('/') || path.normalize(root).replace(/\/$/, '') !== root) {
  throw new Error('DSH roothide preload needs the native launcher’s absolute DSH_JBROOT');
}
const launcher = `${root}/usr/lib/dsh/bin/node`;
const preload = `${root}/usr/lib/dsh/roothide-node-preload.cjs`;
const under = (s, base) => s === base || s.startsWith(`${base}/`);
const toReal = (s) => {
  if (typeof s !== 'string') return s;
  if (under(s, '/var/jb')) return root + s.slice(7);
  if (under(s, '/rootfs')) return s.slice(7) || '/';
  return s;
};
const toVirtual = (s) => {
  if (typeof s !== 'string' || !s.startsWith('/')) return s;
  if (under(s, '/var/jb')) return s.slice(7) || '/';
  if (under(s, root)) return s.slice(root.length) || '/';
  if (under(s, '/rootfs')) return s;
  return `/rootfs${s}`;
};
const fsPath = (p) => {
  if (p instanceof URL && p.protocol === 'file:') {
    const old = fileURLToPath(p);
    const updated = toReal(old);
    return old === updated ? p : pathToFileURL(updated);
  }
  if (Buffer.isBuffer(p)) {
    // Preserve arbitrary pathname bytes, not just UTF-8.
    for (const [from, to] of [['/var/jb', root], ['/rootfs', '']]) {
      if (p.subarray(0, from.length).equals(Buffer.from(from)) &&
          (p.length === from.length || p[from.length] === 47)) {
        return p.length === from.length ? Buffer.from(to || '/') : Buffer.concat([Buffer.from(to), p.subarray(from.length)]);
      }
    }
    return p;
  }
  return toReal(p);
};

// Capture originals; wrapped methods can call another wrapped method safely
// because translation is idempotent for all normal real paths.
const patchPath = (holder, name, n = 1) => {
  const fn = holder[name];
  if (typeof fn !== 'function') return;
  const wrap = (original) => function (...args) {
    for (let i = 0; i < Math.min(n, args.length); i++) args[i] = fsPath(args[i]);
    return Reflect.apply(original, this, args);
  };
  const wrapper = wrap(fn);
  if (typeof fn.native === 'function') wrapper.native = wrap(fn.native);
  const custom = Object.getOwnPropertyDescriptor(fn, util.promisify.custom);
  if (custom && typeof custom.value === 'function') {
    Object.defineProperty(wrapper, util.promisify.custom, { ...custom, value: wrap(custom.value) });
  }
  holder[name] = wrapper;
};
const one = ('access appendFile chmod chown exists glob lchmod lchown lstat lutimes mkdir mkdtemp open opendir readFile readdir readlink realpath rm rmdir stat statfs truncate unlink utimes writeFile').split(' ');
const two = 'copyFile cp link rename symlink'.split(' ');
for (const [names, count] of [[one, 1], [two, 2]]) {
  for (const name of names) {
    patchPath(fs, name, count);
    patchPath(fs, `${name}Sync`, count);
    patchPath(fs.promises, name, count);
  }
}
for (const name of ['createReadStream', 'createWriteStream', 'watch', 'watchFile', 'unwatchFile']) patchPath(fs, name);
patchPath(process, 'chdir');
patchPath(process, 'dlopen', 0); // handled separately: filename is the second argument
const originalDlopen = process.dlopen;
process.dlopen = function (module, filename, ...rest) {
  return Reflect.apply(originalDlopen, this, [module, fsPath(filename), ...rest]);
};

// Node 24's require.resolve calls the CommonJS resolver directly, outside registerHooks.
const originalResolveFilename = mod._resolveFilename;
mod._resolveFilename = function (request, ...args) {
  return Reflect.apply(originalResolveFilename, this, [toReal(request), ...args]);
};

if (typeof mod.registerHooks !== 'function') throw new Error('DSH roothide preload requires Node 24 module hooks');
mod.registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith('file:')) {
      const original = new URL(specifier);
      const updated = fsPath(original);
      if (original !== updated) {
        updated.search = original.search;
        updated.hash = original.hash;
        specifier = updated.href;
      }
    } else {
      specifier = toReal(specifier);
    }
    return nextResolve(specifier, context);
  },
});

const realExists = (p) => {
  try { fs.accessSync(p, fs.constants.X_OK); return true; } catch { return false; }
};
const bootstrapDirs = ['/usr/bin', '/bin', '/usr/sbin', '/sbin', '/usr/lib/dsh/bin'];
const shellEnv = /^(?:HOME|DSH_HOME|DSH_NODE|NODE_PATH|TMPDIR|PWD|OLDPWD|PNPM_HOME|XDG_[A-Z_]+|(?:npm_config|NPM_CONFIG)_(?:cache|CACHE|store_dir|STORE_DIR|userconfig|USERCONFIG)|GIT_(?:WORK_TREE|DIR|EXEC_PATH|INDEX_FILE))$/;
function transformArg(arg, convert) {
  if (typeof arg !== 'string') return arg;
  if (arg.startsWith('/')) return convert(arg);
  const match = /^(--[a-z0-9-]+=)(\/.*)$/i.exec(arg);
  return match ? match[1] + convert(match[2]) : arg;
}
function explicitBootstrap(file) {
  return bootstrapDirs.some(dir => path.dirname(file) === dir) && realExists(root + file);
}
function resolveExecutable(file, env, cwd) {
  let executable = toReal(file);
  if (typeof file === 'string' && !under(file, '/rootfs') && explicitBootstrap(executable)) executable = root + executable;
  if (typeof executable === 'string' && !executable.includes('/')) {
    for (const dir of (env.PATH || '').split(':')) {
      const candidate = path.resolve(cwd || process.cwd(), toReal(dir), executable);
      if (realExists(candidate)) { executable = candidate; break; }
    }
  }
  const native = executable === process.execPath || executable === launcher || executable === `${launcher}-real` ||
    executable === `${root}/usr/bin/mcp-logreader` || executable === `${root}/usr/bin/dsh-app-helper`;
  return { executable, native, bootstrap: typeof executable === 'string' && under(executable, root) && !native };
}
function commandSpec(file, args, options) {
  const opts = { ...options };
  const inputEnv = opts.env ?? process.env;
  if (opts.cwd != null) opts.cwd = fsPath(opts.cwd);
  const cwd = opts.cwd instanceof URL ? fileURLToPath(opts.cwd) : opts.cwd;
  const usesShell = !!opts.shell;
  const shellCommand = usesShell ? (typeof opts.shell === 'string' ? opts.shell : '/bin/sh') : file;
  const { executable, native, bootstrap } = resolveExecutable(shellCommand, inputEnv, cwd);
  const convert = bootstrap ? toVirtual : toReal;
  const env = { ...inputEnv };
  // PATH is actual for Node/libuv, logical for libvroot. Directory entries in
  // an explicitly supplied env may still use the recognized legacy prefix.
  if (typeof env.PATH === 'string') {
    env.PATH = env.PATH.split(':').map(convert).join(':');
  }
  for (const key of Object.keys(env)) {
    if (!shellEnv.test(key) || typeof env[key] !== 'string') continue;
    env[key] = key === 'NODE_PATH' ? env[key].split(':').map(convert).join(':') : convert(env[key]);
  }
  if (native && (executable === launcher || executable === process.execPath || executable === `${launcher}-real`)) {
    env.DSH_JBROOT = root;
    env.DSH_HOME = toReal(env.DSH_HOME || process.env.DSH_HOME);
  }
  opts.env = env;
  // Do not parse or rewrite shell source. For `sh -c script name arg...`,
  // the script is opaque but positional arguments after it may be path operands.
  const shellSourceIndex = /\/(?:ba|da|z|a)?sh$/.test(executable) ? args.indexOf('-c') + 1 : 0;
  const isNode = executable === launcher || executable === process.execPath || executable === `${launcher}-real`;
  const evalAt = isNode ? args.findIndex(arg => ['-e', '-p', '--eval', '--print', '-pe', '-ep'].includes(arg)) : -1;
  const mapped = usesShell ? args : args.map((arg, i) => (evalAt >= 0 && i === evalAt + 1) ||
    (shellSourceIndex > 0 && (i === shellSourceIndex || i === shellSourceIndex + 1)) ? arg : transformArg(arg, convert));
  if (usesShell) opts.shell = executable;
  return [usesShell ? file : executable, mapped, opts];
}

function optionalArgs(args, options) {
  return Array.isArray(args) ? [args, options] : [[], options || args];
}
for (const name of ['spawn', 'spawnSync', 'execFileSync']) {
  const original = cp[name];
  cp[name] = function (file, args, options) {
    return original(...commandSpec(file, ...optionalArgs(args, options)));
  };
}
const originalExecFile = cp.execFile;
cp.execFile = function (file, args, options, callback) {
  if (!Array.isArray(args)) {
    callback = typeof args === 'function' ? args : options;
    options = typeof args === 'object' ? args : undefined;
    args = [];
  } else if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  return originalExecFile(...commandSpec(file, args, options), callback);
};
const originalExec = cp.exec;
cp.exec = function (command, options, callback) {
  if (typeof options === 'function') { callback = options; options = undefined; }
  // Node's exec delegates to the public execFile; its wrapper does the mapping.
  return originalExec(command, options, callback);
};
const originalExecSync = cp.execSync;
cp.execSync = function (command, options) {
  return originalExecSync(command, commandSpec(command, [], { ...options, shell: options?.shell || true })[2]);
};
for (const name of ['execFile', 'exec']) {
  Object.defineProperty(cp[name], util.promisify.custom, {
    value: (...args) => {
      let child;
      const promise = new Promise((resolve, reject) => {
        child = cp[name](...args, (error, stdout, stderr) => {
          if (error) reject(Object.assign(error, { stdout, stderr }));
          else resolve({ stdout, stderr });
        });
      });
      promise.child = child;
      return promise;
    },
  });
}
const originalFork = cp.fork;
cp.fork = function (modulePath, args, options) {
  [args, options] = optionalArgs(args, options);
  const opts = { ...options, shell: false };
  const executable = opts.execPath || process.execPath;
  const [file, _args, translated] = commandSpec(executable, [], opts);
  translated.execPath = file;
  if (file === process.execPath || file === `${launcher}-real`) {
    const execArgv = opts.execArgv ?? process.execArgv;
    translated.execArgv = execArgv.includes(preload) || execArgv.includes(`--require=${preload}`)
      ? execArgv : ['--require', preload, ...execArgv];
  }
  return originalFork(fsPath(modulePath), args, translated);
};

mod.syncBuiltinESMExports();
