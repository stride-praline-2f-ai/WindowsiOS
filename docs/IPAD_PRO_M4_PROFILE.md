# 13-inch iPad Pro M4 (16 GB): WindowsiOS profile

## Target hardware
- iPad Pro 13-inch (M4), Wi-Fi \`iPad16,5\` or Cellular \`iPad16,6\`.
- Only the **16 GiB** RAM configuration receives this profile. The runtime checks both \`hw.machine\` and \`hw.memsize\`; 8 GiB configurations and iPhone Duo retain the previous allocation sequence.
- Four guest vCPUs remain the default (matching the M4's four performance cores without artificially pinning threads).

## Guest RAM: request 12 GiB
After JIT activation while the debugger is attached, \`winios_jit.c\` attempts **12,288 MiB** of ledger-exempt guest RAM on the target iPad. If the mapping cannot be created, it tries 10,240, 8,192, 6,144 MiB and the original smaller sizes. The real allocation size is passed into \`HvWinVmConfig.ram_mb\` and appears in the VM status and logs.

**Caution:** 12 GiB is the maximum requested guest capacity, **not guaranteed resident memory**. M4, iPadOS, GPU textures, JIT mappings and other apps still require host RAM. Ledger exemption does not create physical RAM or ensure immunity from system-wide memory pressure or termination. Validate sustained Windows loads, backgrounding, and thermal state on the actual 16 GiB iPad before relying on this setting. If unstable, use the lower RAM fallback and investigate memory pressure rather than bypassing safety checks.

## 4:3 screen and render budget
The iPad's physical panel is **2752 × 2064** in landscape, a perfect 4:3 ratio. The iPad-specific profile:
- Defaults to the full studio canvas in both orientations instead of misdetecting the iPad's portrait screen as a folding iPhone laptop posture.
- Preserves the live guest framebuffer's aspect ratio and accurate touch coordinate mapping.
- Limits the host Metal *drawable* to **2048 × 1536** in landscape (or **1536 × 2048** when the drawable itself is portrait). It never increases the drawable beyond the visible view's actual pixel dimensions. This reduces presentation bandwidth relative to a full native-resolution drawable.
- Leaves iPhone Duo rendering and manually selected laptop mode unchanged.

**Important firmware limitation:** This renderer change does **not** set Windows's internal display mode to 2048 × 1536. The repository uses the stock EDK2 QemuRamfb GOP, which exposes only 640 × 480, 800 × 600 and 1024 × 768 modes. All three are 4:3. A genuine higher-resolution Windows desktop needs an updated/custom GOP (or a separate Windows-supported virtual display adapter/driver), plus guest integration and hardware validation. Claiming a higher guest resolution by only enlarging the Metal drawable would be incorrect.

## Verification
Run the portable policy test:

\`\`\`sh
cc -std=c11 -Wall -Wextra -Werror tests/test_ipad_profile.c -o /tmp/winios-ipad-profile-test
/tmp/winios-ipad-profile-test
\`\`\`

Then build an unsigned iPhoneOS ARM64 IPA using the repository's GitHub Actions workflow. The portable test checks model detection, strict 16 GiB guard, 12 GiB allocation preference, fallback order, legacy iPhone RAM policy, and 4:3 render budget; it **does not** prove that a physical device can reserve 12 GiB or boot Windows at that capacity. Those require an actual iPad M4 16 GiB.
