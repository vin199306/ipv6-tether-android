#!/usr/bin/env python3
"""Repack Android boot.img from kernel + ramdisk + dtb."""
import struct, os, sys, gzip, subprocess, tempfile, shutil

def make_cpio(ramdisk_dir):
    """Create cpio archive from directory (newc format)."""
    result = subprocess.run(
        ['find', '.', '-print0'],
        cwd=ramdisk_dir,
        capture_output=True
    )
    file_list = result.stdout

    proc = subprocess.run(
        ['cpio', '-o', '-H', 'newc', '--owner=root:root', '-0'],
        input=file_list,
        capture_output=True,
        cwd=ramdisk_dir
    )
    if proc.returncode != 0:
        print(f"cpio error: {proc.stderr.decode()}")
        sys.exit(1)
    return proc.stdout

def main():
    src_boot = sys.argv[1] if len(sys.argv) > 1 else 'boot.img'
    ramdisk_dir = sys.argv[2] if len(sys.argv) > 2 else 'boot_unpacked/ramdisk'
    out_boot = sys.argv[3] if len(sys.argv) > 3 else 'boot_patched.img'

    # Read original header
    with open(src_boot, 'rb') as f:
        data = f.read()
    src_size = len(data)  # original file size (includes padding to partition size)

    magic = data[0:8]
    assert magic == b'ANDROID!', f"Bad magic: {magic}"
    ks, ka, rs, ra, ss, sa, ta, ps, dt_size, os_ver = struct.unpack_from('<10I', data, 8)
    name = data[48:64]
    cmdline = data[64:576]

    # Read original kernel and dtb
    def npages(sz):
        return (sz + ps - 1) // ps

    pos = ps
    kernel = data[pos:pos+ks]; pos += npages(ks)*ps
    orig_ramdisk = data[pos:pos+rs]; pos += npages(rs)*ps
    second = data[pos:pos+ss] if ss > 0 else b''; pos += npages(ss)*ps
    dtb = data[pos:pos+dt_size] if dt_size > 0 else b''

    # Rebuild ramdisk from modified directory
    print("Creating cpio...")
    cpio_data = make_cpio(ramdisk_dir)
    print(f"cpio size: {len(cpio_data)}")

    print("Compressing gzip...")
    new_ramdisk = gzip.compress(cpio_data, compresslevel=9)
    print(f"ramdisk.gz: {len(new_ramdisk)} (original: {len(orig_ramdisk)})")

    # Build new boot.img
    def align_page(buf, page_size):
        remainder = len(buf) % page_size
        if remainder:
            buf += b'\x00' * (page_size - remainder)
        return buf

    # Header (page_size bytes, matches original)
    header = bytearray(ps)
    header[0:8] = b'ANDROID!'
    struct.pack_into('<10I', header, 8,
                     len(kernel), ka, len(new_ramdisk), ra,
                     len(second), sa, ta, ps, len(dtb), os_ver)
    header[48:64] = name
    header[64:576] = cmdline

    # Assemble
    out = bytearray()
    out += align_page(header, ps)
    out += align_page(kernel, ps)
    out += align_page(new_ramdisk, ps)
    if second:
        out += align_page(second, ps)
    if dtb:
        out += align_page(dtb, ps)

    # Pad to original boot.img size (partition size) with 0x00 to match the
    # original image's tail padding (verified: original uses 0x00 padding).
    if src_size > len(out):
        pad_len = src_size - len(out)
        print(f"Padding {pad_len} bytes (0x00) to match original size {src_size}")
        out += b'\x00' * pad_len
    else:
        print(f"WARNING: output {len(out)} > original {src_size}, no padding")

    with open(out_boot, 'wb') as f:
        f.write(out)

    print(f"Written {len(out)} bytes to {out_boot} (original: {src_size})")
    print(f"  kernel:   {len(kernel)}")
    print(f"  ramdisk:  {len(new_ramdisk)} (was {len(orig_ramdisk)})")
    print(f"  second:   {len(second)}")
    print(f"  dtb:      {len(dtb)}")

if __name__ == '__main__':
    main()
