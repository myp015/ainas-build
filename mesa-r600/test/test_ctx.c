/* test_ctx：只验证 VAAPI 初始化与 H.264 EncSlice 上下文创建，不提交任何 GPU 命令。
 * 用 dlopen 动态取符号，避免依赖 libva 头文件/链接库。 */
#define _GNU_SOURCE
#include <stdio.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>

typedef void *VADisplay;

int main(void) {
    void *hva = dlopen("libva.so.2", RTLD_NOW);
    void *hdrm = dlopen("libva-drm.so.2", RTLD_NOW);
    if (!hva) { printf("dlopen libva.so.2: %s\n", dlerror()); return 1; }
    if (!hdrm) { printf("dlopen libva-drm.so.2: %s\n", dlerror()); return 1; }

    VADisplay (*getDisplayDRM)(int) = dlsym(hdrm, "vaGetDisplayDRM");
    int (*initialize)(VADisplay, int *, int *, const char **) = dlsym(hva, "vaInitialize");
    int (*terminate)(VADisplay) = dlsym(hva, "vaTerminate");
    int (*createConfig)(VADisplay, int, int, void *, int, unsigned *) = dlsym(hva, "vaCreateConfig");
    int (*createContext)(VADisplay, unsigned, int, int, int, unsigned *, int, unsigned *) =
        dlsym(hva, "vaCreateContext");
    int (*destroyContext)(VADisplay, unsigned) = dlsym(hva, "vaDestroyContext");
    int (*destroyConfig)(VADisplay, unsigned) = dlsym(hva, "vaDestroyConfig");
    if (!getDisplayDRM || !initialize || !createConfig || !createContext) {
        printf("dlsym 失败\n"); return 1;
    }

    int fd = open("/dev/dri/renderD128", O_RDWR);
    if (fd < 0) { perror("open renderD128"); return 1; }

    VADisplay d = getDisplayDRM(fd);
    if (!d) { printf("vaGetDisplayDRM 失败\n"); return 1; }

    int major = 0, minor = 0;
    const char *ver = "?";
    int r = initialize(d, &major, &minor, &ver);
    printf("vaInitialize      = %d  ver=%s\n", r, ver ? ver : "?");
    if (r != 0) return 1;

    unsigned cfg = 0;
    /* VAProfileH264High=7, VAEntrypointEncSlice=6 */
    r = createConfig(d, 7, 6, NULL, 0, &cfg);
    printf("vaCreateConfig    = %d  cfg=%u\n", r, cfg);
    if (r != 0) return 1;

    unsigned ctx = 0;
    r = createContext(d, cfg, 1920, 1080, 0, NULL, 0, &ctx);
    printf("vaCreateContext   = %d  ctx=%u\n", r, ctx);

    if (r == 0 && destroyContext) destroyContext(d, ctx);
    if (destroyConfig) destroyConfig(d, cfg);
    if (terminate) terminate(d);
    close(fd);
    return r == 0 ? 0 : 2;
}
