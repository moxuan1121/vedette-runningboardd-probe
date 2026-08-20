#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <roothide.h>
#import <substrate.h>
#import "VedetteProbeEntry.h"
#include <stdio.h>

// This probe intentionally runs only in runningboardd (also enforced by the
// tweak filter). It does not alter arguments, return values, process state, or
// any CPU/jetsam/assertion policy. A live ABI check limits hooks to v@:@ methods.

typedef struct {
    const char *className;
    const char *selectorName;
} VDTProbeCandidate;

static const VDTProbeCandidate kCandidates[] = {
    { "RBProcessManager", "addProcess:" },
    { "RBProcessManager", "_addProcess:" },
    { "RBProcessManager", "registerProcess:" },
    { "RBProcessManager", "_registerProcess:" },
    { "RBProcessManager", "trackProcess:" },
    { "RBProcessManager", "_trackProcess:" },
    { "RBProcessManager", "processDidLaunch:" },
    { "RBProcessManager", "_processDidLaunch:" },
    { "RBProcessManager", "didLaunchProcess:" },
    { "RBProcessManager", "_didLaunchProcess:" },
    { "RBProcessIndex", "addProcess:" },
    { "RBProcessIndex", "_addProcess:" },
    { "RBProcessIndex", "registerProcess:" },
    { "RBProcessIndex", "_registerProcess:" },
    { "RBProcessIndex", "trackProcess:" },
    { "RBProcessIndex", "_trackProcess:" },
    { "RBProcessIndex", "processDidLaunch:" },
    { "RBProcessIndex", "_processDidLaunch:" },
};

static NSMutableDictionary<NSString *, NSValue *> *gOriginalIMPs;
static dispatch_queue_t gOriginalLock;
static dispatch_queue_t gFileLogQueue;
static os_log_t gLog;

// Explicitly resolve through RootHide. This avoids relying on the current
// process's path-redirection behavior and never hardcodes a jbroot directory.
static NSString *VDTProbeLogPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = jbroot(@"/var/mobile/Media/VDTProbe.log");
    });
    return path;
}

static void VDTWriteLoaderEntryMarker(void) {
    @try {
        FILE *file = fopen(VDTProbeLogPath().fileSystemRepresentation, "a");
        if (!file) return;
        fputs("[VDTProbe] loader-entry dylib-initialized\n", file);
        fclose(file);
    } @catch (__unused NSException *exception) {
        // A diagnostic marker must never affect runningboardd.
    }
}

static NSString *VDTStringOrNull(id value) {
    if (!value || value == [NSNull null]) return @"(null)";
    if ([value isKindOfClass:[NSString class]]) return value;
    @try { return [value description] ?: @"(null)"; } @catch (__unused NSException *exception) { return @"(null)"; }
}

static id VDTSafeObjectValue(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static pid_t VDTSafePID(id process) {
    static SEL const selectors[] = {
        @selector(processIdentifier), @selector(pid), @selector(PID), @selector(identifier)
    };
    for (NSUInteger index = 0; index < sizeof(selectors) / sizeof(selectors[0]); index++) {
        id value = VDTSafeObjectValue(process, selectors[index]);
        if ([value respondsToSelector:@selector(intValue)]) {
            pid_t pid = (pid_t)[value intValue];
            if (pid > 0) return pid;
        }
    }
    return 0;
}

static NSString *VDTFirstStringValue(id object, SEL const *selectors, NSUInteger count) {
    for (NSUInteger index = 0; index < count; index++) {
        id value = VDTSafeObjectValue(object, selectors[index]);
        if (value) return VDTStringOrNull(value);
    }
    return @"(null)";
}

static void VDTLog(NSString *line) {
    if (!line.length) return;
    @try {
        os_log_with_type(gLog, OS_LOG_TYPE_DEFAULT, "%{public}s", line.UTF8String ?: "[VDTProbe] (log encoding failed)");
    } @catch (__unused NSException *exception) {
        // Unified logging is optional and must never affect runningboardd.
    }

    // iOS RootHide shells do not provide macOS's `log stream` reader. Keep an
    // independent, append-only file resolved by jbroot; all file failures are ignored.
    dispatch_async(gFileLogQueue, ^{
        @autoreleasepool {
            @try {
                FILE *file = fopen(VDTProbeLogPath().fileSystemRepresentation, "a");
                if (!file) return;
                NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
                if (data.length) fwrite(data.bytes, 1, data.length, file);
                fclose(file);
            } @catch (__unused NSException *exception) {
                // Never allow diagnostics to destabilize runningboardd.
            }
        }
    });
}

static NSString *VDTKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%s/%s", class_getName(cls), sel_getName(selector)];
}

