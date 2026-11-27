#include <assert.h>
#include "winios_profile.h"

int main(void) {
    assert(winios_classify_device("iPad16,5", 15416) == WINIOS_M4_13_16GB);
    assert(winios_classify_device("iPad16,6", 15416) == WINIOS_M4_13_16GB);
    assert(winios_classify_device("iPad16,5", 8192) == WINIOS_STANDARD);
    assert(winios_classify_device("iPad16,5", 0) == WINIOS_STANDARD);
    assert(winios_classify_device("iPad16,3", 16384) == WINIOS_STANDARD);
    assert(winios_classify_device("iPhone19,4", 12288) == WINIOS_IPHONE_DUO);
    assert(winios_ram_fits(WINIOS_M4_13_16GB, 12288, 15416, 13312));
    assert(!winios_ram_fits(WINIOS_M4_13_16GB, 12288, 15359, 13312));
    assert(!winios_ram_fits(WINIOS_M4_13_16GB, 12288, 15416, 13311));
    assert(winios_ram_fits(WINIOS_M4_13_16GB, 11264, 15416, 13311));
    assert(!winios_ram_fits(WINIOS_M4_13_16GB, 2048, 15416, 3071));
    assert(winios_ram_fits(WINIOS_STANDARD, 4608, 8192, 0));
}
