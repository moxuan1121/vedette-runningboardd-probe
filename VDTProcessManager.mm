#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "PrivateHeaders.h"

#include <libproc/libproc.h>
#include <libproc/libproc_internal.h>

static dispatch_queue_t sQueue;
static dispatch_source_t sTimer;
static NSDictionary<NSString *, NSDictionary *> *sAppTargets;
static NSDictionary<NSString *, NSDictionary *> *sDaemonTargets;
static NSMutableDictionary<NSNumber *, NSDictionary *> *sMonitored;
static BOOL sScanPending;

static void VDTApplyPolicy(pid_t pid, NSDictionary *rule) {
    if (pid <= 0 || !rule) return;
    NSUInteger policy = [rule[@"policy"] unsignedIntegerValue];
    int percentage = [rule[@"percentage"] intValue];
    int interval = [rule[@"interval"] intValue];
    if (policy == VDTViolationPolicyMonitorAndTerminate) {
        proc_disable_cpumon(pid);
        if (percentage > 0 && interval > 0) proc_set_cpumon_params_fatal(pid, percentage, interval);
        else proc_set_cpumon_defaults(pid);
        proc_resume_cpumon(pid);
    } else if (policy == VDTViolationPolicyThrottle) {
        if (percentage > 0) proc_setcpu_percentage(pid, PROC_SETCPU_ACTION_THROTTLE, percentage);
        else proc_clear_cpulimits(pid);
    }
}

static void VDTClearPolicy(pid_t pid, NSDictionary *rule) {
    if (pid <= 0 || !rule) return;
    if ([rule[@"policy"] unsignedIntegerValue] == VDTViolationPolicyThrottle) proc_clear_cpulimits(pid);
    else {
        proc_disable_cpumon(pid);
        proc_set_cpumon_defaults(pid);
        proc_resume_cpumon(pid);
    }
}

static NSDictionary *VDTRule(NSDictionary *config) {
    NSUInteger policy = [config[@"violationPolicy"] unsignedIntegerValue];
    if (policy != VDTViolationPolicyMonitorAndTerminate && policy != VDTViolationPolicyThrottle) return nil;
    return @{@"policy": @(policy), @"percentage": @([config[@"percentage"] intValue] ?: 80), @"interval": @([config[@"interval"] intValue] ?: 120)};
}

static NSString *VDTDaemonName(pid_t pid) {
    char buffer[256] = {0};
    return proc_name(pid, buffer, sizeof(buffer)) > 0 ? [NSString stringWithUTF8String:buffer] : nil;
}

static NSString *VDTAppBundleIdentifier(pid_t pid, NSString **executableOut) {
    char buffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, buffer, sizeof(buffer)) <= 0) return nil;
    NSString *path = [NSString stringWithUTF8String:buffer];
    if (!path.length) return nil;
    if (executableOut) *executableOut = path;
    LSApplicationProxy *proxy = [objc_getClass("LSApplicationProxy") applicationProxyForBundleURL:[NSURL fileURLWithPath:[path stringByDeletingLastPathComponent]]];
    return proxy.bundleIdentifier;
}

static void VDTArmTimer(NSTimeInterval seconds) {
    if (!sTimer) return;
    dispatch_source_set_timer(sTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, (uint64_t)(seconds * NSEC_PER_SEC * 0.1));
}