static IMP VDTOriginalIMP(Class cls, SEL selector) {
    __block IMP result = NULL;
    dispatch_sync(gOriginalLock, ^{
        // A superclass hook can be invoked on a private subclass. Walk upward so
        // the original IMP is always recovered rather than suppressing behavior.
        for (Class current = cls; current && !result; current = class_getSuperclass(current)) {
            result = (IMP)(uintptr_t)[gOriginalIMPs[VDTKey(current, selector)] pointerValue];
        }
    });
    return result;
}

static void VDTLogEvent(id receiver, SEL selector, id process) {
    static SEL const bundleSelectors[] = { @selector(bundleIdentifier), @selector(bundleID), @selector(identifier) };
    static SEL const executableSelectors[] = { @selector(executablePath), @selector(executable), @selector(path) };
    static SEL const nameSelectors[] = { @selector(processName), @selector(name), @selector(displayName) };

    pid_t pid = VDTSafePID(process);
    NSString *bundleID = VDTFirstStringValue(process, bundleSelectors, sizeof(bundleSelectors) / sizeof(bundleSelectors[0]));
    NSString *executable = VDTFirstStringValue(process, executableSelectors, sizeof(executableSelectors) / sizeof(executableSelectors[0]));
    NSString *processName = VDTFirstStringValue(process, nameSelectors, sizeof(nameSelectors) / sizeof(nameSelectors[0]));
    NSString *line = [NSString stringWithFormat:@"[VDTProbe] class=%s selector=%s pid=%d bundleID=%@ executable=%@ processName=%@ timestamp=%.6f",
        class_getName(object_getClass(receiver)) ?: "(null)", sel_getName(selector) ?: "(null)", pid,
        bundleID ?: @"(null)", executable ?: @"(null)", processName ?: @"(null)", [NSDate date].timeIntervalSince1970];
    VDTLog(line);
}

static void VDTProbeHook(id receiver, SEL selector, id process) {
    // Preserve original behavior exactly; log only after its lifecycle work completes.
    IMP original = VDTOriginalIMP(object_getClass(receiver), selector);
    if (original) ((void (*)(id, SEL, id))original)(receiver, selector, process);
    VDTLogEvent(receiver, selector, process);
}

static BOOL VDTIsSafeOneObjectVoidMethod(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char *returnType = method_copyReturnType(method);
    char *argumentType = method_copyArgumentType(method, 2);
    BOOL safe = returnType && argumentType && returnType[0] == 'v' && argumentType[0] == '@';
    if (returnType) free(returnType);
    if (argumentType) free(argumentType);
    return safe;
}

static void VDTDiscoverAndHook(void) {
    for (NSUInteger index = 0; index < sizeof(kCandidates) / sizeof(kCandidates[0]); index++) {
        const VDTProbeCandidate candidate = kCandidates[index];
        Class cls = objc_lookUpClass(candidate.className);
        SEL selector = sel_registerName(candidate.selectorName);
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        BOOL safe = VDTIsSafeOneObjectVoidMethod(method);
        VDTLog([NSString stringWithFormat:@"[VDTProbe] discovery class=%s selector=%s classExists=%s methodExists=%s safeABI=%s action=%s",
            candidate.className, candidate.selectorName, cls ? "yes" : "no", method ? "yes" : "no", safe ? "yes" : "no", safe ? "hook" : "skip"]);
        if (!safe) continue;

        IMP original = NULL;
        MSHookMessageEx(cls, selector, (IMP)VDTProbeHook, &original);
        if (!original) {
            VDTLog([NSString stringWithFormat:@"[VDTProbe] discovery class=%s selector=%s hookResult=no-original-skip", candidate.className, candidate.selectorName]);
            continue;
        }
        dispatch_sync(gOriginalLock, ^{
            gOriginalIMPs[VDTKey(cls, selector)] = [NSValue valueWithPointer:(const void *)(uintptr_t)original];
        });
        VDTLog([NSString stringWithFormat:@"[VDTProbe] discovery class=%s selector=%s hookResult=installed", candidate.className, candidate.selectorName]);
    }
}

static void VDTProbeInitializeOnce(void) {
    @autoreleasepool {
        // The dylib Filter is the authority for injection scope. Do not make
        // startup depend on NSProcessInfo's private daemon naming behavior.
        VDTWriteLoaderEntryMarker();
        gLog = os_log_create("com.udevs.vedette.probe", "runningboardd");
        gOriginalIMPs = [NSMutableDictionary dictionary];
        gOriginalLock = dispatch_queue_create("com.udevs.vedette.probe.original-imps", DISPATCH_QUEUE_SERIAL);
        gFileLogQueue = dispatch_queue_create("com.udevs.vedette.probe.file-log", DISPATCH_QUEUE_SERIAL);
        VDTLog(@"[VDTProbe] startup process=runningboardd mode=log-only no-pid-scan no-timer file=/var/mobile/Media/VDTProbe.log");
        VDTDiscoverAndHook();
    }
}

extern "C" void VDTProbeInitialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VDTProbeInitializeOnce();
    });
}
