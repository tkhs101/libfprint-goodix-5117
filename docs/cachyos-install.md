# CachyOS / Arch 安装与验证（2026-10-29 实测）

本文记录在 **CachyOS（Arch 系）** 上让 Goodix `27c6:5117` 端到端可用的
完整步骤。设备是**出厂状态**，所以没有刷机；如果你探测到的 PSK 摘要不是
出厂值，先看 [flash-on-linux.md](flash-on-linux.md)。

## 实测结果

| 项 | 值 |
|---|---|
| 主机 | CachyOS rolling，kernel `7.3.0-4-cachyos` |
| 设备 | Goodix `27c6:5117` |
| 固件 | `GF_ST411SEC_APP_12118` |
| 发行版 libfprint | `1.94.100-1.1`（被替换） |
| 补丁库 | 基分支 `goodix-5117-support` + 4 个补丁，构建版本 `1.94.5` |
| fprintd | `1.94.5-2.1` |
| OpenCV | `5.0.0-13.1`（Arch 只提供 `opencv5.pc`） |
| PSK | `/etc/goodix5117/psk` = 64 个零，`0600 root:root` |
| PSK 摘要 | `ba1a8603…d72d43`（出厂值） |
| 录入 | 20/20 阶段通过 |
| 验证 | `verify-match` |
| PAM | `system-auth` 中指纹优先，最多 3 次、每次 30 秒，失败后回退密码 |

## 与 Debian / Fedora 的差异

- 库路径是 **`/usr/lib/libfprint-2.so.2.0.0`**，不是
  `/usr/lib64/...` 或 `/usr/lib/x86_64-linux-gnu/...`。
- `opencv` 5.0 只提供 **`opencv5.pc`**，而基分支的
  `libfprint/sigfm/meson.build` 查找 `opencv4`。需要一个本地兼容文件，
  不能直接改系统包。
- `glib-mkenums` 在 **`glib2-devel`** 里，不在 `glib2` 主包。
- 不要用 [`scripts/install.sh`](../scripts/install.sh)：它写死了 Debian
  的库路径，在 Arch 上不会备份正确的文件。
- 发行版 libfprint 是 1.94.100，而基分支构建出 1.94.5；两者的 SONAME
  都是 `libfprint-2.so.2`，fprintd 1.94.5 可正常工作。

## 一、安装依赖

```bash
sudo pacman -S --needed fprintd meson ninja pkgconf \
  glib2 glib2-devel libgusb cairo gnutls libgudev pixman \
  opencv python-pyusb
```

`fprintd` 会拉入发行版 `libfprint`，先保留它，后面只替换共享库。

## 二、构建补丁库

```bash
mkdir -p ~/src && cd ~/src
git clone -b goodix-5117-support https://github.com/gulp/libfprint-1.git
cd libfprint-1
git am /path/to/libfprint-goodix-5117/patches/000*.patch

# Arch 的 opencv5.pc -> opencv4.pc 兼容垫片（仅构建时使用）
mkdir -p /tmp/opencode/pkgconfig
cp /usr/lib/pkgconfig/opencv5.pc /tmp/opencode/pkgconfig/opencv4.pc

PKG_CONFIG_PATH=/tmp/opencode/pkgconfig meson setup build \
  --prefix=/usr \
  -Ddrivers=goodixtls511 \
  -Dudev_rules=disabled -Dudev_hwdb=disabled \
  -Ddoc=false -Dintrospection=false

ninja -C build
meson test -C build --suite unit-tests --print-errorlogs
```

实测 4 个单元测试全部通过（含 `goodix5xx-image`）。构建只有来自 OpenCV 5
头文件的警告，无错误。

## 三、部署（只替换共享库）

```bash
sudo mkdir -p /var/backups/libfprint-goodix5117
sudo cp -a /usr/lib/libfprint-2.so.2.0.0 /var/backups/libfprint-goodix5117/
sudo install -m 755 build/libfprint/libfprint-2.so.2.0.0 \
  /usr/lib/libfprint-2.so.2.0.0
sudo ldconfig
sudo systemctl restart fprintd
```

确认加载的是补丁库：

```bash
strings /usr/lib/libfprint-2.so.2.0.0 | grep goodixtls511
systemctl is-active fprintd
fprintd-list "$USER"
```

设备应显示为 `Goodix TLS Fingerprint Sensor 511`。

## 四、只读探测 PSK（刷机前必做）

以下命令在仓库根目录执行（假设仓库在 `/path/to/libfprint-goodix-5117`）。

`goodix-fp-dump` 的 `protocol.py` 会在导入时 `import spidev`，而探测只走
USB。用一个空实现顶替即可，不必安装树莓派依赖：

