#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#ifndef DIRECTINPUT_VERSION
#define DIRECTINPUT_VERSION 0x0800
#endif
#include <dinput.h>
#include <array>
#include <cstdint>
#include <memory>
#include <vector>

namespace saitek {
enum class EffectKind { Constant, Square, Sine, Triangle, SawtoothUp, SawtoothDown, Spring, Damper };

// All values are owned. The COM layer resolves object IDs and coordinates before
// crossing this interface. condition[0]/[1] always refer to physical X/Y.
struct EffectParams {
    EffectKind kind = EffectKind::Constant;
    DWORD durationUs = 0;
    DWORD startDelayUs = 0;
    DWORD triggerRepeatUs = 0;
    DWORD gain = 10000;
    DWORD triggerButton = 0; // Only 0 (no button-triggered replay) is supported.
    BYTE axesMask = 3;
    DWORD directionHundredths = 0; // Polar direction, 0..35999.
    LONG constantMagnitude = 0;
    DIPERIODIC periodic{};
    std::array<DICONDITION, 2> condition{};
    bool hasEnvelope = false;
    DIENVELOPE envelope{};
};

struct DeviceState {
    bool actuatorsEnabled = false;
    bool paused = false;
    bool anyPlaying = false;
    DWORD memoryLoad = 0; // 0..100 percent of usable parameter memory.
    DWORD effectCount = 0;
};

// Pure protocol functions are public so allocation and exact wire bytes can be
// tested without opening any device. No Linux implementation code is used.
namespace protocol {
constexpr size_t ReportBytes = 15;
using Report = std::array<BYTE, ReportBytes>;
struct PoolConfig {
    WORD bytes = 300;
    WORD alignment = 2;
    BYTE maxEffects = 9; // Conservative local policy: use 1..9, leave index 0 unused.
    WORD constantBytes = 1;
    WORD periodicBytes = 12;
    WORD envelopeBytes = 12;
    WORD conditionBytes = 8;
};
struct Block { WORD offset = 0; WORD bytes = 0; };
class PoolAllocator {
public:
    explicit PoolAllocator(PoolConfig config = {});
    bool Allocate(WORD bytes, Block& result);
    bool Free(Block block);
    void Clear();
    DWORD Used() const;
    const PoolConfig& Config() const { return config_; }
private:
    PoolConfig config_;
    std::vector<Block> allocations_;
};
struct EffectStorage {
    BYTE slot = 0;
    Block primary{};
    Block secondary{};
    Block envelope{};
};
HRESULT Validate(const EffectParams& params);
bool CanUpdateInPlace(const EffectParams& previous, const EffectParams& next);
HRESULT AllocateEffect(PoolAllocator& pool, BYTE slot, const EffectParams& params, EffectStorage& storage);
void FreeEffect(PoolAllocator& pool, const EffectStorage& storage);
HRESULT EncodeEffect(const EffectParams& params, const EffectStorage& storage, DWORD globalGain, std::vector<Report>& reports);
HRESULT EncodeOperation(BYTE slot, bool start, DWORD iterations, Report& report);
Report EncodeControl(BYTE selector); // PID array: 1 reset,2 stop-all,3 enable,4 disable,5 pause,6 continue.
}

class HidPidDevice {
public:
    HidPidDevice();
    ~HidPidDevice();
    HidPidDevice(const HidPidDevice&) = delete;
    HidPidDevice& operator=(const HidPidDevice&) = delete;
    HRESULT Open(const wchar_t* devicePath);
    HRESULT Download(DWORD handle, const EffectParams& params);
    HRESULT Start(DWORD handle, DWORD iterations);
    HRESULT Stop(DWORD handle);
    HRESULT StopAll();
    HRESULT Destroy(DWORD handle);
    HRESULT Reset();
    HRESULT SetGain(DWORD gain);
    HRESULT SetActuators(bool enabled);
    HRESULT Pause(bool paused);
    HRESULT GetState(DeviceState& state);
    HRESULT IsPlaying(DWORD handle, bool& playing);
    void Close() noexcept;
#ifdef SAITEK_PROTOCOL_TESTS
    // Test build only: no HID path can be opened through this entry point.
    using TestWriter = HRESULT (*)(const protocol::Report&, void*);
    HRESULT OpenForTesting(TestWriter writer, void* context);
    static HRESULT WriteForTesting(HANDLE handle, const protocol::Report& report);
#endif
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
