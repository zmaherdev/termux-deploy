#!/data/data/com.termux/files/usr/bin/bash
# Install @deepseek-ai/dsh on Termux (Android) and patch it into a working state.
#
# This script applies all known Android/Termux compatibility fixes:
#   1. node-gyp: strips OS=android (no NDK path configured).
#   2. sharp: builds against Termux's system libvips (no prebuilt binary).
#   3. session-persistence: link() -> rename() (Android blocks hard links).
#   4. attachment-local: fsync walk tolerates EACCES; link() -> rename().
#   5. shebang: adds --expose-internals to bypass Node internals restriction.
#   6. fs-local: link() -> copyFile(O_EXCL) fallback (preserves no-replace semantics).
#   7. node-addon-require-builtin: compiles native binding for Android.
#   8. flock: stubs out the missing native binding (single-process mode).
#   9. imports: fixes missing rename/copyFile declarations after patches.

set -euo pipefail

NDK_TARGET="aarch64-unknown-linux-android30"

log() { printf '\033[1;36m[%s/%s]\033[0m %s\n' "$1" "$2" "$3"; }

# Auto-scan for a DeepSeek API key across common sources and print the first
# match. Priority: environment, dsh's credential store, shell rc files, then
# standalone key files. Prints nothing and returns 1 when no key is found.
find_deepseek_key() {
    local key f creds
    if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
        printf '%s' "$DEEPSEEK_API_KEY"; return 0
    fi
    creds="${DSH_HOME:-$HOME/.dsh}/.credentials.yaml"
    if [ -f "$creds" ]; then
        key="$(grep -E 'DEEPSEEK_API_KEY[[:space:]]*:' "$creds" | head -1 \
            | sed -E 's/.*DEEPSEEK_API_KEY[[:space:]]*:[[:space:]]*//' | tr -d " \t\r")"
        key="${key#\"}"; key="${key%\"}"; key="${key#\'}"; key="${key%\'}"
        [ -n "$key" ] && { printf '%s' "$key"; return 0; }
    fi
    for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        [ -f "$f" ] || continue
        key="$(grep -E '^[[:space:]]*export[[:space:]]+DEEPSEEK_API_KEY=' "$f" | head -1 \
            | sed -E 's/^[[:space:]]*export[[:space:]]+DEEPSEEK_API_KEY=//' | tr -d " \t\r")"
        key="${key#\"}"; key="${key%\"}"; key="${key#\'}"; key="${key%\'}"
        [ -n "$key" ] && { printf '%s' "$key"; return 0; }
    done
    for f in "$HOME/.deepseek_api_key" "$HOME/.deepseek"; do
        [ -f "$f" ] || continue
        key="$(head -1 "$f" | tr -d " \t\r\n")"
        key="${key#\"}"; key="${key%\"}"; key="${key#\'}"; key="${key%\'}"
        [ -n "$key" ] && { printf '%s' "$key"; return 0; }
    done
    return 1
}

log 1 12 "Installing prerequisites (node, python, build tools, libvips, unzip)..."
pkg install -y nodejs build-essential clang cmake ninja python libvips unzip curl >/dev/null

# Resolve Node/npm paths only now that nodejs is installed.
if ! NODE_BIN="$(command -v node)"; then
    echo "error: 'node' not found after 'pkg install -y nodejs'; NODE_BIN is empty" >&2
    exit 1
fi
NODE_GYP_BIN="$(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js"
DSH_LIB="$(npm root -g)/@deepseek-ai/dsh"

# pnpm is required to build node-addon-require-builtin later.
if ! command -v pnpm >/dev/null 2>&1; then
    echo "    Installing pnpm..."
    npm install -g pnpm >/dev/null
fi

log 2 12 "Patching node-gyp (drop bogus OS=android)..."
CREATE_GYPI="$(npm root -g)/npm/node_modules/node-gyp/lib/create-config-gypi.js"
if [ ! -f "$CREATE_GYPI" ]; then
    echo "error: node-gyp not found at $CREATE_GYPI" >&2
    exit 1
