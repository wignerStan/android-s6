# s6-rc service tree

Source tree for `s6-rc-compile`. Compile it on the device and bring it up:

```sh
# 1. compile (one-off, or whenever a service definition changes)
/data/adb/s6/bin/s6-rc-compile /data/adb/s6/compiled /data/adb/s6/src
ln -sfn /data/adb/s6/compiled /data/adb/s6/current

# 2. at boot, after s6-svscan is running on the scandir
/data/adb/s6/bin/s6-rc-init -c /data/adb/s6/current -l /data/adb/s6/live /data/adb/s6/scan
/data/adb/s6/bin/s6-rc -l /data/adb/s6/live -u change default
```

Copy this directory to `/data/adb/s6/src` before compiling.

## Layout

```
default/    type=bundle, contents=<one service name per line>
net-wait/   type=oneshot  up/down  (EXECLINE scripts)
sing-box/   type=longrun  dependencies=net-wait   run
watchdog/   type=longrun  dependencies=sing-box   run
dropbear/   type=longrun                          run
```

Dependency graph: `net-wait -> sing-box -> watchdog`; `dropbear` is independent.

## Rules that bite

- **oneshot `up`/`down` must be execline scripts**, not shell. Wrap a shell
  helper instead:
  ```sh
  #!/data/adb/s6/bin/execlineb -P
  /system/bin/sh /data/adb/s6/bin/net-wait.sh
  ```
  A plain `#!/system/bin/sh` file fails with
  `s6-rc-oneshot-run: unable to exec i=0`.
- longrun `run` files are ordinary shebang scripts and work as-is.
- a bundle's `contents` file takes **one service name per line**.
- `sing-box/run` must wait for a default route before starting sing-box,
  otherwise `auto_route` installs its route without a matching `ip rule` and the
  TUN silently captures nothing. Here that wait lives in the `net-wait` oneshot
  (the dependency), so `sing-box/run` can `exec` directly.
- `dropbear`'s `run` waits for the Termux binary to appear: `/data/data/com.termux`
  is credential-encrypted and invisible until the first unlock after a reboot.

Control services with:

```sh
/data/adb/s6/bin/s6-svc -r /data/adb/s6/live/servicedirs/sing-box
/data/adb/s6/bin/s6-svstat /data/adb/s6/live/servicedirs/sing-box
```
