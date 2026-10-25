# Mesa r600 VA 驱动（VCE 编码修复）

## 问题

DSM 7.2 / epyc7002 / AMD A8-4500M（ARUBA，VLIW4，走 Mesa r600）上，Emby 选择硬件转码后
实际仍走 CPU。Emby 的 ffmpeg 日志：

```
-init_hw_device vaapi=dev1:/dev/dri/renderD128 -hwaccel vaapi -hwaccel_device dev1
-hwaccel_output_format vaapi -i xxx.mp4
-filter_complex "[0:0]scale_vaapi@f1=w=426:h=240" -c:v:0 h264_vaapi ...
[h264_vaapi @ ...] Failed to create encode pipeline context: 2 (resource allocation failed).
Conversion failed!
```

内核侧完全正常（`VCE initialized successfully`、`Found VCE firmware/feedback version 50.0.1`），
错误码 2 = `VA_STATUS_ERROR_ALLOCATION_FAILED`，来自用户态 Mesa。

## 根因

Mesa（17.3 起直到当前主线）`src/gallium/drivers/r600/radeon_vce.c` 的
`rvce_create_encoder()` 在初始化完 CPB 后直接：

```c
    reset_cpb(enc);
    goto error;          /* <-- 无条件走错误路径 */
    return &enc->base;
```

同时 `static void (*get_pic_param)(...)= NULL;` 从未赋值，`enc->session/create/config/
feedback/encode/destroy` 等版本相关回调也没有注册。因此：

* `vaCreateContext()` 立刻返回 `VA_STATUS_ERROR_ALLOCATION_FAILED`；
* 即便绕过（二进制补丁），一进 `rvce_begin_frame()` 也会 NULL 解引用。

radeonsi 的同一份代码（`src/gallium/drivers/radeon/radeon_vce.c`）是完整的：它会按
`vce_fw_version` 分派到 `radeon_vce_40_2_2_init` / `_50_init` / `_52_init`。r600 只是
一直没有把这三个版本文件搬过来。

## 修复

`patches/0001-r600-vce-version-callbacks.patch` 把 Mesa 21.3.9 自带的
`radeon/radeon_vce_{40_2_2,50,52}.c` 机械移植到 `r600/`（只改名：`si_vce_*` → `radeon_vce_*` /
`rvce_*`，`struct si_screen` → `struct r600_common_screen`，`sscreen->info.chip_class`
→ `sscreen->chip_class`），并在 `rvce_create_encoder()` 里补上 fw 版本分派、删掉
`goto error`、把 `get_pic_param` 变成 `enc->get_pic_param` 由版本 init 赋值。

ARUBA 的 VCE 固件是 50.0.1，走 `radeon_vce_50_init()` 分支。

## 为什么用 Mesa 21.3.9 + Ubuntu 18.04

* Emby 容器环境实测：glibc 2.27、libva 2.22（VA API 1.22）、
  原版 `/lib/dri/r600_drv_video.so` 只是 `libgallium_drv_video.so` 的符号链接。
* 原版驱动最高只用到 `GLIBC_2.27`，入口是 `__vaDriverInit_1_22`；
  新产物必须同样满足，所以编译在 `ubuntu:18.04` 容器内完成。
* Mesa 21.3.9 的 r600 允许 `-Dllvm=disabled`（25.x 起强制要求 LLVM），
  产物不依赖 libLLVM，容器内无需额外部署。
* 21.3.9 的 `r600/` 与 `radeon/` 的 `struct rvce_encoder` 结构完全一致，
  移植只是改名，不需要适配 VA 接口。

## 构建

```bash
# 本地（需要 x86_64 + docker）
docker run --rm -v "$PWD:/work" -w /work ubuntu:18.04 bash /work/mesa-r600/build.sh

# 或走 CI：GitHub Actions → "Build Mesa r600 VA" → Run workflow
```

产物：`mesa-r600/out/libgallium_drv_video.so`，由 `verify.py` 校验
`__vaDriverInit_1_22`、GLIBC ≤ 2.27、无 libLLVM、依赖库白名单。

## 部署（高影响，需单独确认）

容器内 `/lib/dri/r600_drv_video.so` 与 `radeonsi_drv_video.so` 都是
`libgallium_drv_video.so` 的软链，因此只需替换后者：

```bash
docker cp libgallium_drv_video.so emby-8096:/lib/dri/libgallium_drv_video.so
```

然后重启 Emby 容器并重新触发一次硬件转码。