static void VDTScan(void) {
    sScanPending = NO;
    if (!sAppTargets.count && !sDaemonTargets.count) return;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) { VDTArmTimer(10); return; }
    int *pids = (int *)calloc(1, (size_t)bytes);
    int count = pids ? proc_listpids(PROC_ALL_PIDS, 0, pids, bytes) : 0;
    NSMutableSet *live = [NSMutableSet set];
    BOOL foundTarget = NO;
    for (int index = 0; index < count; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) continue;
        NSDictionary *rule = nil;
        NSString *identity = nil;
        NSString *daemon = sDaemonTargets.count ? VDTDaemonName(pid) : nil;
        if (daemon) { rule = sDaemonTargets[daemon]; identity = [@"d:" stringByAppendingString:daemon]; }
        if (!rule && sAppTargets.count) {
            NSString *executable = nil;
            NSString *bundleID = VDTAppBundleIdentifier(pid, &executable);
            if (bundleID) { rule = sAppTargets[bundleID]; identity = [@"a:" stringByAppendingString:bundleID]; }
        }
        if (!rule || !identity) continue;
        foundTarget = YES;
        NSNumber *key = @(pid);
        [live addObject:key];
        NSDictionary *previous = sMonitored[key];
        // Matching identity is re-established every scan before either reuse or skip.
        if (previous && [previous[@"identity"] isEqualToString:identity]) continue;
        if (previous) VDTClearPolicy(pid, previous[@"rule"]);
        VDTApplyPolicy(pid, rule);
        sMonitored[key] = @{@"identity": identity, @"rule": rule};
    }
    if (pids) free(pids);
    for (NSNumber *pid in sMonitored.allKeys.copy) {
        if (![live containsObject:pid]) {
            NSDictionary *entry = sMonitored[pid];
            VDTClearPolicy(pid.intValue, entry[@"rule"]);
            [sMonitored removeObjectForKey:pid];
        }
    }
    VDTArmTimer(foundTarget ? 5 : 10);
}

static void VDTScheduleScanNow(void) {
    if (!sTimer || sScanPending) return;
    sScanPending = YES;
    dispatch_async(sQueue, ^{ VDTScan(); });
}

void VDTConfigureTargets(NSDictionary *prefs) {
    dispatch_async(sQueue, ^{
        for (NSNumber *pid in sMonitored.allKeys.copy) VDTClearPolicy(pid.intValue, sMonitored[pid][@"rule"]);
        [sMonitored removeAllObjects];
        NSMutableDictionary *apps = [NSMutableDictionary dictionary], *daemons = [NSMutableDictionary dictionary];
        BOOL enabled = [prefs[@"enabled"] boolValue];
        if (enabled) {
            for (NSDictionary *config in prefs[@"appConfigs"]) { NSString *key = config[@"bundleIdentifier"]; NSDictionary *rule = [config[@"enabled"] boolValue] ? VDTRule(config) : nil; if (key.length && rule) apps[key] = rule; }
            for (NSDictionary *config in prefs[@"daemonConfigs"]) { NSString *key = config[@"daemonName"]; NSDictionary *rule = [config[@"enabled"] boolValue] ? VDTRule(config) : nil; if (key.length && rule) daemons[key] = rule; }
        }
        sAppTargets = [apps copy]; sDaemonTargets = [daemons copy];
        if (!sAppTargets.count && !sDaemonTargets.count) {
            sScanPending = NO;
            if (sTimer) { dispatch_source_cancel(sTimer); sTimer = nil; }
            return;
        }
        if (!sTimer) {
            sTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sQueue);
            dispatch_source_set_event_handler(sTimer, ^{ VDTScan(); });
            dispatch_resume(sTimer);
        }
        VDTScheduleScanNow();
    });
}

void VDTStartPIDDiscovery(void) {
    dispatch_async(sQueue, ^{
        if (sTimer || (!sAppTargets.count && !sDaemonTargets.count)) return;
        sTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sQueue);
        dispatch_source_set_event_handler(sTimer, ^{ VDTScan(); });
        dispatch_resume(sTimer);
    });
}

void VDTStopPIDDiscovery(void) {
    dispatch_async(sQueue, ^{
        sScanPending = NO;
        if (sTimer) { dispatch_source_cancel(sTimer); sTimer = nil; }
    });
}

__attribute__((constructor)) static void VDTManagerInit(void) {
    sQueue = dispatch_queue_create("com.udevs.vedette.pid-discovery", DISPATCH_QUEUE_SERIAL);
    sMonitored = [NSMutableDictionary dictionary];
    sAppTargets = @{}; sDaemonTargets = @{};
}