```bash
git clone --depth 1 https://github.com/goodix-fp-linux-dev/goodix-fp-dump.git \
  ~/goodix-fp-dump
mkdir -p /tmp/opencode/stubs
cat > /tmp/opencode/stubs/spidev.py <<'PY'
class SpiDev:
    def __init__(self, *args, **kwargs): pass
    def open(self, *args, **kwargs): pass
    def close(self): pass
    def xfer(self, *args, **kwargs): return []
    def xfer2(self, *args, **kwargs): return []
PY

sudo systemctl stop fprintd
sudo env PYTHONPATH=/tmp/opencode/stubs \
  GOODIX_FP_DUMP=$HOME/goodix-fp-dump \
  python3 tools/probe_psk.py
sudo systemctl start fprintd
```

本次输出：

```text
固件版本 : GF_ST411SEC_APP_12118
PSK 摘要 : ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43
判读: ★ 出厂状态 —— TLS 全零密钥即可用, 不需要刷机
```

摘要等于出厂值就**不要刷机**，直接进入下一步。

## 五、写入全零 PSK 并录入

驱动在文件缺失时也会用全零，但显式写出来便于以后排查：

```bash
sudo mkdir -p /etc/goodix5117
printf '%064d\n' 0 | sudo tee /etc/goodix5117/psk >/dev/null
sudo chmod 600 /etc/goodix5117/psk
sudo chown root:root /etc/goodix5117/psk
sudo systemctl restart fprintd

fprintd-enroll -f right-index-finger
fprintd-verify -f right-index-finger
```

本次 `fprintd-enroll` 输出 20 次 `enroll-stage-passed` 后
`enroll-completed`；`fprintd-verify` 返回 `verify-match`。
录入后可以用 `fprintd-list "$USER"` 确认。

## 六、PAM：sudo 与 KDE 锁屏

KDE 的锁屏已经自带 `kde-fingerprint` PAM 服务，无需修改；要让 `sudo`、
`su` 和密码提示路径也接受指纹，按 ArchWiki 的推荐修改
`/etc/pam.d/system-auth`：

```text
-auth      [success=3 default=ignore]  pam_systemd_home.so
auth       [success=2 default=ignore]  pam_fprintd.so       max-tries=3 timeout=30
auth       [success=1 default=bad]     pam_unix.so          try_first_pass nullok
```

也就是把 `pam_systemd_home.so` 的 `success` 从 2 改为 3，并在它下面插入
`pam_fprintd.so`。指纹成功会跳过密码；3 次都失败或单次 30 秒超时后回退到
`pam_unix`，所以密码仍然可用。

这里有两个不同层次的“重试”：

- `fprintd` 的一次 `VerifyStart` 只采集一帧。`verify-no-match` 是最终结果，
  不会在同一帧上反复匹配；只有采集失败（`verify-retry-scan`）才会由
  fprintd 自动重新开始。
- `pam_fprintd` 负责在 PAM 层循环调用 `VerifyStart`。`max-tries` 默认是
  3，`timeout` 默认 30 秒（每一次尝试单独计时）。之前用
  `max-tries=1 timeout=10` 时，失败一次或 10 秒没按就立即回退密码，
  看起来就像“只能试一次、必须关掉重来”。

所以 `max-tries=3 timeout=30` 才是可重试的配置；不需要重启 fprintd，
也不需要拔插传感器。命令行 `fprintd-verify` 本身是单次命令，重跑一次
就是新的一次尝试。

实测 `sudo` 的行为：

```text
请把您的右手食指放在指纹读取器上
验证超时
# 单次 30 秒超时后回退密码，命令成功
```

> **安全提醒**：指纹优先意味着后台进程也可能触发指纹提示
> （CVE-2024-37408 类风险）。如果只想要最小改动，可以只改
> `/etc/pam.d/sudo`，不要动 `system-auth`。

回退 PAM 配置：

```bash
sudo install -m 644 -o root -g root \
  /var/backups/libfprint-goodix5117/system-auth.orig \
  /etc/pam.d/system-auth
```

## 七、回滚与后续升级

回滚补丁库：

```bash
sudo install -m 755 /var/backups/libfprint-goodix5117/libfprint-2.so.2.0.0 \
  /usr/lib/libfprint-2.so.2.0.0
sudo ldconfig && sudo systemctl restart fprintd
```

注意：

- `pacman -Syu` 升级 `libfprint` 会覆盖补丁库，需要重新执行第三节的部署
  （构建目录可以复用）。
- `pacman -Qkk libfprint` 会报告校验和不符，这是预期的。
- **不要再让 Windows 接触这个传感器**：Windows 驱动会重新 provision，
  全零 PSK 立刻失效。
- 构建目录 `~/src/libfprint-1` 和备份目录
  `/var/backups/libfprint-goodix5117/` 建议长期保留。
