/*
 * Native Roothide Node launcher.
 * Installed as /usr/lib/dsh/bin/node; the original Node Mach-O stays at
 * /usr/lib/dsh/bin/node-real and is never rewritten by this launcher.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <roothide.h>

extern char **environ;

#define DSHRH_REAL_NODE_LOGICAL "/usr/lib/dsh/bin/node-real"
#define DSHRH_PRELOAD_LOGICAL   "/usr/lib/dsh/roothide-node-preload.cjs"
#define DSHRH_HOME_LOGICAL      "/var/mobile/.dsh"

static int DSHRHHasPrefix(const char *value, const char *prefix) {
    if (!value || !prefix) return 0;
    size_t n = strlen(prefix);
    return strncmp(value, prefix, n) == 0 && (value[n] == '\0' || value[n] == '/');
}

static char *DSHRHNormalizeJailbreakRoot(const char *root) {
    if (!root || !*root) return NULL;
    size_t n = strlen(root);
    while (n > 1 && root[n - 1] == '/') n--;
    char *out = (char *)malloc(n + 1);
    if (!out) return NULL;
    memcpy(out, root, n);
    out[n] = '\0';
    return out;
}

static int DSHRHIsActualJailbreakPath(const char *path, const char *root) {
    return root && strcmp(root, "/") != 0 && DSHRHHasPrefix(path, root);
}

static const char *DSHRHMapLogicalPath(const char *path, const char *root) {
    if (!path || path[0] != '/' || strstr(path, "://") != NULL) return path;
    if (DSHRHIsActualJailbreakPath(path, root)) return path;

    /* Explicit bootstrap view of the ordinary rootfs: never pass to jbroot(). */
    if (strcmp(path, "/rootfs") == 0) return "/";
    if (strncmp(path, "/rootfs/", strlen("/rootfs/")) == 0) return path + strlen("/rootfs");

    /* Migrate stale fixed-rootless paths exactly once. */
    if (strcmp(path, "/var/jb") == 0) return jbroot("/");
    if (strncmp(path, "/var/jb/", strlen("/var/jb/")) == 0) {
        return jbroot(path + strlen("/var/jb"));
    }

    /* Known package and DSH state trees are jbroot logical paths. */
    if (DSHRHHasPrefix(path, "/usr/lib/dsh") ||
        DSHRHHasPrefix(path, "/usr/lib/dsh-phone-bridge") ||
        DSHRHHasPrefix(path, "/var/mobile/.dsh") ||
        DSHRHHasPrefix(path, "/var/log/dsh-app") ||
        DSHRHHasPrefix(path, "/etc/dsh")) {
        return jbroot(path);
    }
    return path;
}

static char *DSHRHMapPathCopy(const char *path, const char *root) {
    const char *mapped = DSHRHMapLogicalPath(path, root);
    return mapped ? strdup(mapped) : NULL;
}

static char *DSHRHMapPathListCopy(const char *value, const char *root) {
    if (!value) return NULL;
    size_t capacity = strlen(value) + 1, used = 0;
    char *out = (char *)malloc(capacity);
    if (!out) return NULL;
    const char *cursor = value;
    for (;;) {
        const char *separator = strchr(cursor, ':');
        size_t n = separator ? (size_t)(separator - cursor) : strlen(cursor);
        char *component = (char *)malloc(n + 1);
        if (!component) { free(out); return NULL; }
        memcpy(component, cursor, n); component[n] = '\0';
        const char *mapped = DSHRHMapLogicalPath(component, root);
        size_t mappedN = strlen(mapped ? mapped : component);
        size_t required = used + mappedN + (separator ? 1 : 0) + 1;
        if (required > capacity) {
            size_t grown = capacity;
            while (grown < required) grown *= 2;
            char *resized = (char *)realloc(out, grown);
            if (!resized) { free(component); free(out); return NULL; }
            out = resized; capacity = grown;
        }
        memcpy(out + used, mapped ? mapped : component, mappedN); used += mappedN;
        free(component);
        if (!separator) break;
        out[used++] = ':'; cursor = separator + 1;
    }
    out[used] = '\0';
    return out;
}

static int DSHRHIsPathEnvironmentKey(const char *key) {
    static const char *const exact[] = {
        "PATH", "HOME", "DSH_HOME", "DSH_NODE", "NODE_PATH", "PNPM_HOME",
        "TMPDIR", "TMP", "TEMP", "XDG_CACHE_HOME", "XDG_CONFIG_HOME",
        "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", NULL
    };
    for (size_t i = 0; exact[i]; i++) if (strcmp(key, exact[i]) == 0) return 1;
    return strncasecmp(key, "XDG_", 4) == 0 || strncasecmp(key, "npm_config_", 11) == 0;
}

