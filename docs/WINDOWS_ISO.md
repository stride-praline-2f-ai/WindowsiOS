# Prepare Windows from an ARM64 ISO

The provisioner supports `--iso` as an alternative to the original, fixed-index
24H2 ESD. An ISO is mounted read-only, the boot files come from its filesystem,
and the Windows edition is selected by its WIM metadata. The default edition is
**Windows 11 Pro**, not a hardcoded image index. Only ARM64 images are accepted.

Inspect first (does not create disks or start Windows):

```bash
python3 scripts/provision_windows_arm64.py \
  --iso "$HOME/Downloads/Windows11_Client_arm64_en-us_26300_9457.iso" --inspect
```

The filename above was supplied by the user; the actual version is read from
the ISO. Build 26300 is different from the repository's tested build 26100.
Support for reading an ISO does not establish that a newer Windows kernel boots
on this engine. Report a failed boot with the phase log and screenshots.

On ARM64 macOS with Command Line Tools and Homebrew dependencies installed:

```bash
make -j2 build/winvm build/hvsparse
python3 scripts/provision_windows_arm64.py \
  --iso "$HOME/Downloads/Windows11_Client_arm64_en-us_26300_9457.iso" \
  --phase-timeout-minutes 180
```

`--windows-index N` selects another installed edition explicitly, using the indexes
shown by `--inspect`. `--boot-index N` overrides the ISO's default Windows PE
index (1). The generated `install.wim` always has the selected edition at index 1,
as expected by the WinPE install commands.

The process creates a 32 GiB Windows disk plus a sparse installer with room for
the selected installation image. It refuses to overwrite existing `windows11.img`,
`code.fd` or `vars.fd`. Back up an existing VM and use a fresh checkout/work
directory when creating another one. The ISO itself is not modified.

Running the provisioner inside Henge adds another layer of emulation. Its memory,
performance, and boot behavior have not been validated here. The extended timeout
does not guarantee a successful boot. The local default Windows account and
unattended settings remain those of the original provisioning script.

After **both** installation phases finish successfully:

```bash
./build/hvsparse pack work/windows11.img work/windows11.hvsparse
```

Transfer `work/windows11.hvsparse`, `work/code.fd` and `work/vars.fd` to the iOS
app's `Documents/Machines/Win11` directory. This creates the ordinary Windows
image, without the optional 24H2-specific lite modifications. The old
`optimize_windows_lite.py` still expects its original ESD and is not part of this
ISO path. Do not run it against a different Windows version without adapting it.

The original script does not install the VirtIO network driver despite the README's
claim. Guest networking needs a compatible ARM64 NetKVM driver installed separately.

Validation available without a Mac or Windows media:

```bash
python3 -m unittest discover -s tests -p test_windows_media.py
```
