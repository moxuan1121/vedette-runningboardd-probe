#import "Common.h"
#import "VDTProcessManager.h"
#import "VDTShared.h"

static void VDTReloadPrefs(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    VDTConfigureTargets(getPrefs());
}

%ctor {
    @autoreleasepool {
        NSString *name = [NSProcessInfo processInfo].processName;
        if (![name isEqualToString:@"runningboardd"]) return;
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VDTReloadPrefs, (CFStringRef)PREFS_CHANGED_NN, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        VDTConfigureTargets(getPrefs());
    }
}
