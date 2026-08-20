#import "Common.h"

#ifdef __cplusplus
extern "C" {
#endif

// All APIs are internally serialized. They are called only by runningboardd.
void VDTConfigureTargets(NSDictionary *prefs);
void VDTStartPIDDiscovery(void);
void VDTStopPIDDiscovery(void);

#ifdef __cplusplus
}
#endif
