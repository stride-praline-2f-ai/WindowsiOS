#include "MachPatch.h"
#include <fcntl.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static uint32_t word(const uint8_t *p, int big) {
    if (big) return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3];
    return (uint32_t)p[3]<<24 | (uint32_t)p[2]<<16 | (uint32_t)p[1]<<8 | p[0];
}

static const char *slice(uint8_t *p, size_t n) {
    if (n < 32 || word(p,0) != 0xfeedfacf || word(p+4,0) != 0x0100000c || word(p+12,0) != 2)
        return "Expected an arm64 iOS app executable.";
    size_t commands = word(p+20,0), cursor = 32;
    if (commands > n-32) return "Truncated load commands.";
    size_t end = cursor + commands;
    uint8_t *sdk = NULL;
    for (uint32_t i=0; i<word(p+16,0); i++) {
        if (end-cursor < 8) return "Truncated load command.";
        uint8_t *cmd = p+cursor;
        uint32_t kind = word(cmd,0), size = word(cmd+4,0);
        if (size < 8 || size%8 || size > end-cursor) return "Invalid load command size.";
        if (kind == 0x2c || kind == 0x21) {
            if (size < 20 || word(cmd+16,0)) return "A decrypted executable is required.";
        }
        if (kind == 0x32 || kind == 0x25) {
            if (sdk) return "Conflicting SDK load commands.";
            if (kind == 0x32 && (size < 24 || word(cmd+8,0) != 2 || word(cmd+20,0) > (size-24)/8))
                return "Expected an iOS device build-version command.";
            if (size < 16) return "Invalid minimum-version command.";
            sdk = cmd + (kind == 0x32 ? 16 : 12);
            if (word(sdk-4,0) > 0x001b0200) return "The minimum OS is above 27.2.";
        }
        cursor += size;
    }
    if (cursor != end || !sdk) return "Missing or invalid SDK metadata.";
    sdk[0]=0; sdk[1]=2; sdk[2]=27; sdk[3]=0;
    return NULL;
}

static const char *patch(uint8_t *p, size_t n) {
    if (n < 8) return "Truncated executable.";
    uint32_t magic = word(p,1);
    if (magic != 0xcafebabe && magic != 0xcafebabf) return slice(p,n);
    int wide = magic == 0xcafebabf;
    size_t stride = wide ? 32 : 20;
    uint32_t count = word(p+4,1);
    if (!count || count > (n-8)/stride) return "Invalid universal header.";
    for (uint32_t i=0; i<count; i++) {
        uint8_t *arch = p+8+i*stride;
        uint64_t offset = word(arch+8,1), length = word(arch+12,1);
        if (wide) {
            offset = offset<<32 | length;
            length = (uint64_t)word(arch+16,1)<<32 | word(arch+20,1);
        }
        if (offset < 8+count*stride || offset > n || length > n-offset)
            return "Invalid universal slice bounds.";
        const char *error = slice(p+offset,length);
        if (error) return error;
    }
    return NULL;
}

const char *patch_sdk_file(const char *path) {
    int fd = open(path,O_RDWR);
    if (fd < 0) return "Could not open temporary executable.";
    struct stat st;
    const char *error = "Could not map temporary executable.";
    if (!fstat(fd,&st) && st.st_size > 0 && (uintmax_t)st.st_size <= SIZE_MAX) {
        size_t n = (size_t)st.st_size;
        uint8_t *p = mmap(NULL,n,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
        if (p != MAP_FAILED) {
            error = patch(p,n);
            if (!error && msync(p,n,MS_SYNC)) error = "Could not save executable.";
            munmap(p,n);
        }
    }
    close(fd);
    return error;
}
