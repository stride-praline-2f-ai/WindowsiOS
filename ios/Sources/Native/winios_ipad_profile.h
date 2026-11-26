/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINIOS_IPAD_PROFILE_H
#define WINIOS_IPAD_PROFILE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* 13-inch M4 iPad Pro (1 TB / 2 TB configuration), 16 GiB physical RAM.
 * 12 GiB is a requested GUEST capacity, not a promise that iPadOS can keep
 * all of it resident under memory pressure. Preserve 4 GiB host headroom.
 */
#define WINIOS_M4_IPAD13_GUEST_RAM_MIB 12288u
#define WINIOS_M4_IPAD13_DRAWABLE_LONG_PX 2048u
#define WINIOS_M4_IPAD13_DRAWABLE_SHORT_PX 1536u

static inline bool winios_profile_is_m4_ipad13_16gb(const char *model, uint64_t physical_mib) {
    return physical_mib >= 15360 && model &&
           (!strcmp(model, "iPad16,5") || !strcmp(model, "iPad16,6"));
}

/* Descending attempts keep the app bootable if iPadOS rejects 12 GiB.
 * Never raise the iPhone Duo's existing 4.5 GiB cap.
 * The 2.5 GiB physical-memory guard is the legacy safety floor, while
 * the 12 GiB target itself leaves 4 GiB on the specified 16 GiB iPad.
 */
static inline size_t winios_profile_ram_candidates(bool m4_ipad13_16gb,
                                                    uint64_t physical_mib,
                                                    uint64_t *out,
                                                    size_t capacity) {
    static const uint64_t ipad[] = {12288, 10240, 8192, 6144, 4608, 4096, 3584, 3072, 2560, 2048};
    static const uint64_t other[] = {4608, 4096, 3584, 3072, 2560, 2048};
    const uint64_t *src = m4_ipad13_16gb ? ipad : other;
    size_t count = m4_ipad13_16gb ? sizeof(ipad) / sizeof(ipad[0]) : sizeof(other) / sizeof(other[0]);
    size_t n = 0;
    for (size_t i = 0; i < count && n < capacity; ++i) {
        uint64_t mib = src[i];
        if (physical_mib > 0 && mib + 2560 > physical_mib) continue;
        out[n++] = mib;
    }
    return n;
}

#endif
