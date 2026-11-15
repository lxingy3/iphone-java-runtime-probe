#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>

typedef BOOL (^RPSGameMusicGate)(BOOL muted);

static BOOL RPSReadGameMemory(uintptr_t address, void *buffer, size_t size) {
    if (!address || address > UINTPTR_MAX - size) return NO;
    vm_size_t count = 0;
    return vm_read_overwrite(mach_task_self(), address, size, (vm_address_t)buffer, &count) == KERN_SUCCESS
        && count == size;
}

static uintptr_t RPSGamePointer(uintptr_t object, NSUInteger field) {
    uintptr_t value = 0;
    if (!object || object > UINTPTR_MAX - field || !RPSReadGameMemory(object + field, &value, sizeof value)) {
        return 0;
    }
    return value;
}

static uintptr_t RPSFollowGamePointers(uintptr_t object, NSArray<NSNumber *> *fields) {
    for (NSNumber *field in fields) object = RPSGamePointer(object, field.unsignedIntegerValue);
    return object;
}

static BOOL RPSValidGameMusicPath(id value, NSUInteger count) {
    if (![value isKindOfClass:NSArray.class] || [value count] != count) return NO;
    for (id field in value) {
        if (![field isKindOfClass:NSNumber.class] || [field unsignedIntegerValue] > 0xffff) return NO;
    }
    return YES;
}

#if !TARGET_OS_SIMULATOR && defined(__arm64__)
static const struct mach_header_64 *RPSMatchingGameImage(NSData *uuid) {
    if (uuid.length != 16) return NULL;
    const struct mach_header_64 *header = (void *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64 || header->filetype != MH_EXECUTE) return NULL;
    const uint8_t *commandBytes = (const uint8_t *)(header + 1);
    const uint8_t *end = commandBytes + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if ((size_t)(end - commandBytes) < sizeof(struct load_command)) return NULL;
        const struct load_command *command = (const void *)commandBytes;
        if (command->cmdsize < sizeof *command || command->cmdsize > (size_t)(end - commandBytes)) return NULL;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *identifier = (const void *)command;
            return memcmp(identifier->uuid, uuid.bytes, uuid.length) == 0 ? header : NULL;
        }
        commandBytes += command->cmdsize;
    }
    return NULL;
}
#endif

static RPSGameMusicGate RPSMakeGameMusicGate(void) {
#if !TARGET_OS_SIMULATOR && defined(__arm64__)
    NSURL *url = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"TrainingMusic/game-music-channel.plist"];
    NSDictionary *binding = [NSDictionary dictionaryWithContentsOfURL:url];
    NSData *uuid = binding[@"uuid"];
    NSData *setterEntry = binding[@"setterEntry"];
    NSNumber *registryOffset = binding[@"registryOffset"];
    NSNumber *setterOffset = binding[@"setterOffset"];
    NSArray<NSNumber *> *mixerPath = binding[@"mixerPath"];
    NSArray<NSNumber *> *rtpcPath = binding[@"rtpcPath"];
    NSArray<NSNumber *> *channelPath = binding[@"channelPath"];
    NSArray<NSNumber *> *settingsPath = binding[@"settingsPath"];
    NSNumber *musicVolumeOffset = binding[@"musicVolumeOffset"];
    if (![uuid isKindOfClass:NSData.class] || ![setterEntry isKindOfClass:NSData.class] || setterEntry.length != 16 ||
        ![registryOffset isKindOfClass:NSNumber.class] || ![setterOffset isKindOfClass:NSNumber.class] ||
        ![musicVolumeOffset isKindOfClass:NSNumber.class] || musicVolumeOffset.unsignedIntegerValue > 0xffff ||
        !RPSValidGameMusicPath(mixerPath, 2) || !RPSValidGameMusicPath(rtpcPath, 2) ||
        !RPSValidGameMusicPath(channelPath, 2) || !RPSValidGameMusicPath(settingsPath, 2)) return nil;
    const struct mach_header_64 *image = RPSMatchingGameImage(uuid);
    if (!image || registryOffset.unsignedIntegerValue > UINT32_MAX || setterOffset.unsignedIntegerValue > UINT32_MAX) return nil;
    uintptr_t base = (uintptr_t)image;
    uintptr_t setterAddress = base + setterOffset.unsignedIntegerValue;
    uint8_t entry[16];
    if (!RPSReadGameMemory(setterAddress, entry, sizeof entry) || memcmp(entry, setterEntry.bytes, sizeof entry)) return nil;
    uintptr_t registryAddress = base + registryOffset.unsignedIntegerValue;
    NSUInteger musicField = musicVolumeOffset.unsignedIntegerValue;
    return ^BOOL(BOOL muted) {
        if (!NSThread.isMainThread) return NO;
        uintptr_t registry = RPSGamePointer(registryAddress, 0);
        uintptr_t mixer = RPSFollowGamePointers(registry, mixerPath);
        uintptr_t channel = RPSFollowGamePointers(registry, channelPath);
        uintptr_t settings = RPSFollowGamePointers(registry, settingsPath);
        if (!mixer || !channel || !settings || !RPSFollowGamePointers(mixer, rtpcPath)) return NO;
        int volume = 0;
        if (!muted && (!RPSReadGameMemory(settings + musicField, &volume, sizeof volume) || volume < 0 || volume > 100)) return NO;
        void (*setVolume)(uintptr_t, int, uintptr_t) = (void *)setterAddress;
        setVolume(mixer, volume, channel);
        return YES;
    };
#else
    return nil;
#endif
}
