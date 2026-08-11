#!/usr/bin/env python3
"""Unpack Android boot.img (Qualcomm v0 with dt_size)."""
import struct, sys, os, gzip, subprocess

def main():
    bootimg = sys.argv[1] if len(sys.argv) > 1 else 'boot.img'
    outdir = sys.argv[2] if len(sys.argv) > 2 else 'boot_unpacked'
    os.makedirs(outdir, exist_ok=True)

    with open(bootimg, 'rb') as f:
        data = f.read()

    magic = data[0:8]
    assert magic == b'ANDROID!', f"Bad magic: {magic}"
    ks, ka, rs, ra, ss, sa, ta, ps, dt_size, os_ver = struct.unpack_from('<10I', data, 8)
    name = data[48:64].rstrip(b'\x00')
    cmdline = data[64:576].rstrip(b'\x00')

    print(f"kernel_size={ks} ramdisk_size={rs} second_size={ss} page_size={ps} dt_size={dt_size}")

    def npages(sz):
        return (sz + ps - 1) // ps

    pos = ps
    kernel = data[pos:pos+ks]; pos += npages(ks)*ps
    ramdisk = data[pos:pos+rs]; pos += npages(rs)*ps
    second = data[pos:pos+ss] if ss > 0 else b''; pos += npages(ss)*ps
    dtb = data[pos:pos+dt_size] if dt_size > 0 else b''

    for fn, buf in [('kernel',kernel),('ramdisk.gz',ramdisk),('second',second),('dtb',dtb)]:
        if buf:
            with open(os.path.join(outdir, fn), 'wb') as f:
                f.write(buf)

    with open(os.path.join(outdir, 'header.txt'), 'w') as f:
        f.write(f"kernel_size={ks}\nkernel_addr={ka}\nramdisk_size={rs}\nramdisk_addr={ra}\n")
        f.write(f"second_size={ss}\nsecond_addr={sa}\ntags_addr={ta}\npage_size={ps}\n")
        f.write(f"dt_size={dt_size}\nos_version={os_ver}\n")
        f.write(f"name={name.decode('ascii',errors='replace')}\n")
        f.write(f"cmdline={cmdline.decode('ascii',errors='replace')}\n")

    print(f"kernel={len(kernel)} ramdisk.gz={len(ramdisk)} second={len(second)} dtb={len(dtb)}")

    # Decompress ramdisk
    if ramdisk[:2] == b'\x1f\x8b':
        ramdisk_raw = gzip.decompress(ramdisk)
        with open(os.path.join(outdir, 'ramdisk.cpio'), 'wb') as f:
            f.write(ramdisk_raw)
        print(f"ramdisk decompressed: {len(ramdisk_raw)} bytes (gzip)")

        # Extract cpio
        cpiodir = os.path.join(outdir, 'ramdisk')
        os.makedirs(cpiodir, exist_ok=True)
        os.chdir(cpiodir)
        proc = subprocess.run(['cpio', '-idmu', '--no-absolute-filenames'],
                            input=ramdisk_raw, capture_output=True)
        os.chdir('/')
        if proc.returncode == 0:
            print(f"cpio extracted to {cpiodir}")
        else:
            print(f"cpio failed: {proc.stderr.decode(errors='replace')[:200]}")
            sys.exit(1)
    else:
        print(f"Unknown ramdisk compression: {ramdisk[:4].hex()}")
        sys.exit(1)

if __name__ == '__main__':
    main()
