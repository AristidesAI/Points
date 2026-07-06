#ifndef NDI_Bridging_Header_h
#define NDI_Bridging_Header_h

// Required for static-library linking (libndi_ios.a). Device-only: guard all NDI
// call sites with #if !targetEnvironment(simulator) — the fat .a has no arm64-sim slice.
#define PROCESSINGNDILIB_STATIC

#import "Processing.NDI.Lib.h"

#endif
