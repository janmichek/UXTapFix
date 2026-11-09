//
//  MultitouchSupport.h
//  DockMiddleQuit
//
//  Minimal declarations for the private MultitouchSupport.framework.
//  The framework has no public header. The struct layout and function
//  signatures are the ones used by the open-source trackpad utilities
//  MiddleClick, OpenMultitouchSupport and everypinch.
//
//  This is an undocumented, private API. It is not App Store compatible
//  and Apple may change it in any macOS release.
//

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int stage;
    int fingerID;
    int handID;
    MTVector normalizedVector;
    float total;
    float pressure;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;
    int unknown14;
    int unknown15;
    float density;
} MTTouch;

typedef struct CF_BRIDGED_TYPE(id) MTDevice *MTDeviceRef;

typedef void (*MTFrameCallbackFunction)(
    MTDeviceRef device,
    MTTouch touches[],
    int numTouches,
    double timestamp,
    int frame
);

bool MTDeviceIsAlive(MTDeviceRef) CF_SWIFT_NAME(getter:MTDevice.isAlive(self:));
bool MTDeviceIsRunning(MTDeviceRef) CF_SWIFT_NAME(getter:MTDevice.isRunning(self:));

bool MTRegisterContactFrameCallback(MTDeviceRef, MTFrameCallbackFunction)
    CF_SWIFT_NAME(MTDevice.register(self:contactFrameCallback:));
bool MTUnregisterContactFrameCallback(MTDeviceRef, MTFrameCallbackFunction)
    CF_SWIFT_NAME(MTDevice.unregister(self:contactFrameCallback:));

void MTDeviceStart(MTDeviceRef, int runMode) CF_SWIFT_NAME(MTDevice.start(self:runMode:));
void MTDeviceStop(MTDeviceRef) CF_SWIFT_NAME(MTDevice.stop(self:));

// MTDeviceCreateList is intentionally not declared here: it is resolved
// with @_silgen_name in DockMiddleQuit.swift.
