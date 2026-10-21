#ifndef WANDERING_BRIDGING_H
#define WANDERING_BRIDGING_H

// C surface over the idevice FFI. The module itself (vendor/include) is compiled
// into the app through this shim; Swift never sees the Rust handles.
#import "IDeviceShim.h"

#endif /* WANDERING_BRIDGING_H */
#import "LockdownClient.h"