static int DSHRHRewritePathEnvironment(const char *root) {
    size_t count = 0;
    while (environ && environ[count]) count++;
    char **updates = (char **)calloc(count + 1, sizeof(char *));
    if (!updates) return -1;
    size_t updateCount = 0;

    for (size_t i = 0; i < count; i++) {
        const char *entry = environ[i], *equals = strchr(entry, '=');
        if (!equals) continue;
        size_t keyN = (size_t)(equals - entry);
        char *key = (char *)malloc(keyN + 1);
        if (!key) goto fail;
        memcpy(key, entry, keyN); key[keyN] = '\0';
        const char *value = equals + 1;
        if (!DSHRHIsPathEnvironmentKey(key) || value[0] != '/') { free(key); continue; }
        char *mapped = DSHRHMapPathListCopy(value, root);
        if (!mapped) { free(key); goto fail; }
        if (strcmp(value, mapped) != 0) {
            size_t n = keyN + strlen(mapped) + 2;
            updates[updateCount] = (char *)malloc(n);
            if (!updates[updateCount]) { free(mapped); free(key); goto fail; }
            snprintf(updates[updateCount], n, "%s=%s", key, mapped);
            updateCount++;
        }
        free(mapped); free(key);
    }
    for (size_t i = 0; i < updateCount; i++) {
        char *equals = strchr(updates[i], '=');
        *equals = '\0';
        if (setenv(updates[i], equals + 1, 1) != 0) goto fail;
    }
    for (size_t i = 0; i < updateCount; i++) free(updates[i]);
    free(updates); return 0;
fail:
    for (size_t i = 0; i < updateCount; i++) free(updates[i]);
    free(updates); return -1;
}

static int DSHRHMapOptionValue(const char *argument) {
    static const char *const prefixes[] = {
        "--require=", "--import=", "--loader=", "--experimental-loader=", NULL
    };
    for (size_t i = 0; prefixes[i]; i++) {
        size_t n = strlen(prefixes[i]);
        if (strncmp(argument, prefixes[i], n) == 0 && argument[n] == '/') return 1;
    }
    return 0;
}

static char *DSHRHRewriteArgument(const char *argument, const char *root) {
    const char *path = argument, *separator = strchr(argument, '=');
    char *prefix = NULL;
    if (separator && DSHRHMapOptionValue(argument)) {
        size_t n = (size_t)(separator - argument) + 1;
        prefix = (char *)malloc(n + 1);
        if (!prefix) return NULL;
        memcpy(prefix, argument, n); prefix[n] = '\0'; path = separator + 1;
    }
    const char *mapped = DSHRHMapLogicalPath(path, root);
    if (!prefix) return strdup(mapped ? mapped : argument);
    size_t n = strlen(prefix) + strlen(mapped ? mapped : path) + 1;
    char *out = (char *)malloc(n);
    if (out) snprintf(out, n, "%s%s", prefix, mapped ? mapped : path);
    free(prefix); return out;
}

static char *DSHRHTokenizeNodeOptions(const char *input, const char *root) {
    if (!input) return strdup("");
    size_t inputN = strlen(input), tokenCount = 0;
    char **tokens = (char **)calloc(inputN + 1, sizeof(char *));
    if (!tokens) return NULL;
    const char *cursor = input;
    while (*cursor) {
        while (*cursor == ' ' || *cursor == '\t' || *cursor == '\n' || *cursor == '\r') cursor++;
        if (!*cursor) break;
        char *token = (char *)malloc(inputN + 1);
        if (!token) goto fail;
        size_t used = 0; char quote = '\0';
        while (*cursor) {
            char ch = *cursor++;
            if (ch == '\\' && quote != '\'') { if (*cursor) token[used++] = *cursor++; continue; }
            if (quote) { if (ch == quote) quote = '\0'; else token[used++] = ch; continue; }
            if (ch == '\'' || ch == '"') { quote = ch; continue; }
            if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') break;
            token[used++] = ch;
        }
        token[used] = '\0'; tokens[tokenCount++] = token;
    }

    char *out = NULL; size_t outN = 0, outCap = 0; int mapNext = 0;
    for (size_t i = 0; i < tokenCount; i++) {
        char *mapped = NULL;
        if (mapNext) { mapped = DSHRHMapPathCopy(tokens[i], root); mapNext = 0; }
        else if (strcmp(tokens[i], "--require") == 0 || strcmp(tokens[i], "-r") == 0 ||
                 strcmp(tokens[i], "--import") == 0 || strcmp(tokens[i], "--loader") == 0 ||
                 strcmp(tokens[i], "--experimental-loader") == 0) {
            mapped = strdup(tokens[i]); mapNext = 1;
        } else mapped = DSHRHRewriteArgument(tokens[i], root);
        if (!mapped) { free(out); out = NULL; goto options_fail; }
        size_t n = strlen(mapped), extra = n + (outN ? 1 : 0) + 1;
        if (outN + extra > outCap) {
            size_t grown = outCap ? outCap * 2 : 128;
            while (grown < outN + extra) grown *= 2;
            char *resized = (char *)realloc(out, grown);
            if (!resized) { free(mapped); free(out); out = NULL; goto options_fail; }
            out = resized; outCap = grown;
        }
        if (outN) out[outN++] = ' ';
        memcpy(out + outN, mapped, n); outN += n; out[outN] = '\0'; free(mapped);
    }
    if (!out) out = strdup("");
options_fail:
    for (size_t i = 0; i < tokenCount; i++) free(tokens[i]);
    free(tokens); return out;
fail:
    for (size_t i = 0; i < tokenCount; i++) free(tokens[i]);
    free(tokens); return NULL;
}

