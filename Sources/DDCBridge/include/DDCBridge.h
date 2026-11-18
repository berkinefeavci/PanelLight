#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

void MBMakeGetPacket(uint8_t code, uint8_t output[4]);
void MBMakeSetPacket(uint8_t code, uint16_t value, uint8_t output[6]);
bool MBParseReply(const uint8_t *reply, size_t count, uint8_t code, uint16_t *current, uint16_t *maximum);

// The DDC functions below share static service state and are not thread-safe: call them from one serial queue
// (DDCClient does). Every reply is length-, header- and checksum-checked before a value is returned.
void MBRescan(void);
int32_t MBServiceCount(void);
bool MBServiceIdentity(int32_t index, uint32_t *vendor, uint32_t *product, uint32_t *serial);
// IORegistry path of a DDC service, e.g. ".../dispext0:dcpav-service-epic:0/DCPAVServiceProxy".
bool MBServicePath(int32_t index, char *buffer, size_t size);
bool MBReadVCP(int32_t index, uint8_t code, uint16_t *current, uint16_t *maximum);
bool MBWriteVCP(int32_t index, uint8_t code, uint16_t value);

// CoreDisplay's IODisplayLocation for a display, e.g. ".../dispext0@B0000000/IOMobileFramebufferShim".
// Together with MBServicePath it pairs a monitor with its DDC service even when two monitors share one EDID.
bool MBDisplayLocation(uint32_t displayID, char *buffer, size_t size);

bool MBReadBuiltInBrightness(uint32_t displayID, float *value);
bool MBWriteBuiltInBrightness(uint32_t displayID, float value);
bool MBReadKeyboardBrightness(float *value);
bool MBWriteKeyboardBrightness(float value);
bool MBReadNightShift(bool *active, bool *enabled, int32_t *mode);
bool MBSetNightShiftWarm(bool warm, bool enabledWhenOff);