fi
if grep -q "delete variables.OS" "$CREATE_GYPI"; then
    echo "    node-gyp already patched, skipping."
else
    python3 - "$CREATE_GYPI" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
anchor = "const variables = config.variables\n"
assert anchor in src, "patch anchor not found; node-gyp may have changed"
block = (
    anchor + "\n"
    + "  // Termux's Node.js reports process.config.variables.OS as \"android\" even\n"
    + "  // though native addons build against the Termux (linux-like) sysroot, not\n"
    + "  // the Android NDK. gyp's \"OS == android\" branches then reference the\n"
    + "  // undefined android_ndk_path variable and fail. Drop OS so gyp infers it\n"
    + "  // as \"linux\" from the host platform.\n"
    + "  delete variables.OS\n"
)
open(path, "w", encoding="utf-8").write(src.replace(anchor, block, 1))
print("    patched", path)
PY
fi

log 3 12 "Installing @deepseek-ai/dsh (native modules will be compiled)..."
export CFLAGS="--target=$NDK_TARGET"
export CXXFLAGS="--target=$NDK_TARGET"
npm install -g @deepseek-ai/dsh

log 4 12 "Building sharp against system libvips..."
SHARP_DIR="$DSH_LIB/node_modules/sharp"
if compgen -G "$SHARP_DIR/src/build/Release/sharp-android-arm64-*.node" >/dev/null; then
    echo "    sharp already built, skipping."
else
    (cd "$SHARP_DIR" && SHARP_FORCE_GLOBAL_LIBVIPS=1 \
        CFLAGS="--target=$NDK_TARGET" CXXFLAGS="--target=$NDK_TARGET" \
        "$NODE_BIN" "$NODE_GYP_BIN" rebuild --directory=src >/dev/null)
fi

log 5 12 "Patching session persistence (hard link -> rename)..."
SESSION_JS="$DSH_LIB/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
if [ -f "$SESSION_JS" ]; then
    if grep -q "await rename(tmp, finalPath)" "$SESSION_JS"; then
        echo "    session persistence already patched, skipping."
    else
        python3 - "$SESSION_JS" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace(
    'import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";',
    'import { mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, stat, truncate } from "node:fs/promises";',
)
src = src.replace(
    "\t\t\tawait link(tmp, finalPath);",
    "\t\t\tawait rename(tmp, finalPath);",
)
open(path, "w", encoding="utf-8").write(src)
print("    patched", path)
PY
    fi
else
    echo "    warning: session persistence module not found, skipping."
fi

log 6 12 "Patching attachment store (durability walk + hard link fallback)..."
ATTACH_JS="$DSH_LIB/node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js"
if [ ! -f "$ATTACH_JS" ]; then
    echo "    warning: attachment module not found, skipping (read_image will not work)."
elif grep -q "termux-hardlink-fallback" "$ATTACH_JS"; then
    echo "    attachment store already patched, skipping."
else
    python3 - "$ATTACH_JS" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

if "termux-hardlink-fallback" in src:
    print("    already patched")
    sys.exit(0)


def once(old, new):
    global src
    assert src.count(old) == 1, "patch anchor not found (%d matches); dsh may have changed" % src.count(old)
    src = src.replace(old, new, 1)


once(
    "\tconst handle = await open(path, constants.O_RDONLY);",
    "\tlet handle;\n"
    "\ttry {\n"
    "\t\thandle = await open(path, constants.O_RDONLY);\n"
    "\t} catch (error) {\n"
    "\t\t/* termux-durability-guard */\n"
    "\t\tif (error.code === \"EACCES\" || error.code === \"EPERM\" || error.code === \"ENOENT\") return;\n"
    "\t\tthrow error;\n"
    "\t}",
)