static int DSHRHHasPreloadOption(const char *options) {
    return options && strstr(options, "roothide-node-preload.cjs") != NULL;
}

static int DSHRHInstallNodeOptions(const char *preloadPath, const char *root) {
    const char *existing = getenv("NODE_OPTIONS");
    char *normalized = DSHRHTokenizeNodeOptions(existing, root);
    if (!normalized) return -1;
    if (DSHRHHasPreloadOption(normalized)) {
        int result = setenv("NODE_OPTIONS", normalized, 1);
        free(normalized); return result;
    }
    size_t n = strlen(normalized), required = n + strlen(preloadPath) + 24;
    char *merged = (char *)malloc(required);
    if (!merged) { free(normalized); return -1; }
    if (n) snprintf(merged, required, "%s --require=\"%s\"", normalized, preloadPath);
    else snprintf(merged, required, "--require=\"%s\"", preloadPath);
    int result = setenv("NODE_OPTIONS", merged, 1);
    free(merged); free(normalized); return result;
}

static int DSHRHSetBootstrapEnvironment(const char *root) {
    const char *bin = jbroot("/usr/bin"), *sbin = jbroot("/usr/sbin");
    const char *baseBin = jbroot("/bin"), *baseSbin = jbroot("/sbin");
    if (!root || !*root || !bin || !sbin || !baseBin || !baseSbin) return -1;
    if (DSHRHRewritePathEnvironment(root) != 0 || setenv("DSH_JBROOT", root, 1) != 0) return -1;

    if (!getenv("HOME") || !*getenv("HOME")) setenv("HOME", "/var/mobile", 1);
    if (!getenv("DSH_HOME") || !*getenv("DSH_HOME")) {
        const char *defaultHome = jbroot(DSHRH_HOME_LOGICAL);
        if (!defaultHome || setenv("DSH_HOME", defaultHome, 1) != 0) return -1;
    }

    const char *oldPath = getenv("PATH"), *systemPath = "/usr/bin:/bin:/usr/sbin:/sbin";
    size_t pathN = strlen(bin) + strlen(baseBin) + strlen(sbin) + strlen(baseSbin) + strlen(systemPath) +
                   (oldPath && *oldPath ? strlen(oldPath) + 6 : 5);
    char *path = (char *)malloc(pathN);
    if (!path) return -1;
    snprintf(path, pathN, "%s:%s:%s:%s:%s%s%s", bin, baseBin, sbin, baseSbin,
             systemPath, oldPath && *oldPath ? ":" : "", oldPath && *oldPath ? oldPath : "");
    int result = setenv("PATH", path, 1); free(path); return result;
}

int main(int argc, char **argv) {
    char *root = DSHRHNormalizeJailbreakRoot(jbroot("/"));
    const char *realNode = jbroot(DSHRH_REAL_NODE_LOGICAL);
    const char *preload = jbroot(DSHRH_PRELOAD_LOGICAL);
    if (!root || !*root || !realNode || !preload) { free(root); return 78; }
    if (access(realNode, X_OK) != 0) { free(root); return 127; }
    if (access(preload, R_OK) != 0) { free(root); return 78; }
    if (DSHRHSetBootstrapEnvironment(root) != 0 || DSHRHInstallNodeOptions(preload, root) != 0) { free(root); return 78; }

    char **childArgv = (char **)calloc((size_t)argc + 1, sizeof(char *));
    if (!childArgv) { free(root); return 71; }
    childArgv[0] = strdup(realNode);
    int skipEval = 0, mapNext = 0;
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i] ? argv[i] : "";
        if (skipEval) { childArgv[i] = strdup(arg); skipEval = 0; }
        else if (strcmp(arg, "-e") == 0 || strcmp(arg, "--eval") == 0 || strcmp(arg, "-p") == 0 || strcmp(arg, "--print") == 0) {
            childArgv[i] = strdup(arg); skipEval = 1;
        } else if (mapNext) { childArgv[i] = DSHRHMapPathCopy(arg, root); mapNext = 0; }
        else if (strcmp(arg, "--require") == 0 || strcmp(arg, "-r") == 0 || strcmp(arg, "--import") == 0 || strcmp(arg, "--loader") == 0 || strcmp(arg, "--experimental-loader") == 0) {
            childArgv[i] = strdup(arg); mapNext = 1;
        } else childArgv[i] = DSHRHRewriteArgument(arg, root);
        if (!childArgv[i]) { for (int j = 0; j < i; j++) free(childArgv[j]); free(childArgv); free(root); return 71; }
    }
    execv(realNode, childArgv);
    for (int i = 0; i < argc; i++) free(childArgv[i]);
    free(childArgv); free(root); return 126;
}
