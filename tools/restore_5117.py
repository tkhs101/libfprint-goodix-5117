#!/usr/bin/env python3
"""
Goodix 27c6:5117 恢复脚本 —— 把设备恢复到出厂 PSK (全零), 使 Linux 驱动可用。

与 goodix-fp-dump 的 driver_51x7.py 的关键区别:
  * **失败时不二次擦除**。driver_51x7.py 在异常时会再调用一次 erase_firmware,
    那会把设备彻底留在 IAP 状态且无可用固件时无法恢复。
    本脚本失败时保留 IAP 模式, 设备仍可用同一份镜像重新刷回。
  * 使用**设备当前运行的原版固件** (GF_ST411SEC_APP_12118_5117.bin),
    不是降级版本, 因此操作完全可逆。
  * 每一步都有明确回执, 失败立即停止。

流程 (依据 goodix-fp-dump issue #83 的实证结论):
  1. mcu_erase_app(0, False)                      进入 IAP
  2. preset_psk_write(0xbb010003, PSK_WHITE_BOX)  写全零 PSK 白盒
  3. preset_psk_read(0xbb020003)                  验证 = ba1a8603...d72d43
  4. write_firmware(offset, chunk)                刷原版固件, 1008 字节/块
  5. check_firmware(0, 102336, 0xD90EC273)        CRC 校验
  6. reset(False, True, 20)                       重启

注意: 步骤 1 之后设备处于 IAP 模式, 若后续失败, 设备仍可被本脚本重新刷回。
      不要在 IAP 模式下断电。
"""
import argparse, os, struct, sys, time

# Where goodix-fp-dump lives (it provides the goodix/protocol modules).
# Override with GOODIX_FP_DUMP if you keep it elsewhere.
FP_DUMP = os.environ.get("GOODIX_FP_DUMP", os.path.expanduser("~/goodix-fp-dump"))
sys.path.insert(0, FP_DUMP)

# Firmware images are NOT shipped with this repository: they are vendor
# binaries. Point this at a directory containing the extracted images.
# Override with GOODIX_FW_DIR.
FWDIR = os.environ.get("GOODIX_FW_DIR",
                       os.path.expanduser("~/.local/share/goodix5117/firmware"))
# 可选固件: (文件名, 长度, CRC-32/MPEG-2)
FW_OPTIONS = {
    # 设备当前运行的原版固件 (同版本刷新, 完全可逆)
    "12118": (f"{FWDIR}/GF_ST411SEC_APP_12118_5117.bin", 102336, 0xD90EC273),
    # issue #83 实证成功过的版本 (降级, 但社区验证过完整流程)
    "12117": (f"{FWDIR}/GF_ST411SEC_APP_12117_5117.bin", 102264, 0xDBD51539),
}
PSK_WHITE_BOX = bytes.fromhex(
    "ec35ae3abb45ed3f12c4751f1e5c2cc05b3c5452e9104d9f2a3118644f37a04b"
    "6fd66b1d97cf80f1345f76c84f03ff30bb51bf308f2a9875c41e6592cd2a2f9e"
    "60809b17b5316037b69bb2fa5d4c8ac31edb3394046ec06bbdacc57da6a756c5")
EXPECT_PMK = "ba1a86037c1d3c71c3af344955bd69a9a9861d9e911fa24985b677e8dbd72d43"
CHUNK = 1008