helpers = (
    "/**\n"
    " * Publish one staged object into place.\n"
    " * POSIX links are the cheapest atomic publish, but Android refuses link()\n"
    " * for untrusted apps (EACCES: no hard links). rename() inside the same\n"
    " * private root is equally atomic, so fall back to it. rename() replaces an\n"
    " * existing target instead of raising EEXIST, which is safe here because\n"
    " * targets are content-addressed: an object already at `target` holds the\n"
    " * same digest as the bytes being published.\n"
    " */\n"
    "/* termux-hardlink-fallback */\n"
    "async function publishStagedName(source, target) {\n"
    "\ttry {\n"
    "\t\tawait link(source, target);\n"
    "\t} catch (error) {\n"
    "\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"EACCES\")) throw error;\n"
    "\t\tawait rename(source, target);\n"
    "\t}\n"
    "}\n"
    "/** Remove a staging name, tolerating one already consumed by the rename fallback. */\n"
    "async function removeStagedName(path) {\n"
    "\ttry {\n"
    "\t\tawait unlink(path);\n"
    "\t} catch (error) {\n"
    "\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"ENOENT\")) throw error;\n"
    "\t}\n"
    "}\n"
    "async function publishStagedObject(root, target, staged) {"
)
once("async function publishStagedObject(root, target, staged) {", helpers)
once("\t\t\tawait link(staged.path, target);", "\t\t\tawait publishStagedName(staged.path, target);")
once("\t\t\tawait link(source, target);", "\t\t\tawait publishStagedName(source, target);")
assert src.count("\t\tawait unlink(staged.path);") == 1, "staging unlink anchor not found"
src = src.replace("\t\tawait unlink(staged.path);", "\t\tawait removeStagedName(staged.path);")

open(path, "w", encoding="utf-8").write(src)
print("    patched", path)
PY
fi

log 7 12 "Fixing shebang (node --expose-internals)..."
DSH_BIN="$DSH_LIB/lib/bin.js"
if [ -f "$DSH_BIN" ]; then
    python3 - "$DSH_BIN" "$NODE_BIN" <<'PY'
import sys
path, node = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
first, _, rest = src.partition("\n")
if not first.startswith("#!"):
    sys.exit("no shebang on first line")
src = "#!" + node + " --expose-internals\n" + rest
open(path, "w", encoding="utf-8").write(src)
print("    shebang set:", node, "--expose-internals")
PY
fi

log 8 12 "Patching file publication (hard link -> O_EXCL copy fallback)..."
FS_LOCAL_JS="$DSH_LIB/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js"
if [ ! -f "$FS_LOCAL_JS" ]; then
    echo "    warning: fs-local module not found, skipping (write/edit tools will not work)."
elif grep -q "termux-noreplace-fallback" "$FS_LOCAL_JS"; then
    echo "    file publication already patched, skipping."
else
    python3 - "$FS_LOCAL_JS" <<'PY'
import re, sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

if "termux-noreplace-fallback" in src:
    print("    already patched")
    sys.exit(0)

pat = re.compile(
    r"^([ \t]*)await (linkFile|link)\(\s*(\w+)\s*,\s*(\w+)\s*\)[ \t]*;?[ \t]*$",
    re.MULTILINE,
)
matches = list(pat.finditer(src))
if not matches:
    sys.exit("    error: no await link/linkFile(<tmp>, <dst>) call found")
guard = src.find("throwGuardedCreateFailure")
if guard != -1 and len(matches) > 1:
    matches.sort(key=lambda m: abs(m.start() - guard))
m = matches[0]
indent, fn, tmp_var, dest_var = m.group(1), m.group(2), m.group(3), m.group(4)

