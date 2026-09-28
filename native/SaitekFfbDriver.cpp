// Original user-mode DirectInput adapter for the physical 06A3:FFB5 HID PID device.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define DIRECTINPUT_VERSION 0x0800
#include <windows.h>
#include <dinput.h>
#include <dinputd.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cwchar>
#include <cwctype>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include "HidPidDevice.h"

namespace {
// Installer-owned per-user registration; no DllRegisterServer or machine writes.
constexpr CLSID kDriverClass = { 0x1db0c28f, 0x6d99, 0x416e, {0x8d,0x05,0x73,0xde,0x59,0xe6,0xe1,0x70} };
constexpr IID kEffectDriverIid = { 0x02538130, 0x898f, 0x11d0, {0x9a,0xd0,0x00,0xa0,0xc9,0xa0,0x6e,0x35} };
std::atomic<ULONG> gObjects{0};
std::atomic<ULONG> gLocks{0};
std::atomic<std::uint64_t> gNextHandle{1};
#ifdef SAITEK_DRIVER_TEST
using DeviceTransport = TestDevice;
#else
using DeviceTransport = saitek::HidPidDevice;
#endif

template<class F> HRESULT Boundary(F&& callback) noexcept {
    try { return callback(); }
    catch (const std::bad_alloc&) { return E_OUTOFMEMORY; }
    catch (...) { return E_UNEXPECTED; }
}

bool SignedUnit(LONG value) { return value >= -10000 && value <= 10000; }
bool KindForId(DWORD id, saitek::EffectKind& kind) {
    switch (id) {
    case 0x26: kind = saitek::EffectKind::Constant; return true;
    case 0x30: kind = saitek::EffectKind::Square; return true;
    case 0x31: kind = saitek::EffectKind::Sine; return true;
    case 0x32: kind = saitek::EffectKind::Triangle; return true;
    case 0x33: kind = saitek::EffectKind::SawtoothUp; return true;
    case 0x34: kind = saitek::EffectKind::SawtoothDown; return true;
    case 0x40: kind = saitek::EffectKind::Spring; return true;
    case 0x41: kind = saitek::EffectKind::Damper; return true;
    default: return false;
    }
}

HRESULT Normalize(DWORD effectId, const DIEFFECT* effect, saitek::EffectParams& output) {
    if (!effect || (effect->dwSize != sizeof(DIEFFECT) && effect->dwSize != sizeof(DIEFFECT_DX5))) return E_INVALIDARG;
    if (!KindForId(effectId, output.kind)) return DIERR_UNSUPPORTED;
    if (effect->cAxes < 1 || effect->cAxes > 2 || !effect->rgdwAxes || !effect->rglDirection ||
        !effect->lpvTypeSpecificParams || effect->dwGain > 10000) return E_INVALIDARG;
    // The driver callback always receives object IDs; DirectInput may strip the
    // application-level OBJECTIDS bit (observed native flags are just POLAR).
    if (effect->dwFlags & DIEFF_OBJECTOFFSETS) return E_INVALIDARG;
    const DWORD coords = effect->dwFlags & (DIEFF_CARTESIAN | DIEFF_POLAR | DIEFF_SPHERICAL);
    if (coords != DIEFF_CARTESIAN && coords != DIEFF_POLAR) return E_INVALIDARG;
    output.axesMask = 0;
    unsigned axes[2]{};
    for (DWORD i = 0; i < effect->cAxes; ++i) {
        const DWORD object = effect->rgdwAxes[i];
        const DWORD type = DIDFT_GETTYPE(object);
        const DWORD axis = DIDFT_GETINSTANCE(object);
        if ((type != DIDFT_ABSAXIS && type != DIDFT_RELAXIS) || axis > 1 || (output.axesMask & (1u << axis))) return E_INVALIDARG;
        axes[i] = axis;
        output.axesMask = static_cast<BYTE>(output.axesMask | (1u << axis));
    }
    // DirectInput polar zero points north (-Y); angles increase clockwise.
    if (effect->cAxes == 1) {
        LONG direction = effect->rglDirection[0];
        if (coords == DIEFF_POLAR && direction != 0 && direction != 18000) return E_INVALIDARG;
        bool reverse = coords == DIEFF_POLAR ? direction == 18000 : direction < 0;
        output.directionHundredths = axes[0] == 0 ? (reverse ? 27000 : 9000) : (reverse ? 0 : 18000);
    } else if (coords == DIEFF_POLAR) {
        LONG direction = effect->rglDirection[0];
        if (direction < 0 || direction >= 36000) return E_INVALIDARG;
        if (axes[0] == 0 && axes[1] == 1) output.directionHundredths = static_cast<DWORD>(direction);
        else output.directionHundredths = static_cast<DWORD>((27000 - direction + 36000) % 36000);
    } else {
        double vector[2]{};
        for (DWORD i = 0; i < effect->cAxes; ++i) vector[axes[i]] = effect->rglDirection[i];
        double angle = std::atan2(vector[0], -vector[1]) * (18000.0 / 3.14159265358979323846);
        if (angle < 0) angle += 36000.0;
        output.directionHundredths = static_cast<DWORD>(std::llround(angle)) % 36000;
    }
    output.durationUs = effect->dwDuration;
    output.startDelayUs = effect->dwSize == sizeof(DIEFFECT) ? effect->dwStartDelay : 0;
    output.triggerRepeatUs = 0; // Trigger parameters are not advertised and must be ignored.
    output.gain = effect->dwGain;
    output.triggerButton = 0;
    const bool condition = output.kind == saitek::EffectKind::Spring || output.kind == saitek::EffectKind::Damper;
    if (condition) {
        // Per-axis conditions are supported; rotated one-condition/two-axis forms are not advertised.
        if (effect->cbTypeSpecificParams != effect->cAxes * sizeof(DICONDITION)) return DIERR_UNSUPPORTED;
        const auto* conditions = static_cast<const DICONDITION*>(effect->lpvTypeSpecificParams);
        for (DWORD i = 0; i < effect->cAxes; ++i) {
            const auto& value = conditions[i];
            if (!SignedUnit(value.lOffset) || !SignedUnit(value.lPositiveCoefficient) || !SignedUnit(value.lNegativeCoefficient) ||
                value.dwPositiveSaturation > 10000 || value.dwNegativeSaturation > 10000 || value.lDeadBand < 0 || value.lDeadBand > 10000) return E_INVALIDARG;
            output.condition[axes[i]] = value;
        }
    } else if (output.kind == saitek::EffectKind::Constant) {
        if (effect->cbTypeSpecificParams != sizeof(DICONSTANTFORCE)) return E_INVALIDARG;
        output.constantMagnitude = static_cast<const DICONSTANTFORCE*>(effect->lpvTypeSpecificParams)->lMagnitude;
        if (!SignedUnit(output.constantMagnitude)) return E_INVALIDARG;
    } else {
        if (effect->cbTypeSpecificParams != sizeof(DIPERIODIC)) return E_INVALIDARG;
        output.periodic = *static_cast<const DIPERIODIC*>(effect->lpvTypeSpecificParams);
        if (output.periodic.dwMagnitude > 10000 || !SignedUnit(output.periodic.lOffset) ||
            output.periodic.dwPhase >= 36000 || output.periodic.dwPeriod == 0) return E_INVALIDARG;
    }
    // Condition effects do not advertise envelope support. DirectInput permits unsupported parameters to be ignored.
    output.hasEnvelope = !condition && effect->lpEnvelope != nullptr;
    if (output.hasEnvelope) {
        if (effect->lpEnvelope->dwSize != sizeof(DIENVELOPE)) return E_INVALIDARG;
        output.envelope = *effect->lpEnvelope;
        if (output.envelope.dwAttackLevel > 10000 || output.envelope.dwFadeLevel > 10000) return E_INVALIDARG;
    }
    // Sample period is intentionally not advertised; hardware chooses its native update rate.
    return saitek::protocol::Validate(output);
}

struct EffectRecord {
    DWORD kindId = 0;
    saitek::EffectParams params{};
    bool downloaded = false;
    bool dirty = false;
    DWORD iterations = 1;
};

struct DeviceContext {
    DeviceTransport device;
    std::wstring path;
    DWORD internalId = 0;
    std::map<DWORD, EffectRecord> effects;
    HANDLE ownership = nullptr;
    bool opened = false;
    DWORD desiredGain = 10000;
    bool passivePaused = false;
    // Initial physical OFF is an implementation detail, not an application mute.
    // A deliberate OFF survives STOPALL/RESET until ON or a new device session.
    bool explicitActuatorsOff = false;
    bool lost = false;
    ~DeviceContext() {
        try { device.Close(); } catch (...) { /* Destruction must never terminate the host. */ }
        if (ownership) { ReleaseSemaphore(ownership, 1, nullptr); CloseHandle(ownership); }
    }
};

HRESULT SetDevicePath(DeviceContext& context, const wchar_t* path) {
    if (!path) return E_INVALIDARG;
    size_t length = wcsnlen_s(path, 4097);
    if (!length || length > 4096) return E_INVALIDARG;
    context.path.assign(path, length);
    std::transform(context.path.begin(), context.path.end(), context.path.begin(), [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
    if (context.path.rfind(L"\\\\?\\hid#", 0) != 0 || context.path.find(L"vid_06a3&pid_ffb5") == std::wstring::npos) return DIERR_DEVICENOTREG;
    return S_OK;
}

HRESULT ClaimDevice(DeviceContext& context) {
    if (context.opened) return S_OK;
#ifndef SAITEK_DRIVER_TEST
    std::uint64_t hash = 14695981039346656037ULL;
    for (wchar_t c : context.path) { hash ^= static_cast<unsigned short>(c); hash *= 1099511628211ULL; }
    wchar_t name[96]{};
    swprintf_s(name, L"Local\\SaitekFfbDriver_06A3_FFB5_%016llX", static_cast<unsigned long long>(hash));
    HANDLE semaphore = CreateSemaphoreW(nullptr, 1, 1, name);
    if (!semaphore) return HRESULT_FROM_WIN32(GetLastError());
    DWORD wait = WaitForSingleObject(semaphore, 0);
    if (wait != WAIT_OBJECT_0) {
        DWORD error = wait == WAIT_FAILED ? GetLastError() : ERROR_BUSY;
        CloseHandle(semaphore);
        return wait == WAIT_TIMEOUT ? DIERR_OTHERAPPHASPRIO : HRESULT_FROM_WIN32(error);
    }
    context.ownership = semaphore;
#endif
    HRESULT hr = context.device.Open(context.path.c_str());
    if (SUCCEEDED(hr) && context.desiredGain != 10000) hr = context.device.SetGain(context.desiredGain);
    if (SUCCEEDED(hr) && context.passivePaused) hr = context.device.Pause(true);
    if (FAILED(hr)) {
        context.device.Close();
        if (context.ownership) { ReleaseSemaphore(context.ownership, 1, nullptr); CloseHandle(context.ownership); context.ownership = nullptr; }
        return hr;
    }
    context.opened = true;
    return S_OK;
}

class EffectDriver final : public IDirectInputEffectDriver {
    std::atomic<ULONG> refs_{1};
    std::mutex mutex_;
    std::map<DWORD, std::unique_ptr<DeviceContext>> devices_;

    DeviceContext* Device(DWORD id) {
        auto item = devices_.find(id);
        return item == devices_.end() || item->second->lost ? nullptr : item->second.get();
    }
    HRESULT FailedIo(DeviceContext& context, HRESULT error, DWORD* effectHandle = nullptr) {
        if (FAILED(error)) {
            saitek::DeviceState state{};
            if (FAILED(context.device.GetState(state))) {
                context.lost = true;
                context.effects.clear();
                if (effectHandle) *effectHandle = 0;
            }
        }
        return error;
    }
    HRESULT Start(DeviceContext& context, DWORD handle, DWORD flags, DWORD iterations) {
        if ((flags & ~DIES_SOLO) || iterations == 0 || (iterations > 254 && iterations != INFINITE)) return E_INVALIDARG;
        auto item = context.effects.find(handle);
        if (item == context.effects.end()) return DIERR_INVALIDPARAM;
        EffectRecord& record = item->second;
        HRESULT hr = ClaimDevice(context);
        if (FAILED(hr)) return hr;
        if (flags & DIES_SOLO) {
            hr = context.device.StopAll();
            if (FAILED(hr)) return FailedIo(context, hr);
        }
        if (!record.downloaded || record.dirty) {
            if (record.downloaded) {
                hr = context.device.Stop(handle);
                if (FAILED(hr)) return FailedIo(context, hr);
            }
            hr = context.device.Download(handle, record.params);
            if (FAILED(hr)) return FailedIo(context, hr);
            record.downloaded = true;
            record.dirty = false;
        }
        saitek::DeviceState state{};
        hr = context.device.GetState(state);
        if (FAILED(hr)) return FailedIo(context, hr);
        // Ordinary DirectInput applications acquire then Start without issuing
        // SETACTUATORSON (including Microsoft's FFConst sample). Enable only at
        // this explicit playback boundary, never during metadata or download.
        if (!context.explicitActuatorsOff && !state.actuatorsEnabled && !state.paused) {
            hr = context.device.SetActuators(true);
            if (FAILED(hr)) return FailedIo(context, hr);
        }
        hr = context.device.Start(handle, iterations);
        if (SUCCEEDED(hr)) record.iterations = iterations;
        return FailedIo(context, hr);
    }
public:
    EffectDriver() { ++gObjects; }
    ~EffectDriver() { devices_.clear(); --gObjects; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) noexcept override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (iid != IID_IUnknown && iid != kEffectDriverIid) return E_NOINTERFACE;
        *object = static_cast<IDirectInputEffectDriver*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() noexcept override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() noexcept override { ULONG count = --refs_; if (!count) delete this; return count; }
    HRESULT STDMETHODCALLTYPE DeviceID(DWORD version, DWORD externalId, DWORD begin, DWORD internalId, void* info) noexcept override {
        return Boundary([&]() -> HRESULT {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!begin) { devices_.erase(externalId); return S_OK; }
            if (version < 0x500 || !info) return E_INVALIDARG;
            auto* initialization = static_cast<DIHIDFFINITINFO*>(info);
            if (initialization->dwSize != sizeof(DIHIDFFINITINFO) || !initialization->pwszDeviceInterface) return E_INVALIDARG;
            auto existing = devices_.find(externalId);
            if (existing != devices_.end()) return DIERR_ACQUIRED;
            auto context = std::make_unique<DeviceContext>();
            context->internalId = internalId;
            HRESULT hr = SetDevicePath(*context, initialization->pwszDeviceInterface);
            if (FAILED(hr)) return hr;
            devices_.emplace(externalId, std::move(context));
            return S_OK;
        });
    }
    HRESULT STDMETHODCALLTYPE GetVersions(DIDRIVERVERSIONS* versions) noexcept override {
        if (!versions || versions->dwSize != sizeof(DIDRIVERVERSIONS)) return E_INVALIDARG;
        versions->dwFirmwareRevision = 0; versions->dwHardwareRevision = 0; versions->dwFFDriverVersion = 0x00010000;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Escape(DWORD, DWORD, DIEFFESCAPE* escape) noexcept override {
        if (!escape || escape->dwSize != sizeof(DIEFFESCAPE)) return E_INVALIDARG;
        escape->cbOutBuffer = 0; return DIERR_UNSUPPORTED;
    }
    HRESULT STDMETHODCALLTYPE SetGain(DWORD id, DWORD gain) noexcept override {
        return Boundary([&]() -> HRESULT {
            std::lock_guard<std::mutex> lock(mutex_); auto* context = Device(id);
            if (!context) return DIERR_NOTINITIALIZED;
            if (gain > 10000) return E_INVALIDARG;
            if (!context->opened) { context->desiredGain = gain; return S_OK; }
            HRESULT hr = context->device.SetGain(gain);
            if (SUCCEEDED(hr)) context->desiredGain = gain;
            return FailedIo(*context, hr);
        });
    }
    HRESULT STDMETHODCALLTYPE SendForceFeedbackCommand(DWORD id, DWORD command) noexcept override {
        return Boundary([&]() -> HRESULT {
            std::lock_guard<std::mutex> lock(mutex_); auto* context = Device(id);
            if (!context) return DIERR_NOTINITIALIZED;
            if (command != DISFFC_RESET && command != DISFFC_STOPALL && command != DISFFC_PAUSE && command != DISFFC_CONTINUE &&
                command != DISFFC_SETACTUATORSON && command != DISFFC_SETACTUATORSOFF) return E_INVALIDARG;
            // Input-only clients can send cleanup/default commands. A context that
            // never owned output cannot have effects to stop, and must not reset
            // another process's effect pool while doing that cleanup.
            if (!context->opened && command != DISFFC_SETACTUATORSON) {
                if (command == DISFFC_RESET) context->effects.clear();
                if (command == DISFFC_SETACTUATORSOFF) context->explicitActuatorsOff = true;
                if (command == DISFFC_PAUSE) context->passivePaused = true;
                else if (command != DISFFC_SETACTUATORSOFF) context->passivePaused = false;
                return S_OK;
            }
            HRESULT opened = ClaimDevice(*context);
            if (FAILED(opened)) return opened;
            HRESULT hr;
            switch (command) {
            case DISFFC_RESET:
                hr = context->device.Reset();
                if (SUCCEEDED(hr)) context->effects.clear();
                break;
            case DISFFC_STOPALL: hr = context->device.StopAll(); break;
            case DISFFC_PAUSE: hr = context->device.Pause(true); break;
            case DISFFC_CONTINUE: hr = context->device.Pause(false); break;
            case DISFFC_SETACTUATORSON:
                hr = context->device.SetActuators(true);
                if (SUCCEEDED(hr)) context->explicitActuatorsOff = false;
                break;
            case DISFFC_SETACTUATORSOFF:
                hr = context->device.SetActuators(false);
                if (SUCCEEDED(hr)) context->explicitActuatorsOff = true;
                break;
            default: return E_INVALIDARG;
            }
            return FailedIo(*context, hr);
        });
    }
    HRESULT STDMETHODCALLTYPE GetForceFeedbackState(DWORD id, DIDEVICESTATE* state) noexcept override {
        return Boundary([&]() -> HRESULT {
            if (!state || state->dwSize != sizeof(DIDEVICESTATE)) return E_INVALIDARG;
            std::lock_guard<std::mutex> lock(mutex_); auto* context = Device(id);
            if (!context) { state->dwState = DIGFFS_DEVICELOST; state->dwLoad = 0; return DIERR_NOTINITIALIZED; }
            if (!context->opened) { state->dwState = DIGFFS_EMPTY | DIGFFS_STOPPED | DIGFFS_ACTUATORSOFF |
                (context->passivePaused ? DIGFFS_PAUSED : 0); state->dwLoad = 0; return S_OK; }
            saitek::DeviceState current{};
            HRESULT hr = context->device.GetState(current);
            if (FAILED(hr)) { state->dwState = DIGFFS_DEVICELOST; state->dwLoad = 0; return FailedIo(*context, hr); }
            state->dwState = (current.effectCount ? 0 : DIGFFS_EMPTY) | (current.anyPlaying ? 0 : DIGFFS_STOPPED) |
                (current.paused ? DIGFFS_PAUSED : 0) | (current.actuatorsEnabled ? DIGFFS_ACTUATORSON : DIGFFS_ACTUATORSOFF);
            // No invented power/grip-switch state; only observable transport state is reported.
            state->dwLoad = current.memoryLoad;
            return S_OK;
        });
    }
    HRESULT STDMETHODCALLTYPE DownloadEffect(DWORD id, DWORD effectId, DWORD* handle, const DIEFFECT* effect, DWORD flags) noexcept override {
        return Boundary([&]() -> HRESULT {
            if (!handle || (flags & ~(DIEP_ALLPARAMS | DIEP_START | DIEP_NODOWNLOAD | DIEP_NORESTART))) return E_INVALIDARG;
            saitek::EffectParams normalized{};
            HRESULT hr = Normalize(effectId, effect, normalized);
            if (FAILED(hr)) return hr;
            std::lock_guard<std::mutex> lock(mutex_); auto* context = Device(id);
            if (!context) { *handle = 0; return DIERR_NOTINITIALIZED; }
            auto existing = context->effects.find(*handle);
            if (*handle && existing == context->effects.end()) { *handle = 0; return DIERR_INVALIDPARAM; }
            if (existing != context->effects.end() && existing->second.kindId != effectId) return DIERR_INVALIDPARAM;
            bool isNew = *handle == 0;
            DWORD candidate = *handle;
            if (isNew) {
                auto next = gNextHandle.fetch_add(1);
                if (next > MAXDWORD) return E_OUTOFMEMORY;
                candidate = static_cast<DWORD>(next);
            }
            if (flags & DIEP_NODOWNLOAD) {
                // No calls to the transport: validation and owned cache only, even with START.
                auto& record = context->effects[candidate];
                record.kindId = effectId; record.params = normalized; record.dirty = true;
                *handle = candidate;
                return S_OK;
            }
            // Allocate bookkeeping before any device mutation, so allocation failure
            // cannot strand a downloaded hardware slot without a returned handle.
            if (isNew) context->effects.emplace(candidate, EffectRecord{});
            struct NewRecordGuard {
                DeviceContext& context;
                DWORD handle;
                bool rollback;
                ~NewRecordGuard() { if (rollback) context.effects.erase(handle); }
            } guard{*context, candidate, isNew};
            hr = ClaimDevice(*context);
            if (FAILED(hr)) return hr;
            bool playing = false;
            DWORD iterations = 1;
            if (!isNew && existing->second.downloaded) {
                hr = context->device.IsPlaying(candidate, playing);
                if (FAILED(hr)) return FailedIo(*context, hr, handle);
                iterations = existing->second.iterations;
                // Transport can update matching live storage without an operation report.
                // NORESTART forbids the fallback stop/restart path unless START overrides it.
                if (playing && (flags & DIEP_START)) {
                    hr = context->device.Stop(candidate);
                    if (FAILED(hr)) return FailedIo(*context, hr, handle);
                }
            }
            hr = context->device.Download(candidate, normalized);
            bool restart = playing && (flags & DIEP_START);
            if (hr == DIERR_EFFECTPLAYING && playing && !(flags & DIEP_NORESTART)) {
                hr = context->device.Stop(candidate);
                if (FAILED(hr)) return FailedIo(*context, hr, handle);
                hr = context->device.Download(candidate, normalized);
                restart = SUCCEEDED(hr);
            }
            if (FAILED(hr)) return FailedIo(*context, hr, handle);
            auto& record = context->effects[candidate];
            record.kindId = effectId; record.params = normalized; record.downloaded = true; record.dirty = false;
            *handle = candidate;
            guard.rollback = false;
            if ((flags & DIEP_START) || restart) {
                hr = Start(*context, candidate, 0, (flags & DIEP_START) ? 1 : iterations);
                if (FAILED(hr)) return FailedIo(*context, hr, handle);
            }
            return S_OK;
        });
    }
    HRESULT STDMETHODCALLTYPE DestroyEffect(DWORD id, DWORD handle) noexcept override {
        return Boundary([&]() -> HRESULT {
            std::lock_guard<std::mutex> lock(mutex_); auto* context = Device(id);
            if (!context) return DIERR_NOTINITIALIZED;
            auto item = context->effects.find(handle);
            if (item == context->effects.end()) return DIERR_INVALIDPARAM;
            if (item->second.downloaded) {
                HRESULT hr = context->device.Destroy(handle);
                if (FAILED(hr)) return FailedIo(*context, hr);
            }
            context->effects.erase(item); return S_OK;
        });
    }
    HRESULT STDMETHODCALLTYPE StartEffect(DWORD id, DWORD handle, DWORD flags, DWORD iterations) noexcept override {
        return Boundary([&]() -> HRESULT {
            std::lock_guard<std::mutex> lock(mutex_); auto* context = Device(id);
            return context ? Start(*context, handle, flags, iterations) : DIERR_NOTINITIALIZED;
        });
    }
    HRESULT STDMETHODCALLTYPE StopEffect(DWORD id, DWORD handle) noexcept override {
        return Boundary([&]() -> HRESULT {
            std::lock_guard<std::mutex> lock(mutex_); auto* context = Device(id);
            if (!context) return DIERR_NOTINITIALIZED;
            auto item = context->effects.find(handle);
            if (item == context->effects.end()) return DIERR_INVALIDPARAM;
            return item->second.downloaded ? FailedIo(*context, context->device.Stop(handle)) : S_OK;
        });
    }
    HRESULT STDMETHODCALLTYPE GetEffectStatus(DWORD id, DWORD handle, DWORD* status) noexcept override {
        return Boundary([&]() -> HRESULT {
            if (!status) return E_POINTER;
            *status = 0;
            std::lock_guard<std::mutex> lock(mutex_); auto* context = Device(id);
            if (!context) return DIERR_NOTINITIALIZED;
            auto item = context->effects.find(handle);
            if (item == context->effects.end()) return DIERR_INVALIDPARAM;
            bool playing = false;
            HRESULT hr = item->second.downloaded ? context->device.IsPlaying(handle, playing) : S_OK;
            if (SUCCEEDED(hr) && playing) *status = DIEGES_PLAYING;
            return FailedIo(*context, hr);
        });
    }
};

class ClassFactory final : public IClassFactory {
    std::atomic<ULONG> refs_{1};
public:
    ClassFactory() { ++gObjects; }
    ~ClassFactory() { --gObjects; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) noexcept override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (iid != IID_IUnknown && iid != IID_IClassFactory) return E_NOINTERFACE;
        *object = static_cast<IClassFactory*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() noexcept override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() noexcept override { ULONG count = --refs_; if (!count) delete this; return count; }
    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID iid, void** object) noexcept override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        return Boundary([&]() -> HRESULT {
            auto* driver = new EffectDriver;
            HRESULT hr = driver->QueryInterface(iid, object);
            driver->Release(); return hr;
        });
    }
    HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) noexcept override {
        if (lock) ++gLocks;
        else {
            ULONG current = gLocks.load();
            do { if (!current) return E_UNEXPECTED; } while (!gLocks.compare_exchange_weak(current, current - 1));
        }
        return S_OK;
    }
};
} // namespace

STDAPI DllGetClassObject(REFCLSID classId, REFIID iid, void** object) {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (classId != kDriverClass) return CLASS_E_CLASSNOTAVAILABLE;
    return Boundary([&]() -> HRESULT {
        auto* factory = new ClassFactory;
        HRESULT hr = factory->QueryInterface(iid, object);
        factory->Release(); return hr;
    });
}
STDAPI DllCanUnloadNow() {
    return gObjects.load() == 0 && gLocks.load() == 0 ? S_OK : S_FALSE;
}
