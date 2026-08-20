#import "VedetteProbeEntry.h"

#ifndef __unused
#define __unused __attribute__((unused))
#endif

// Use Logos' generated tweak initializer rather than relying on a naked C++
// constructor in a .mm translation unit. Filter scope remains runningboardd.
%ctor {
    VDTProbeInitialize();
}
