# android-s6

Build **s6 + s6-rc** for Android (`aarch64-linux-android`, bionic) with the
**Android NDK**, and run it from `/data/adb/s6` as the supervisor layer for a
rooted device (KernelSU / Magisk).

```
Android NDK
   └─ aarch64-linux-android
        ├─ skalibs
        ├─ execline
        ├─ s6
        └─ s6-rc
```

## Why

Android `init` owns services but **does not restart them when they exit**, and
KernelSU's `initrc/` injection only gives you ownership + triggers — not
supervision. `s6` gives real supervision and `s6-rc` adds a dependency graph,
oneshots and a compiled database:

```
init (PID 1)
 ├─ s6-svscan <scandir>          (the only init-owned entry point for services)
 └─ oneshot: s6-rc-init + s6-rc -u change default
      └─ s6-svscan -> s6-supervise -> services
           net-wait (oneshot) -> sing-box -> watchdog
           dropbear
```

## Layout

```
/data/adb/s6/
├── bin/        s6-svscan s6-supervise s6-svc s6-svstat s6-log s6-rc
│               s6-rc-init s6-rc-compile execlineb ...
├── libexec/    s6-ftrigrd s6-rc-fdholder-filler s6-rc-oneshot-run
└── lib/        static archives (skalibs / execline / s6 / s6-rc)
```

`lib/` holds **static** archives: the tools link `skalibs` statically and only
need bionic's `libc.so`, which every device already has. That means no
`LD_LIBRARY_PATH`, and it keeps working from `/data/adb` *before the user
unlocks* (credential-encrypted storage is not needed).

## Build

```sh
NDK=/path/to/android-ndk-r27d ./build.sh
```

`PREFIX` defaults to `/data/adb/s6` and **must stay that value**: skarnet's tools
exec helpers from `$PREFIX/libexec` at runtime, so the prefix is baked into the
binaries. Building with a scratch prefix produces binaries that die with
`execve(<scratch>/libexec/s6-ftrigrd) = ENOENT`.

Then push to the device:

```sh
adb push /data/adb/s6 /data/adb/s6     # or tar + untar as root
adb shell su -c 'chmod -R 755 /data/adb/s6/bin /data/adb/s6/libexec'
```

## On-device wiring (KernelSU)

`/data/adb/modules/<id>/initrc/10-s6.rc`:

```rc
service k70-s6-svscan /system/bin/sh /data/adb/s6/run-svscan.sh
    class late_start
    user root
    group root
    seclabel u:r:ksu:s0
    setenv PATH /data/adb/s6/bin:/system/bin:/system/xbin:/sbin:/vendor/bin

service k70-s6-rc /system/bin/sh /data/adb/s6/k70-s6-rc-init.sh
    user root
    group root
    seclabel u:r:ksu:s0
    setenv PATH /data/adb/s6/bin:/system/bin:/system/xbin:/sbin:/vendor/bin
    oneshot

on property:sys.boot_completed=1
    start k70-s6-rc
```

Generate the injected rc with `ksud initrc refresh` (the generated file may be
`/metadata/watchdog/ksu/modules.rc` rather than the documented
`/metadata/modules.rc`).

## Traps (each one cost a debugging round)

1. **`init` cannot execute binaries under `/data/adb`.** They are labelled
   `adb_data_file`, and:
   ```
   avc: denied { execute } scontext=u:r:init:s0 tcontext=u:object_r:adb_data_file:s0
   init: cannot execv('/data/adb/s6/bin/s6-svscan'): Permission denied
   ```
   Launch through `/system/bin/sh <script>` (sh is a `system_file`), and add a
   module `sepolicy.rule`:
   `allow init adb_data_file:file { execute execute_no_trans open read getattr };`
2. **`s6-svscan` execs `s6-supervise` by name** — `/data/adb/s6/bin` must be in
   `PATH` (`setenv PATH ...`).
3. **The s6-rc `live` dir must not exist** before `s6-rc-init`; it creates
   `live:initial` and symlinks `live` to it.
4. **`scandir` must be a separate real directory** with `s6-svscan` already
   running on it.
5. **oneshot `up`/`down` are execline scripts**, not shell:
   `#!/data/adb/s6/bin/execlineb -P` + `/system/bin/sh /path/helper.sh`.
   longrun `run` files are ordinary scripts.
6. **A bundle's `contents` file takes one service name per line.**
7. **Clear stale state each boot**: `rm -rf <live>` and `rm -f <scandir>/*`
   (keep the hidden `.s6-svscan` directory), otherwise a stale "all down" state
   is reused and nothing starts.

## Verify

```sh
getprop init.svc.k70-s6-svscan          # running
/data/adb/s6/bin/s6-svstat /data/adb/s6/live/servicedirs/sing-box
# supervision test:
kill -9 <service pid>                   # s6-supervise must restart it
```
