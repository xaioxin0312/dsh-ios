/*
 * DSHLauncher — legacy CLI entry point kept inside DSH.app.
 * The UIApplication executable is DSHNativeApp; this tool runs the package's
 * dsh-app-ui script when a caller invokes the historical launcher directly.
 */
#include <roothide.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;

    const char *shell = jbroot("/bin/sh");
    const char *jbrootPath = jbroot("/");
    const char *homePath = jbroot("/var/mobile/.dsh");
    const char *binPath = jbroot("/usr/bin");
    const char *baseBinPath = jbroot("/bin");
    const char *sbinPath = jbroot("/usr/sbin");
    const char *baseSbinPath = jbroot("/sbin");
    if (!shell || !jbrootPath || !homePath || !binPath || !baseBinPath || !sbinPath || !baseSbinPath) {
        fprintf(stderr, "DSHLauncher: jbroot() failed to resolve runtime paths\n");
        return 78;
    }

    size_t pathLength = strlen(binPath) + strlen(baseBinPath) + strlen(sbinPath) + strlen(baseSbinPath) + 40;
    char *path = (char *)malloc(pathLength);
    if (!path) return 71;
    snprintf(path, pathLength, "%s:%s:%s:%s:/usr/bin:/bin:/usr/sbin:/sbin",
             binPath, baseBinPath, sbinPath, baseSbinPath);

    setenv("DSH_JBROOT", jbrootPath, 1);
    setenv("DSH_HOME", homePath, 1);
    setenv("HOME", "/var/mobile", 1);
    setenv("PATH", path, 1);
    free(path);

    const char *script = "/usr/bin/dsh-app-ui";
    char *const childArgv[] = { (char *)"sh", (char *)script, NULL };
    execv(shell, childArgv);
    fprintf(stderr, "DSHLauncher: execv(%s) failed: %s\n", shell, strerror(errno));
    return 78;
}