# Android refuses link() with EACCES. copyFile with O_CREAT|O_EXCL preserves
# the createIfAbsent (no-overwrite) semantics: it throws EEXIST if the target
# exists, which the surrounding guard converts into a normal guarded failure.
# COPYFILE_EXCL is the literal 1.
wrapped = (
    f"{indent}try {{\n"
    f"{indent}\tawait {fn}({tmp_var}, {dest_var});\n"
    f"{indent}}} catch (error) {{\n"
    f"{indent}\t/* termux-noreplace-fallback */\n"
    f"{indent}\tif (!(error instanceof Error && \"code\" in error && error.code === \"EACCES\")) throw error;\n"
    f"{indent}\tawait copyFile({tmp_var}, {dest_var}, 1);\n"
    f"{indent}}}"
)
src = src[:m.start()] + wrapped + src[m.end():]

open(path, "w", encoding="utf-8").write(src)
print(f"    patched {path} (wrapped {fn}({tmp_var}, {dest_var}))")
PY
fi

log 9 12 "Building node-addon-require-builtin for Android..."
NARB_TARGET="$DSH_LIB/node_modules/node-addon-require-builtin/build/napi/napi-v9-android-arm64/require_builtin.node"
if [ -f "$NARB_TARGET" ]; then
    echo "    require_builtin.node already exists, skipping."
