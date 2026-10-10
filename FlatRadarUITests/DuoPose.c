// Simulator-only test support. These HID events are the controls sent by Device Hub.
// Based on https://github.com/artemnovichkov/hinge (MIT; see tools/screenshots/hinge-LICENSE).
// This file belongs to FlatRadarUITests and is never linked into the shipping app.
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdint.h>

typedef CFTypeRef (*CreateClient)(CFAllocatorRef, int, CFDictionaryRef);
typedef CFDataRef (*Serialize)(CFTypeRef, CFOptionFlags);
typedef CFTypeRef (*CreateEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                               uint32_t, const uint8_t *, CFIndex, uint32_t);
typedef void (*DispatchEvent)(CFTypeRef, CFTypeRef);

static int send_control(CFTypeRef client, Serialize serialize, CreateEvent create,
                        DispatchEvent dispatch, CFStringRef source,
                        CFStringRef type, CFTypeRef value) {
    const void *keys[] = {CFSTR("provider"), CFSTR("source"), CFSTR("type"), CFSTR("value")};
    const void *values[] = {CFSTR("com.apple.Virtualization"), source, type, value};
    CFDictionaryRef payload = CFDictionaryCreate(NULL, keys, values, 4,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef data = serialize(payload, 1);
    CFRelease(payload);
    if (!data) return 2;
    CFTypeRef event = create(NULL, mach_absolute_time(), 0xFF61, 0x5B, 0,
                            CFDataGetBytePtr(data), CFDataGetLength(data), 0);
    CFRelease(data);
    if (!event) return 3;
    dispatch(client, event);
    CFRelease(event);
    return 0;
}

int FRSetDuoPose(int innerLandscape) {
    void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!library) return 4;
    CreateClient createClient = (CreateClient)dlsym(library, "IOHIDEventSystemClientCreateWithType");
    Serialize serialize = (Serialize)dlsym(library, "IOCFSerialize");
    CreateEvent createEvent = (CreateEvent)dlsym(library, "IOHIDEventCreateVendorDefinedEvent");
    DispatchEvent dispatch = (DispatchEvent)dlsym(library, "IOHIDEventSystemClientDispatchEvent");
    if (!createClient || !serialize || !createEvent || !dispatch) { dlclose(library); return 5; }
    CFTypeRef client = createClient(NULL, 4, NULL);
    if (!client) { dlclose(library); return 6; }
    double angle = innerLandscape ? 180 : 0;
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberDoubleType, &angle);
    int result = send_control(client, serialize, createEvent, dispatch,
                              CFSTR("hinge-slider-control"), CFSTR("range"), value);
    CFRelease(value);
    if (!result) {
        result = send_control(client, serialize, createEvent, dispatch,
                              CFSTR("orientation-picker-control"), CFSTR("enum"),
                              innerLandscape ? CFSTR("landscape-left") : CFSTR("portrait"));
    }
    CFRelease(client);
    dlclose(library);
    return result;
}
