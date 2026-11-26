/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Portable profile policy checks: cc -std=c11 -Wall -Wextra -Werror tests/test_ipad_profile.c -o /tmp/winios-ipad-test && /tmp/winios-ipad-test */
#include "../ios/Sources/Native/winios_ipad_profile.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    uint64_t candidates[12] = {0};
    assert(winios_profile_is_m4_ipad13_16gb("iPad16,5", 16384));
    assert(winios_profile_is_m4_ipad13_16gb("iPad16,6", 16384));
    assert(!winios_profile_is_m4_ipad13_16gb("iPad16,5", 8192));
    assert(!winios_profile_is_m4_ipad13_16gb("iPad16,3", 16384));
    assert(!winios_profile_is_m4_ipad13_16gb("iPhone19,4", 16384));
    assert(!winios_profile_is_m4_ipad13_16gb(NULL, 16384));

    size_t n = winios_profile_ram_candidates(true, 16384, candidates, 12);
    assert(n > 4);
    assert(candidates[0] == WINIOS_M4_IPAD13_GUEST_RAM_MIB);
    assert(candidates[1] == 10240);
    assert(candidates[2] == 8192);

    n = winios_profile_ram_candidates(false, 16384, candidates, 12);
    assert(n == 6 && candidates[0] == 4608); /* Existing iPhone Duo budget. */
    n = winios_profile_ram_candidates(false, 8192, candidates, 12);
    assert(n > 0 && candidates[0] == 4608);
    n = winios_profile_ram_candidates(true, 8192, candidates, 12);
    assert(n > 0 && candidates[0] == 4608); /* Avoid 12 GiB on 8 GiB hosts. */

    assert(WINIOS_M4_IPAD13_DRAWABLE_LONG_PX * 3u ==
           WINIOS_M4_IPAD13_DRAWABLE_SHORT_PX * 4u);
    puts("PASS iPad Pro M4 16 GB profile, 12 GiB guest preference, guarded fallback and 4:3 drawable");
    return 0;
}