def log(msg): print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def crc32_mpeg(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 \
                  else (crc << 1) & 0xFFFFFFFF
    return crc

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--step", type=int, default=0,
                    help="从第 N 步开始 (1=擦除 2=写PSK 3=验证 4=刷固件 5=校验 6=重启)")
    ap.add_argument("--skip-erase", action="store_true")
    ap.add_argument("--fw", choices=sorted(FW_OPTIONS), default="12118",
                    help="选择刷入的固件版本 (默认 12118 = 设备原版, 可逆)")
    args = ap.parse_args()

    import types
    m = types.ModuleType('periphery')
    class G:
        def __init__(s, *a, **k): pass
    m.CdevGPIO = G
    sys.modules['periphery'] = m

    import usb.core, usb.util
    import goodix, protocol

    def open_device():
        """打开设备并占用数据接口. 同一进程内只能调用一次 --
        pyusb 的 claim 不会自动释放, 二次 claim 会得到 EBUSY."""
        log("打开 USB 设备 27c6:5117 ...")
        dev = usb.core.find(idVendor=0x27c6, idProduct=0x5117)
        if dev is None:
            return None, None
        cfg = dev.get_active_configuration()
        i1 = [i for i in cfg if i.bInterfaceClass == 10][0]
        try:
            if dev.is_kernel_driver_active(i1.bInterfaceNumber):
                dev.detach_kernel_driver(i1.bInterfaceNumber)
        except Exception:
            pass
        usb.util.claim_interface(dev, i1.bInterfaceNumber)
        p = protocol.USBProtocol.__new__(protocol.USBProtocol)
        p.device = dev; p.endpoint_in = 0x81; p.endpoint_out = 0x01
        d = goodix.Device.__new__(goodix.Device)
        d.protocol = p
        return dev, d

    start = args.step
    if start == 0 and not args.skip_erase:
        start = 1

    # ---------- 步骤 1: 擦除 APP 固件, 进入 IAP ----------
    # 这一步会让设备重新枚举, 所以擦除后本进程结束, 由用户重新运行 --step 2.
    if start <= 1:
        dev, d = open_device()
        if d is None:
            log("!! 找不到设备"); return 1
        log("步骤 1: mcu_erase_app -> 进入 IAP 模式")
        try:
            d.mcu_erase_app(0, False)
        except Exception as e:
            log(f"!! 擦除失败: {e}"); log("   设备状态可能已变化, 请检查后再试"); return 2
        log("   已擦除, 等待设备重新枚举 (10 秒) ...")
        time.sleep(10)
        try:
            d.disconnect()
        except Exception:
            pass
        log("   设备已断开. 请重新运行本脚本 (--step 2) 继续.")
        return 0

    # 其余步骤: 打开一次设备, 全程复用
    dev, d = open_device()
    if d is None:
        log("!! 设备未找到 (若刚执行过步骤 1, 请等设备重新枚举后再运行)"); return 3

    # 唤醒序列 (与 goodix-fp-dump 的 init_device 一致)
    # 传感器会丢弃唤醒后的第一条命令, 必须先 nop() 并等约 0.8 秒,
    # 否则紧随其后的命令会被吞掉 (见 goodix-fp-dump issue #83)。
    log("唤醒序列: nop() -> 等待 0.8s -> enable_chip() -> nop()")
    try:
        d.nop()
        time.sleep(0.8)
        d.enable_chip(True)
        d.nop()
    except Exception as e:
        log(f"   (唤醒序列有告警, 继续: {e})")

    fw_path, FW_LEN, FW_CRC = FW_OPTIONS[args.fw]
    fw = open(fw_path, 'rb').read()
    if len(fw) != FW_LEN:
        log(f"!! 固件长度异常: {len(fw)} != {FW_LEN}"); return 9
    if crc32_mpeg(fw) != FW_CRC:
        log("!! 固件 CRC 校验失败, 拒绝继续."); return 9
    log(f"固件就绪: {fw_path}")
    log(f"   len={len(fw)}  crc=0x{FW_CRC:08X}  (版本 {args.fw})")

    # ---------- 步骤 2: 写 PSK 白盒 ----------
    if start <= 2:
        log("步骤 2: preset_psk_write (全零 PSK 白盒, flags=0xbb010003)")
        try:
            ok = d.preset_psk_write(0xbb010003, PSK_WHITE_BOX)
        except Exception as e:
            log(f"!! 写 PSK 失败: {e}")
            log("   若设备仍在 APP 模式, 说明固件不支持在 APP 模式写 PSK")
            log("   (12118 就是如此) —— 必须先执行步骤 1 进入 IAP 模式.")
            return 4
        if not ok:
            log("!! 写 PSK 返回失败. 可用 --step 2 重试."); return 4
        log("   写入完成")

    # ---------- 步骤 3: 验证 PSK ----------
    if start <= 3:
        log("步骤 3: preset_psk_read 验证")
        try:
            ok, flags, psk = d.preset_psk_read(0xbb020003)
        except Exception as e:
            log(f"!! 读 PSK 失败: {e}"); return 5
        if not ok:
            log("!! 读 PSK 失败 (设备返回失败)"); return 5
        log(f"   flags = 0x{flags:08x}")
        got = psk.hex() if isinstance(psk, (bytes, bytearray)) else str(psk)
        log(f"   读回: {got}")
        if got != EXPECT_PMK:
            log(f"!! 期望 {EXPECT_PMK}")
            log("   若这是步骤 1 之前的状态, 说明设备还没被重新 provision, 属正常.")
            log("   在 IAP 模式下若不匹配, 可用 --step 2 重试写入.")
            return 5
        log("   ★ PSK 已回到出厂值")

    # ---------- 步骤 4: 刷固件 ----------
    if start <= 4:
        log(f"步骤 4: write_firmware ({FW_LEN} 字节, {CHUNK}/块)")
        off = 0
        n = 0
        while off < FW_LEN:
            chunk = fw[off:off+CHUNK]
            try:
                if not d.write_firmware(off, chunk):
                    raise RuntimeError("write_firmware 返回 False")
            except Exception as e:
                log(f"!! 刷写失败 @ 0x{off:x}: {e}")
                log("   ★ 设备仍在 IAP 模式, 可用 --step 4 重试 (不要断电).")
                return 6
            off += CHUNK; n += 1
            if n % 20 == 0:
                log(f"   已写 {off}/{FW_LEN} ({off*100//FW_LEN}%)")
        log(f"   写入完成, 共 {n} 块")

    # ---------- 步骤 5: CRC 校验 ----------
    if start <= 5:
        log("步骤 5: check_firmware CRC 校验")
        try:
            ok = d.check_firmware(0, FW_LEN, FW_CRC)
        except Exception as e:
            log(f"!! 校验调用失败: {e}"); return 7
        if not ok:
            log("!! CRC 校验未通过. 设备仍在 IAP 模式, 可用 --step 4 重刷.")
            return 7
        log("   ★ CRC 校验通过")

    # ---------- 步骤 6: 重启 ----------
    if start <= 6:
        log("步骤 6: reset -> 启动新固件")
        try:
            d.reset(False, True, 20)
        except Exception as e:
            log(f"!! reset 失败: {e}"); return 8
        try:
            d.disconnect()
        except Exception:
            pass
        log("   完成. 设备应已重新枚举为 APP 模式.")
        time.sleep(8)
        return 0
    return 0

if __name__ == '__main__':
    sys.exit(main())
