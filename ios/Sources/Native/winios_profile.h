/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINIOS_PROFILE_H
#define WINIOS_PROFILE_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    WINIOS_STANDARD,
    WINIOS_IPHONE_DUO,
    WINIOS_M4_13_16GB,
} WinIosProfile;

static inline WinIosProfile winios_classify_device(const char *model, uint64_t physical_mib) {
    if (strcmp(model, "iPhone19,4") == 0) return WINIOS_IPHONE_DUO;
    if (physical_mib >= 15000 &&
        (strcmp(model, "iPad16,5") == 0 || strcmp(model, "iPad16,6") == 0))
        return WINIOS_M4_13_16GB;
    return WINIOS_STANDARD;
}

static inline bool winios_ram_fits(WinIosProfile profile, uint64_t size_mib,
                                   uint64_t physical_mib, uint64_t available_mib) {
    bool m4 = profile == WINIOS_M4_13_16GB;
    return (!physical_mib || size_mib + (m4 ? 3072 : 2560) <= physical_mib) &&
           (!m4 || size_mib + 1024 <= available_mib);
}

WinIosProfile winios_device_profile(void);
const char *winios_ram_selection_reason(void);

#endif
