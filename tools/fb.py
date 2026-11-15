#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
最小 fastboot 客户端：绕过 platform-tools 的枚举问题，直接用 WinUSB 与 bootloader 通信。

用法:
    python fb.py devices
    python fb.py getvar all
    python fb.py getvar version
    python fb.py boot <image.img>
    python fb.py flash <partition> <image.img>
    python fb.py reboot
    python fb.py oem <args...>
"""
import ctypes
import ctypes.wintypes as wt
import struct
import sys
import time

# ---------- Win32 / WinUSB 绑定 ----------
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
winusb = ctypes.WinDLL("winusb", use_last_error=True)

GENERIC_RW = 0xC0000000
FILE_SHARE_RW = 0x00000003
OPEN_EXISTING = 3
FILE_FLAG_OVERLAPPED = 0x40000000
INVALID_HANDLE = ctypes.c_void_p(-1).value

k32.CreateFileW.restype = wt.HANDLE
k32.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, wt.LPVOID, wt.DWORD, wt.DWORD, wt.HANDLE]
k32.CloseHandle.argtypes = [wt.HANDLE]

winusb.WinUsb_Initialize.argtypes = [wt.HANDLE, ctypes.POINTER(ctypes.c_void_p)]
winusb.WinUsb_Initialize.restype = wt.BOOL
winusb.WinUsb_Free.argtypes = [ctypes.c_void_p]
winusb.WinUsb_QueryInterfaceSettings.argtypes = [ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_void_p]
winusb.WinUsb_QueryInterfaceSettings.restype = wt.BOOL
winusb.WinUsb_QueryPipe.argtypes = [ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_ubyte, ctypes.c_void_p]
winusb.WinUsb_QueryPipe.restype = wt.BOOL
winusb.WinUsb_WritePipe.argtypes = [ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_char_p,
                                    ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.c_void_p]
winusb.WinUsb_WritePipe.restype = wt.BOOL
winusb.WinUsb_ReadPipe.argtypes = [ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_char_p,
                                   ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.c_void_p]
winusb.WinUsb_ReadPipe.restype = wt.BOOL
winusb.WinUsb_SetPipePolicy.argtypes = [ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_ulong,
                                        ctypes.c_ulong, ctypes.c_void_p]
winusb.WinUsb_SetPipePolicy.restype = wt.BOOL


class USB_INTERFACE_DESCRIPTOR(ctypes.Structure):
    _pack_ = 1
    _fields_ = [
        ("bLength", ctypes.c_ubyte),
        ("bDescriptorType", ctypes.c_ubyte),
        ("bInterfaceNumber", ctypes.c_ubyte),
        ("bAlternateSetting", ctypes.c_ubyte),
        ("bNumEndpoints", ctypes.c_ubyte),
        ("bInterfaceClass", ctypes.c_ubyte),
        ("bInterfaceSubClass", ctypes.c_ubyte),
        ("bInterfaceProtocol", ctypes.c_ubyte),
        ("iInterface", ctypes.c_ubyte),
    ]


class WINUSB_PIPE_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("PipeType", ctypes.c_ulong),
        ("PipeId", ctypes.c_ubyte),
        ("MaximumPacketSize", ctypes.c_ushort),
        ("Interval", ctypes.c_ubyte),
    ]


PIPE_TRANSFER_TIMEOUT = 0x03
RAW_IO = 0x07
ALLOW_PARTIAL_READS = 0x05


class FastbootError(RuntimeError):
    pass


class Fastboot:
    def __init__(self, interface_guid="{a5dcbf10-6530-11d2-901f-00c04fb951ed}",
                 instance=r"USB#VID_18D1&PID_D00D#42de2fc3"):
        path = r"\??\%s#%s" % (instance, interface_guid)
        self.h = k32.CreateFileW(path, GENERIC_RW, FILE_SHARE_RW, None,
                                 OPEN_EXISTING, FILE_FLAG_OVERLAPPED, None)
        if self.h in (INVALID_HANDLE, None):
            raise FastbootError("CreateFile failed: %d" % ctypes.get_last_error())
        self.iface = ctypes.c_void_p()
        if not winusb.WinUsb_Initialize(self.h, ctypes.byref(self.iface)):
            err = ctypes.get_last_error()
            k32.CloseHandle(self.h)
            raise FastbootError("WinUsb_Initialize failed: %d" % err)

        desc = USB_INTERFACE_DESCRIPTOR()
        if not winusb.WinUsb_QueryInterfaceSettings(self.iface, 0, ctypes.byref(desc)):
            raise FastbootError("QueryInterfaceSettings failed: %d" % ctypes.get_last_error())
        self.desc = desc

        self.ep_in = self.ep_out = None
        self.pkt = 64
        for i in range(desc.bNumEndpoints):
            pi = WINUSB_PIPE_INFORMATION()
            if not winusb.WinUsb_QueryPipe(self.iface, 0, i, ctypes.byref(pi)):
                continue
            if pi.PipeType != 2:  # UsbdPipeTypeBulk
                continue
            if pi.PipeId & 0x80:
                self.ep_in = pi.PipeId
                self.pkt = pi.MaximumPacketSize
            else:
                self.ep_out = pi.PipeId
        if self.ep_in is None or self.ep_out is None:
            raise FastbootError("bulk endpoints not found (in=%s out=%s)"
                                % (self.ep_in, self.ep_out))
        for ep in (self.ep_in, self.ep_out):
            timeout = ctypes.c_ulong(30000)
            winusb.WinUsb_SetPipePolicy(self.iface, ep, PIPE_TRANSFER_TIMEOUT,
                                        ctypes.sizeof(timeout), ctypes.byref(timeout))

    def info(self):
        d = self.desc
        return ("iface#%d cls=0x%02x/0x%02x/0x%02x eps=%d in=0x%02x out=0x%02x pkt=%d"
                % (d.bInterfaceNumber, d.bInterfaceClass, d.bInterfaceSubClass,
                   d.bInterfaceProtocol, d.bNumEndpoints, self.ep_in, self.ep_out, self.pkt))

    def close(self):
        try:
            if self.iface:
                winusb.WinUsb_Free(self.iface)
        finally:
            if self.h not in (INVALID_HANDLE, None):
                k32.CloseHandle(self.h)
            self.h = None

    # ---------- 传输 ----------
    def _write(self, data):
        n = ctypes.c_ulong(0)
        if not winusb.WinUsb_WritePipe(self.iface, self.ep_out, data, len(data),
                                       ctypes.byref(n), None):
            raise FastbootError("WritePipe failed: %d" % ctypes.get_last_error())
        return n.value

    def _read(self, size=64):
        buf = ctypes.create_string_buffer(size)
        n = ctypes.c_ulong(0)
        if not winusb.WinUsb_ReadPipe(self.iface, self.ep_in, buf, size,
                                      ctypes.byref(n), None):
            raise FastbootError("ReadPipe failed: %d" % ctypes.get_last_error())
        return buf.raw[: n.value]

    def read_response(self):
        """读一个完整响应（可能是多个 64 字节包拼成的 INFO，直到出现状态包）"""
        data = b""
        while True:
            chunk = self._read(64)
            if not chunk:
                raise FastbootError("empty read (device stopped responding)")
            data += chunk
            head = data[:4]
            if head in (b"OKAY", b"FAIL", b"DATA"):
                if head == b"DATA":
                    if len(data) >= 12:
                        return data[:12]
                    continue
                # OKAY/FAIL 后面可能还有 INFOrma 文本，读到包尾即止
                return data

    def command(self, cmd, timeout=30):
        self._write(cmd.encode())
        return self.read_response()

    def download(self, blob, chunk=65536):
        size = len(blob)
        resp = self.command("download:%08x" % size)
        if not resp.startswith(b"DATA"):
            raise FastbootError("download rejected: %r" % resp)
        expect = int(resp[4:12], 16)
        if expect != size:
            raise FastbootError("size mismatch: sent %d, device wants %d" % (size, expect))
        sent = 0
        t0 = time.time()
        while sent < size:
            part = blob[sent: sent + chunk]
            self._write(part)
            sent += len(part)
            if time.time() - t0 > 1:
                pct = 100.0 * sent / size
                sys.stdout.write("\r  %5.1f%%  %d/%d" % (pct, sent, size))
                sys.stdout.flush()
                t0 = time.time()
        sys.stdout.write("\r  100.0%%  %d/%d\n" % (size, size))
        sys.stdout.flush()
        resp = self.read_response()
        if not resp.startswith(b"OKAY"):
            raise FastbootError("data transfer failed: %r" % resp)
        return True


def find_device():
    """扫描当前 18D1:* 设备的实例路径"""
    import winreg
    base = r"SYSTEM\CurrentControlSet\Enum\USB"
    found = []
    try:
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, base)
    except OSError:
        return found
    i = 0
    while True:
        try:
            vidpid = winreg.EnumKey(key, i)
        except OSError:
            break
        i += 1
        if not vidpid.startswith("VID_18D1"):
            continue
        try:
            k2 = winreg.OpenKey(key, vidpid)
        except OSError:
            continue
        j = 0
        while True:
            try:
                inst = winreg.EnumKey(k2, j)
            except OSError:
                break
            j += 1
            found.append((vidpid, inst))
    return found


def open_device():
    cands = find_device()
    if not cands:
        raise FastbootError("未找到 18D1:* 设备（设备是否在 bootloader 模式？）")
    last = None
    for vidpid, inst in cands:
        try:
            return Fastboot("{%s}" % "a5dcbf10-6530-11d2-901f-00c04fb951ed",
                            r"USB#%s#%s" % (vidpid, inst))
        except FastbootError as ex:
            last = ex
    raise FastbootError("无法打开设备: %s" % last)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    action = argv[1]
    try:
        fb = open_device()
    except FastbootError as ex:
        print("[!] %s" % ex)
        return 1

    print("[i] %s" % fb.info())
    rc = 0
    try:
        if action == "devices":
            resp = fb.command("getvar:version", timeout=10)
            print("[+] response: %r" % resp)
        elif action == "getvar":
            name = argv[2] if len(argv) > 2 else "version"
            resp = fb.command("getvar:%s" % name)
            print("[%s] %s" % ("+" if resp.startswith(b"OKAY") else "-",
                               resp[4:].decode("utf8", "replace").strip("\x00")))
        elif action == "oem":
            resp = fb.command("oem " + " ".join(argv[2:]))
            print("[%s] %s" % ("+" if resp.startswith(b"OKAY") else "-",
                               resp[4:].decode("utf8", "replace").strip("\x00")))
        elif action == "boot":
            data = open(argv[2], "rb").read()
            print("[i] image: %s (%d bytes)" % (argv[2], len(data)))
            fb.download(data)
            print("[i] download OK, issuing boot ...")
            resp = fb.command("boot", timeout=60)
            print("[%s] %s" % ("+" if resp.startswith(b"OKAY") else "-",
                               resp[4:].decode("utf8", "replace").strip("\x00")))
            if not resp.startswith(b"OKAY"):
                rc = 1
        elif action == "flash":
            part, img = argv[2], argv[3]
            data = open(img, "rb").read()
            print("[i] flashing %s <- %s (%d bytes)" % (part, img, len(data)))
            fb.download(data)
            resp = fb.command("flash:%s" % part, timeout=180)
            print("[%s] %s" % ("+" if resp.startswith(b"OKAY") else "-",
                               resp[4:].decode("utf8", "replace").strip("\x00")))
            if not resp.startswith(b"OKAY"):
                rc = 1
        elif action == "reboot":
            try:
                fb.command("reboot")
            except FastbootError:
                pass
            print("[+] reboot 命令已发出")
        else:
            print("未知命令: %s" % action)
            rc = 2
    except FastbootError as ex:
        print("[!] %s" % ex)
        rc = 1
    finally:
        fb.close()
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