else
    WORK="${NARB_WORK:-$HOME/.cache/dsh-require-builtin}"
    mkdir -p "$WORK"; cd "$WORK"
    [ -f narb.zip ] || curl -fsSL -o narb.zip \
        "https://github.com/deepseek-ai/dsh-node-addon-require-builtin/archive/refs/heads/master.zip"
    rm -rf src; mkdir src
    unzip -q -o narb.zip -d src
    cd src/*/

    # pnpm@9.15.9 has no android-arm64 binary; drop the pin.
    sed -i '/"packageManager"/d' package.json

    # Let scripts/build.ts treat android like linux.
    sed -i 's|throw new Error(`unsupported platform for direct build: ${process.platform}`);|return ["-shared", "-fPIC", "-pthread", ...args];|' scripts/build.ts

    # Two small bionic patches: route __linux__ && __aarch64__ (Android)
    # through the already-platform-neutral arm64 readers.
    python3 - <<'PY'
import pathlib
ctx = pathlib.Path('packages/native/src/runtime_context/platform.cc')
s = ctx.read_text()
s = s.replace(
    '#elif defined(__linux__) && defined(__GLIBC__) && defined(__aarch64__)\nreturn ReadLinuxGlibcArm64CurrentV8Context(isolate, symbols);',
    '#elif defined(__linux__) && defined(__GLIBC__) && defined(__aarch64__)\nreturn ReadLinuxGlibcArm64CurrentV8Context(isolate, symbols);\n#elif defined(__linux__) && defined(__aarch64__)\n// Android/bionic\nreturn ReadLinuxGlibcArm64CurrentV8Context(isolate, symbols);'
)
ctx.write_text(s)

probe = pathlib.Path('packages/native/src/runtime_probe/platform.cc')
s = probe.read_text()
s = s.replace(
    '#elif defined(__linux__) && defined(__GLIBC__) && defined(__aarch64__)\nreturn ParseLinuxGlibcArm64BuiltinModuleRequireGetterOffset(getter);',
    '#elif defined(__linux__) && defined(__GLIBC__) && defined(__aarch64__)\nreturn ParseLinuxGlibcArm64BuiltinModuleRequireGetterOffset(getter);\n#elif defined(__linux__) && defined(__aarch64__)\n// Android/bionic\nreturn ParseLinuxGlibcArm64BuiltinModuleRequireGetterOffset(getter);'
)
probe.write_text(s)
PY

    export NARB_PRODUCT=require-builtin
    pnpm install --ignore-scripts --config.manage-package-manager-versions=false --config.pmOnFail=ignore
    pnpm build

    mkdir -p "$(dirname "$NARB_TARGET")"
    cp packages/require-builtin/entry/build/napi/napi-v9-android-arm64/require_builtin.node \
       "$NARB_TARGET"
    echo "    installed $NARB_TARGET"
fi

log 10 12 "Stubbing flock.js (Android lacks native addon)..."
FLOCK_JS="$DSH_LIB/node_modules/@deepseek-ai/node-addon-system/lib/flock.js"
if [ -f "$FLOCK_JS" ]; then
    if grep -q "termux-flock-stub" "$FLOCK_JS"; then
        echo "    flock.js already stubbed, skipping."
    else
        python3 - "$FLOCK_JS" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()

if "termux-flock-stub" in src:
    sys.exit(0)

old = "    const { platform, arch } = process;"
new = """    const { platform, arch } = process;
    if (platform === 'android') {
        /* termux-flock-stub */
        // Single-process harness: emulate an acquired lock.
        // Android lacks the native addon, so we bypass it entirely.
        return { tryLock: (_fd, cb) => cb(0) };
    }"""

if old not in src:
    sys.exit("    error: could not find loadBinding anchor.")

src = src.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(src)
print("    patched", path)
PY
    fi
fi

log 11 12 "Fixing fs/promises imports (rename, copyFile)..."
python3 - <<'PY'
import os, re, subprocess

root = subprocess.check_output(["npm", "root", "-g"]).decode().strip()
dsh = os.path.join(root, "@deepseek-ai/dsh/node_modules/@deepseek-ai")

paths = [
    os.path.join(dsh, "dsh-session-persistence-jsonl/lib/index.js"),
    os.path.join(dsh, "dsh-fs-local/lib/index.js")
]

for path in paths:
    if not os.path.exists(path):
        continue
    src = open(path, encoding="utf-8").read()
    orig = src

    def fix_import(m):
        body = m.group(1)
        parts = [p.strip() for p in body.split(',') if p.strip()]
        for n in ["rename", "copyFile"]:
            if re.search(r'\b' + n + r'\s*\(', src) and n not in parts:
                parts.append(n)
        return 'import { ' + ', '.join(sorted(parts)) + ' } from "node:fs/promises"'

    src = re.sub(r'import\s*\{([^}]*)\}\s*from\s*["\']node:fs/promises["\']', fix_import, src)

    if src != orig:
        open(path, "w", encoding="utf-8").write(src)
        label = os.path.basename(os.path.dirname(os.path.dirname(path)))
        print(f"    patched imports in {label}")
PY

log 12 12 "Setting DeepSeek API key..."
PERSIST_KEY=""
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    echo "    DEEPSEEK_API_KEY already set in environment, using it."
    PERSIST_KEY="$DEEPSEEK_API_KEY"
else
    printf '    Paste your DeepSeek API key (input hidden): '
    IFS= read -r -s PERSIST_KEY || true
    echo
    if [ -n "$PERSIST_KEY" ]; then
        echo "    Key captured (not echoed)."
        export DEEPSEEK_API_KEY="$PERSIST_KEY"
    else
        if PERSIST_KEY="$(find_deepseek_key)"; then
            echo "    Found existing DeepSeek API key, using it."
            export DEEPSEEK_API_KEY="$PERSIST_KEY"
        else
            echo "    No key provided; set it later with: export DEEPSEEK_API_KEY=sk-..."
        fi
    fi
fi
if [ -n "${PERSIST_KEY:-}" ]; then
    RC="$HOME/.bashrc"
    touch "$RC"
    grep -v '^export DEEPSEEK_API_KEY=' "$RC" > "$RC.tmp" 2>/dev/null || true
    printf "export DEEPSEEK_API_KEY='%s'\n" "$PERSIST_KEY" >> "$RC.tmp"
    mv "$RC.tmp" "$RC"
    echo "    Saved DEEPSEEK_API_KEY to $RC"
fi

printf '\n\033[1;32mDone.\033[0m Verify with:\n  dsh --version\n  dsh web\n'
printf 'For headless/web you will need a DeepSeek API key (export DEEPSEEK_API_KEY or set it in the web UI).\n'
