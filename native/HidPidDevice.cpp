// Original implementation of USB HID PID 1.0 using the actual 06A3:FFB5
// descriptor. See ADR-002 and docs/protocol.md. No third-party driver source is
// incorporated. All USB writes are explicit, bounded, and limited to one handle.
#include "HidPidDevice.h"
#include <hidsdi.h>
#include <hidpi.h>
#include <hidclass.h>
#include <algorithm>
#include <limits>
#include <mutex>
#include <new>

namespace saitek {
namespace {
bool Condition(EffectKind k) { return k == EffectKind::Spring || k == EffectKind::Damper; }
bool InSignedRange(LONG n) { return n >= -10000 && n <= 10000; }
bool TimeFits(DWORD us, DWORD maximum, bool infinite = false) {
    return (infinite && us == INFINITE) || static_cast<unsigned long long>(us) <= static_cast<unsigned long long>(maximum) * 1000;
}
WORD Milliseconds(DWORD us) {
    if (us == INFINITE) return 0xffff;
    return static_cast<WORD>((static_cast<unsigned long long>(us) + 999) / 1000);
}
void Word(protocol::Report& report, size_t byte, WORD value) {
    report[byte] = static_cast<BYTE>(value & 255);
    report[byte + 1] = static_cast<BYTE>(value >> 8);
}
LONG Scale(LONG value, LONG maximum, DWORD gain, DWORD global) {
    const long long numerator = static_cast<long long>(value) * maximum * gain * global;
    constexpr long long denominator = 10000LL * 10000 * 10000;
    return static_cast<LONG>((numerator + (numerator < 0 ? -denominator / 2 : denominator / 2)) / denominator);
}
BYTE Angle(DWORD hundredths) { return static_cast<BYTE>((static_cast<unsigned long long>(hundredths) * 255 + 18000) / 36000); }
BYTE Type(EffectKind kind) {
    switch (kind) {
    case EffectKind::Constant: return 1;
    case EffectKind::Square: return 2;
    case EffectKind::Triangle: return 3;
    case EffectKind::Sine: return 4;
    case EffectKind::SawtoothUp: return 5;
    case EffectKind::SawtoothDown: return 6;
    case EffectKind::Spring: return 7;
    case EffectKind::Damper: return 8;
    }
    return 0;
}
HRESULT WinError() { const DWORD e = GetLastError(); return HRESULT_FROM_WIN32(e ? e : ERROR_GEN_FAILURE); }
}

namespace protocol {
PoolAllocator::PoolAllocator(PoolConfig config) : config_(config) {}
bool PoolAllocator::Allocate(WORD bytes, Block& result) {
    result = {};
    if (!bytes || !config_.alignment || config_.alignment > config_.bytes) return false;
    const DWORD aligned = (static_cast<DWORD>(bytes) + config_.alignment - 1) / config_.alignment * config_.alignment;
    if (aligned > config_.bytes) return false;
    DWORD offset = config_.alignment; // Conservative allocation policy: leave offset zero unused.
    for (const auto& block : allocations_) {
        if (offset + aligned <= block.offset) break;
        offset = static_cast<DWORD>(block.offset) + block.bytes;
    }
    if (offset + aligned > config_.bytes) return false;
    Block block{static_cast<WORD>(offset), static_cast<WORD>(aligned)};
    const auto where = std::lower_bound(allocations_.begin(), allocations_.end(), block.offset,
        [](const Block& b, WORD value) { return b.offset < value; });
    allocations_.insert(where, block);
    result = block;
    return true;
}
bool PoolAllocator::Free(Block block) {
    const auto where = std::find_if(allocations_.begin(), allocations_.end(), [block](const Block& b) {
        return b.offset == block.offset && b.bytes == block.bytes;
    });
    if (where == allocations_.end()) return false;
    allocations_.erase(where);
    return true;
}
void PoolAllocator::Clear() { allocations_.clear(); }
DWORD PoolAllocator::Used() const {
    DWORD used = 0;
    for (const auto& block : allocations_) used += block.bytes;
    return used;
}
HRESULT Validate(const EffectParams& p) {
    if (!Type(p.kind) || p.gain > 10000 || !p.axesMask || p.axesMask > 3 || p.directionHundredths >= 36000 || p.triggerButton != 0) return DIERR_INVALIDPARAM;
    if (!TimeFits(p.durationUs, 65534, true) || !TimeFits(p.startDelayUs, 65534) || !TimeFits(p.triggerRepeatUs, 65534)) return DIERR_INVALIDPARAM;
    if (p.hasEnvelope && (Condition(p.kind) || p.envelope.dwAttackLevel > 10000 || p.envelope.dwFadeLevel > 10000 ||
        !TimeFits(p.envelope.dwAttackTime, 10000) || !TimeFits(p.envelope.dwFadeTime, 10000))) return DIERR_INVALIDPARAM;
    if (p.kind == EffectKind::Constant) return InSignedRange(p.constantMagnitude) ? S_OK : DIERR_INVALIDPARAM;
    if (Condition(p.kind)) {
        for (size_t axis = 0; axis < 2; ++axis) {
            if (!(p.axesMask & (1U << axis))) continue;
            const auto& c = p.condition[axis];
            if (!InSignedRange(c.lOffset) || !InSignedRange(c.lPositiveCoefficient) || !InSignedRange(c.lNegativeCoefficient) ||
                c.dwPositiveSaturation > 10000 || c.dwNegativeSaturation > 10000 || c.lDeadBand < 0 || c.lDeadBand > 10000) return DIERR_INVALIDPARAM;
        }
        return S_OK;
    }
    return p.periodic.dwMagnitude <= 10000 && InSignedRange(p.periodic.lOffset) && p.periodic.dwPhase < 36000 &&
        p.periodic.dwPeriod && TimeFits(p.periodic.dwPeriod, 10000) ? S_OK : DIERR_INVALIDPARAM;
}
bool CanUpdateInPlace(const EffectParams& previous, const EffectParams& next) {
    return previous.kind == next.kind && previous.axesMask == next.axesMask && previous.hasEnvelope == next.hasEnvelope &&
        previous.durationUs == next.durationUs && previous.startDelayUs == next.startDelayUs &&
        previous.triggerRepeatUs == next.triggerRepeatUs && previous.triggerButton == next.triggerButton;
}
HRESULT AllocateEffect(PoolAllocator& pool, BYTE slot, const EffectParams& p, EffectStorage& storage) {
    storage = {};
    const HRESULT valid = Validate(p);
    if (FAILED(valid)) return valid;
    if (!slot || slot > pool.Config().maxEffects || slot > 9) return DIERR_INVALIDPARAM;
    EffectStorage candidate{};
    candidate.slot = slot;
    const auto& config = pool.Config();
    bool success = true;
    if (Condition(p.kind)) {
        if (p.axesMask & 1) success = pool.Allocate(config.conditionBytes, candidate.primary);
        if (success && (p.axesMask & 2)) success = pool.Allocate(config.conditionBytes, candidate.secondary);
    } else {
        success = pool.Allocate(p.kind == EffectKind::Constant ? config.constantBytes : config.periodicBytes, candidate.primary);
        // The physical offset field has no null encoding. Even an application
        // effect without an envelope needs a valid, neutral envelope block.
        if (success) success = pool.Allocate(config.envelopeBytes, candidate.envelope);
    }
    if (!success) { FreeEffect(pool, candidate); return DIERR_DEVICEFULL; }
    storage = candidate;
    return S_OK;
}
void FreeEffect(PoolAllocator& pool, const EffectStorage& storage) {
    if (storage.primary.bytes) pool.Free(storage.primary);
    if (storage.secondary.bytes) pool.Free(storage.secondary);
    if (storage.envelope.bytes) pool.Free(storage.envelope);
}
HRESULT EncodeEffect(const EffectParams& p, const EffectStorage& s, DWORD global, std::vector<Report>& reports) {
    reports.clear();
    const HRESULT valid = Validate(p);
    if (FAILED(valid)) return valid;
    if (!s.slot || s.slot > 9 || global > 10000) return DIERR_INVALIDPARAM;
    auto blockValid = [](Block b, WORD minimum) { return b.offset >= 2 && !(b.offset & 1) && b.bytes >= minimum && static_cast<DWORD>(b.offset) + b.bytes <= 300; };
    if (Condition(p.kind)) {
        if (((p.axesMask & 1) && !blockValid(s.primary, 8)) || ((p.axesMask & 2) && !blockValid(s.secondary, 8))) return DIERR_INVALIDPARAM;
        for (size_t axis = 0; axis < 2; ++axis) {
            if (!(p.axesMask & (1U << axis))) continue;
            const auto& c = p.condition[axis];
            Report r{}; r[0] = 0x0f;
            Word(r, 1, axis == 0 ? s.primary.offset : s.secondary.offset);
            r[3] = static_cast<BYTE>(Scale(c.lPositiveCoefficient, 100, p.gain, global));
            r[4] = static_cast<BYTE>(Scale(c.lNegativeCoefficient, 100, p.gain, global));
            Word(r, 5, static_cast<WORD>(Scale(c.lOffset, 500, 10000, 10000)));
            Word(r, 7, static_cast<WORD>(Scale(c.lDeadBand, 1000, 10000, 10000)));
            r[9] = static_cast<BYTE>(Scale(static_cast<LONG>(c.dwPositiveSaturation), 100, p.gain, global));
            r[10] = static_cast<BYTE>(Scale(static_cast<LONG>(c.dwNegativeSaturation), 100, p.gain, global));
            reports.push_back(r);
        }
    } else {
        if (!blockValid(s.primary, p.kind == EffectKind::Constant ? 1 : 12)) return DIERR_INVALIDPARAM;
        Report r{};
        Word(r, 1, s.primary.offset);
        if (p.kind == EffectKind::Constant) {
            r[0] = 0x0d;
            r[3] = static_cast<BYTE>(Scale(p.constantMagnitude, 127, p.gain, global));
        } else {
            r[0] = 0x0e;
            r[3] = static_cast<BYTE>(Scale(static_cast<LONG>(p.periodic.dwMagnitude), 127, p.gain, global));
            r[4] = static_cast<BYTE>(Scale(p.periodic.lOffset, 127, p.gain, global));
            r[5] = Angle(p.periodic.dwPhase);
            Word(r, 6, Milliseconds(p.periodic.dwPeriod));
        }
        reports.push_back(r);
        if (!blockValid(s.envelope, 12)) { reports.clear(); return DIERR_INVALIDPARAM; }
        Report e{}; e[0] = 0x0c;
        Word(e, 1, s.envelope.offset);
        if (p.hasEnvelope) {
            Word(e, 3, Milliseconds(p.envelope.dwAttackTime));
            e[5] = static_cast<BYTE>(Scale(static_cast<LONG>(p.envelope.dwAttackLevel), 127, p.gain, global));
            Word(e, 6, Milliseconds(p.envelope.dwFadeTime));
            e[8] = static_cast<BYTE>(Scale(static_cast<LONG>(p.envelope.dwFadeLevel), 127, p.gain, global));
        }
        // Zero attack/fade times preserve the sustain force when no logical
        // envelope was supplied; hasEnvelope and the caller's DTO stay unchanged.
        reports.push_back(e);
    }
    Report e{}; e[0] = 0x0b; e[1] = s.slot; e[2] = Type(p.kind);
    e[3] = static_cast<BYTE>(p.triggerButton | (static_cast<DWORD>(p.axesMask) << 6) | (Condition(p.kind) ? 0 : 0x20));
    Word(e, 4, Milliseconds(p.durationUs)); e[6] = Angle(p.directionHundredths);
    Word(e, 7, Milliseconds(p.triggerRepeatUs));
    Word(e, 9, s.primary.offset);
    Word(e, 11, Condition(p.kind) ? s.secondary.offset : s.envelope.offset);
    Word(e, 13, Milliseconds(p.startDelayUs));
    reports.push_back(e); // Publish effect only after its parameter bytes exist.
    return S_OK;
}
HRESULT EncodeOperation(BYTE slot, bool start, DWORD iterations, Report& report) {
    report = {};
    if (!slot || slot > 9 || (start && (!iterations || (iterations > 254 && iterations != INFINITE)))) return DIERR_INVALIDPARAM;
    report[0] = 0x51; report[1] = slot; report[2] = start ? 2 : 1;
    report[3] = start ? (iterations == INFINITE ? 255 : static_cast<BYTE>(iterations)) : 0;
    return S_OK;
}
Report EncodeControl(BYTE selector) { Report r{}; r[0] = 0x52; r[1] = selector; return r; }
}

namespace {
constexpr DWORD IoTimeoutMs = 750;
struct PendingIo {
    OVERLAPPED overlapped{};
    std::array<BYTE, 64> bytes{};
    HMODULE ownerModule = nullptr;
    PendingIo() { overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr); }
    ~PendingIo() { if (overlapped.hEvent) CloseHandle(overlapped.hEvent); }
};
DWORD WINAPI ReapCancelledIo(void* parameter) {
    auto* io = static_cast<PendingIo*>(parameter);
    WaitForSingleObject(io->overlapped.hEvent, INFINITE);
    const HMODULE ownerModule = io->ownerModule;
    delete io;
    if (ownerModule) FreeLibraryAndExitThread(ownerModule, 0);
    return 0;
}
// A cancellation that fails to settle promptly must not leave an OVERLAPPED or
// buffer on the stack. A waiter owns it until kernel completion, even on close.
HRESULT Transfer(HANDLE handle, const BYTE* input, DWORD size, bool feature, BYTE* output = nullptr) {
    if (size > 64) return E_INVALIDARG;
    std::unique_ptr<PendingIo> io(new (std::nothrow) PendingIo());
    if (!io) return E_OUTOFMEMORY;
    if (!io->overlapped.hEvent) return WinError();
    std::copy_n(input, size, io->bytes.begin());
    DWORD transferred = 0;
    BOOL ok = feature ? DeviceIoControl(handle, IOCTL_HID_GET_FEATURE, io->bytes.data(), size, io->bytes.data(), size, nullptr, &io->overlapped)
        : WriteFile(handle, io->bytes.data(), size, nullptr, &io->overlapped);
    if (!ok && GetLastError() != ERROR_IO_PENDING) return WinError();
    if (!ok) {
        const DWORD wait = WaitForSingleObject(io->overlapped.hEvent, IoTimeoutMs);
        if (wait != WAIT_OBJECT_0) {
            CancelIoEx(handle, &io->overlapped);
            if (WaitForSingleObject(io->overlapped.hEvent, IoTimeoutMs) != WAIT_OBJECT_0) {
                PendingIo* retained = io.release();
                // Keep this DLL mapped until the deferred cleanup exits. COM
                // references may reach zero while cancellation is still pending.
                const BOOL pinned = GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                    reinterpret_cast<LPCWSTR>(&ReapCancelledIo), &retained->ownerModule);
                HANDLE thread = pinned ? CreateThread(nullptr, 0, ReapCancelledIo, retained, 0, nullptr) : nullptr;
                if (thread) CloseHandle(thread);
                // If thread creation fails, intentionally retain the small object
                // until process exit rather than allow a kernel use-after-free.
            }
            return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        }
    }
    // With an asynchronous handle, retrieve the completed byte count from the
    // OVERLAPPED even when the initial API returned immediate success.
    if (!GetOverlappedResult(handle, &io->overlapped, &transferred, FALSE)) return WinError();
    if (transferred != size) return HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);
    if (output) std::copy_n(io->bytes.begin(), size, output);
    return S_OK;
}
bool CheckValue(PHIDP_PREPARSED_DATA preparsed, BYTE id, USAGE page, USHORT link, USAGE usage, ULONG value, size_t offset, WORD expected, bool wide = false) {
    protocol::Report r{}; r[0] = id;
    if (HidP_SetUsageValue(HidP_Output, page, link, usage, value, preparsed, reinterpret_cast<PCHAR>(r.data()), static_cast<ULONG>(r.size())) != HIDP_STATUS_SUCCESS) return false;
    protocol::Report target{}; target[0] = id;
    if (wide) Word(target, offset, expected); else target[offset] = static_cast<BYTE>(expected);
    return r == target;
}
bool CheckButton(PHIDP_PREPARSED_DATA preparsed, BYTE id, USAGE page, USHORT link, USAGE usage, size_t offset, BYTE expected) {
    protocol::Report r{}; r[0] = id; ULONG count = 1;
    if (HidP_SetUsages(HidP_Output, page, link, &usage, &count, preparsed, reinterpret_cast<PCHAR>(r.data()), static_cast<ULONG>(r.size())) != HIDP_STATUS_SUCCESS) return false;
    protocol::Report target{}; target[0] = id; target[offset] = expected;
    return r == target;
}
HRESULT InspectProtocol(HANDLE handle, protocol::PoolConfig& pool) {
    HIDD_ATTRIBUTES attributes{}; attributes.Size = sizeof(attributes);
    if (!HidD_GetAttributes(handle, &attributes)) return WinError();
    if (attributes.VendorID != 0x06a3 || attributes.ProductID != 0xffb5) return DIERR_DEVICENOTREG;
    PHIDP_PREPARSED_DATA raw = nullptr;
    if (!HidD_GetPreparsedData(handle, &raw)) return WinError();
    struct Owner { PHIDP_PREPARSED_DATA p; ~Owner() { HidD_FreePreparsedData(p); } } owned{raw};
    HIDP_CAPS caps{};
    if (HidP_GetCaps(raw, &caps) != HIDP_STATUS_SUCCESS || caps.UsagePage != 1 || caps.Usage != 4 ||
        caps.InputReportByteLength != 9 || caps.OutputReportByteLength != 15 || caps.FeatureReportByteLength != 9) return DIERR_UNSUPPORTED;
    // Compare parser-generated single-field reports with the original encoder's
    // geometry. In particular, type offsets are Ordinal-page values at link 6.
    struct Field { BYTE id; USAGE page; USHORT link; USAGE usage; ULONG value; size_t byte; WORD encoded; bool wide; };
    const Field fields[] = {
        {0x0b,15,3,0x22,7,1,7,false},{0x0b,15,3,0x53,5,3,5,false},
        {0x0b,15,3,0x50,1234,4,1234,true},{0x0b,15,3,0x57,127,6,127,false},
        {0x0b,15,3,0x54,321,7,321,true},{0x0b,10,6,1,42,9,42,true},{0x0b,10,6,2,84,11,84,true},
        {0x0b,15,3,0xa7,234,13,234,true},
        {0x0c,15,7,0x23,24,1,24,true},{0x0c,15,7,0x5c,123,3,123,true},{0x0c,15,7,0x5b,63,5,63,false},
        {0x0c,15,7,0x5e,345,6,345,true},{0x0c,15,7,0x5d,31,8,31,false},
        {0x0d,15,8,0x23,26,1,26,true},{0x0d,15,8,0x70,static_cast<ULONG>(-127),3,129,false},
        {0x0e,15,9,0x23,28,1,28,true},{0x0e,15,9,0x70,63,3,63,false},
        {0x0e,15,9,0x6f,static_cast<ULONG>(-127),4,129,false},{0x0e,15,9,0x71,63,5,63,false},{0x0e,15,9,0x72,123,6,123,true},
        {0x0f,15,10,0x23,30,1,30,true},{0x0f,15,10,0x61,static_cast<ULONG>(-100),3,156,false},
        {0x0f,15,10,0x62,100,4,100,false},{0x0f,15,10,0x60,static_cast<ULONG>(-500),5,65036,true},
        {0x0f,15,10,0x65,500,7,500,true},{0x0f,15,10,0x63,100,9,100,false},{0x0f,15,10,0x64,100,10,100,false},
        {0x51,15,11,0x22,7,1,7,false},{0x51,15,11,0x7c,12,3,12,false}
        ,{0x43,15,17,0x7e,128,1,128,false}
    };
    for (const auto& f : fields) if (!CheckValue(raw, f.id, f.page, f.link, f.usage, f.value, f.byte, f.encoded, f.wide)) return DIERR_UNSUPPORTED;
    const USAGE types[] = {0x26,0x30,0x32,0x31,0x33,0x34,0x40,0x41};
    for (BYTE i = 0; i < 8; ++i) if (!CheckButton(raw,0x0b,15,4,types[i],2,static_cast<BYTE>(i+1))) return DIERR_UNSUPPORTED;
    if (!CheckButton(raw,0x0b,15,3,0x56,3,0x20) || !CheckButton(raw,0x0b,1,5,0x30,3,0x40) || !CheckButton(raw,0x0b,1,5,0x31,3,0x80)) return DIERR_UNSUPPORTED;
    const USAGE operations[] = {0x7b,0x79,0x7a};
    for (BYTE i = 0; i < 3; ++i) if (!CheckButton(raw,0x51,15,12,operations[i],2,static_cast<BYTE>(i+1))) return DIERR_UNSUPPORTED;
    const USAGE commands[] = {0x9a,0x99,0x97,0x98,0x9b,0x9c};
    for (BYTE i = 0; i < 6; ++i) if (!CheckButton(raw,0x52,15,14,commands[i],1,static_cast<BYTE>(i+1))) return DIERR_UNSUPPORTED;
    std::array<BYTE,9> feature{}; feature[0] = 0x0b;
    const HRESULT result = Transfer(handle, feature.data(), static_cast<DWORD>(feature.size()), true, feature.data());
    if (FAILED(result)) return result;
    auto value = [&](USHORT link, USAGE usage, ULONG& output) {
        return HidP_GetUsageValue(HidP_Feature, 15, link, usage, &output, raw, reinterpret_cast<PCHAR>(feature.data()), static_cast<ULONG>(feature.size())) == HIDP_STATUS_SUCCESS;
    };
    ULONG bytes=0, alignment=0, count=0, constant=0, periodic=0, envelope=0, condition=0;
    if (!value(20,0x80,bytes) || !value(20,0x84,alignment) || !value(20,0x83,count) || !value(21,0x73,constant) ||
        !value(21,0x6e,periodic) || !value(21,0x5a,envelope) || !value(21,0x5f,condition)) return DIERR_UNSUPPORTED;
    USAGE usages[8]{}; ULONG usagesCount = 8;
    if (HidP_GetUsages(HidP_Feature,15,20,usages,&usagesCount,raw,reinterpret_cast<PCHAR>(feature.data()),static_cast<ULONG>(feature.size())) != HIDP_STATUS_SUCCESS) return DIERR_UNSUPPORTED;
    for (ULONG i = 0; i < usagesCount; ++i) if (usages[i] == 0xa9) return DIERR_UNSUPPORTED;
    if (bytes != 300 || alignment != 2 || count != 10 || constant != 1 || periodic != 12 || envelope != 12 || condition != 8) return DIERR_UNSUPPORTED;
    pool = {static_cast<WORD>(bytes),static_cast<WORD>(alignment),9,static_cast<WORD>(constant),static_cast<WORD>(periodic),static_cast<WORD>(envelope),static_cast<WORD>(condition)};
    return S_OK;
}
}

struct HidPidDevice::Impl {
    struct Entry {
        DWORD handle = 0;
        EffectParams params{};
        protocol::EffectStorage storage{};
        bool playing = false;
        ULONGLONG endsAt = 0;
    };
    HANDLE device = INVALID_HANDLE_VALUE;
    std::mutex lock;
    protocol::PoolAllocator pool;
    std::array<Entry,9> entries{};
    DWORD gain = 10000;
    bool enabled = false;
    bool paused = false;
    ULONGLONG pausedAt = 0;
#ifdef SAITEK_PROTOCOL_TESTS
    HidPidDevice::TestWriter testWriter = nullptr;
    void* testContext = nullptr;
#endif
    bool Opened() const {
#ifdef SAITEK_PROTOCOL_TESTS
        if (testWriter) return true;
#endif
        return device != INVALID_HANDLE_VALUE;
    }
    HRESULT RawWrite(const protocol::Report& report) {
#ifdef SAITEK_PROTOCOL_TESTS
        if (testWriter) return testWriter(report,testContext);
#endif
        return Transfer(device,report.data(),static_cast<DWORD>(report.size()),false);
    }
    HRESULT Write(const protocol::Report& report) {
        if (!Opened()) return DIERR_NOTINITIALIZED;
        const HRESULT hr = RawWrite(report);
        if (FAILED(hr)) {
            // Stop/off are best effort after a partial transfer; then discard all
            // client state and close. No offsets can be reused on this session.
            const auto stop = protocol::EncodeControl(2);
            const auto off = protocol::EncodeControl(4);
            RawWrite(stop); RawWrite(off);
            if (device != INVALID_HANDLE_VALUE) CloseHandle(device);
            device = INVALID_HANDLE_VALUE;
#ifdef SAITEK_PROTOCOL_TESTS
            testWriter=nullptr;
#endif
            entries = {}; pool.Clear(); enabled = false; paused = false;
        }
        return hr;
    }
    Entry* Find(DWORD handle) {
        for (auto& entry : entries) if (entry.handle == handle && handle) return &entry;
        return nullptr;
    }
    void Refresh(Entry& e) {
        if (!paused && e.playing && e.endsAt && GetTickCount64() >= e.endsAt) e.playing = false;
    }
    void Close() {
        if (Opened()) {
            const auto stop=protocol::EncodeControl(2), off=protocol::EncodeControl(4);
            RawWrite(stop); RawWrite(off);
            if (device != INVALID_HANDLE_VALUE) CloseHandle(device);
            device = INVALID_HANDLE_VALUE;
#ifdef SAITEK_PROTOCOL_TESTS
            testWriter=nullptr;
#endif
        }
        entries = {}; pool.Clear(); enabled = false; paused = false; pausedAt = 0;
    }
};
HidPidDevice::HidPidDevice() : impl_(std::make_unique<Impl>()) {}
HidPidDevice::~HidPidDevice() { Close(); }
HRESULT HidPidDevice::Open(const wchar_t* path) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    impl_->Close();
    if (!path || !*path) return E_INVALIDARG;
    HANDLE handle=CreateFileW(path,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
    if (handle == INVALID_HANDLE_VALUE) return WinError();
    protocol::PoolConfig config{};
    const HRESULT inspected=InspectProtocol(handle,config);
    if (FAILED(inspected)) { CloseHandle(handle); return inspected; }
    impl_->device=handle; impl_->pool=protocol::PoolAllocator(config); impl_->gain=10000;
    HRESULT hr=impl_->Write(protocol::EncodeControl(1));
    if (SUCCEEDED(hr)) hr=impl_->Write(protocol::EncodeControl(4));
    // Global and per-effect gain are applied once, in parameter encoding.
    protocol::Report nominalGain{}; nominalGain[0]=0x43; nominalGain[1]=128;
    if (SUCCEEDED(hr)) hr=impl_->Write(nominalGain);
    return hr;
}
HRESULT HidPidDevice::Download(DWORD handle,const EffectParams& params) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    if (!impl_->Opened()) return DIERR_NOTINITIALIZED;
    if (!handle) return E_INVALIDARG;
    const HRESULT valid=protocol::Validate(params); if (FAILED(valid)) return valid;
    auto* entry=impl_->Find(handle);
    if (entry) {
        impl_->Refresh(*entry);
        if (entry->playing) {
            if (!protocol::CanUpdateInPlace(entry->params,params)) return DIERR_EFFECTPLAYING;
            std::vector<protocol::Report> liveReports;
            HRESULT hr=protocol::EncodeEffect(params,entry->storage,impl_->gain,liveReports);
            if (FAILED(hr)) return hr;
            for (const auto& report : liveReports) { hr=impl_->Write(report); if (FAILED(hr)) return hr; }
            entry->params=params;
            return S_OK;
        }
    }
    if (!entry) for (auto& e : impl_->entries) if (!e.handle) { entry=&e; break; }
    if (!entry) return DIERR_DEVICEFULL;
    auto candidate=impl_->pool;
    if (entry->handle) protocol::FreeEffect(candidate,entry->storage);
    protocol::EffectStorage storage{};
    const BYTE slot=static_cast<BYTE>(entry-impl_->entries.data()+1);
    HRESULT hr=protocol::AllocateEffect(candidate,slot,params,storage);
    if (FAILED(hr)) return hr;
    std::vector<protocol::Report> reports;
    hr=protocol::EncodeEffect(params,storage,impl_->gain,reports);
    if (FAILED(hr)) return hr;
    for (const auto& report : reports) { hr=impl_->Write(report); if (FAILED(hr)) return hr; }
    impl_->pool=std::move(candidate);
    *entry={handle,params,storage,false,0};
    return S_OK;
}
HRESULT HidPidDevice::Start(DWORD handle,DWORD iterations) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    if (!impl_->Opened()) return DIERR_NOTINITIALIZED;
    auto* entry=impl_->Find(handle); if (!entry) return DIERR_NOTDOWNLOADED;
    // Actuators Off mutes playback; it does not revoke acquisition or stop
    // effect time. The COM layer owns the policy for enabling on explicit Start.
    if (impl_->paused) return DIERR_NOTEXCLUSIVEACQUIRED;
    protocol::Report report{};
    HRESULT hr=protocol::EncodeOperation(entry->storage.slot,true,iterations,report);
    if (FAILED(hr)) return hr;
    hr=impl_->Write(report); if (FAILED(hr)) return hr;
    entry->playing=true;
    entry->endsAt=(iterations == INFINITE || entry->params.durationUs == INFINITE || entry->params.triggerButton) ? 0 :
        GetTickCount64()+Milliseconds(entry->params.startDelayUs)+static_cast<ULONGLONG>(Milliseconds(entry->params.durationUs))*iterations;
    return S_OK;
}
HRESULT HidPidDevice::Stop(DWORD handle) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    if (!impl_->Opened()) return DIERR_NOTINITIALIZED;
    auto* entry=impl_->Find(handle); if (!entry) return DIERR_NOTDOWNLOADED;
    protocol::Report report{}; protocol::EncodeOperation(entry->storage.slot,false,0,report);
    const HRESULT hr=impl_->Write(report); if (FAILED(hr)) return hr;
    entry->playing=false; entry->endsAt=0;
    return S_OK;
}
HRESULT HidPidDevice::StopAll() {
    std::lock_guard<std::mutex> guard(impl_->lock);
    const HRESULT hr=impl_->Write(protocol::EncodeControl(2)); if (FAILED(hr)) return hr;
    for (auto& e : impl_->entries) { e.playing=false; e.endsAt=0; }
    return S_OK;
}
HRESULT HidPidDevice::Destroy(DWORD handle) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    if (!impl_->Opened()) return DIERR_NOTINITIALIZED;
    auto* entry=impl_->Find(handle); if (!entry) return DIERR_NOTDOWNLOADED;
    protocol::Report report{}; protocol::EncodeOperation(entry->storage.slot,false,0,report);
    const HRESULT hr=impl_->Write(report); if (FAILED(hr)) return hr;
    protocol::FreeEffect(impl_->pool,entry->storage); *entry={};
    return S_OK;
}
HRESULT HidPidDevice::Reset() {
    std::lock_guard<std::mutex> guard(impl_->lock);
    const HRESULT hr=impl_->Write(protocol::EncodeControl(1)); if (FAILED(hr)) return hr;
    impl_->entries={}; impl_->pool.Clear(); impl_->paused=false;
    // DirectInput RESET returns the force-feedback system to its disabled
    // startup state. The physical PID reset itself enables actuators, so mute
    // immediately before restoring nominal gain.
    const HRESULT off=impl_->Write(protocol::EncodeControl(4)); if (FAILED(off)) return off;
    impl_->enabled=false;
    protocol::Report nominalGain{}; nominalGain[0]=0x43; nominalGain[1]=128;
    const HRESULT gain=impl_->Write(nominalGain); if (FAILED(gain)) return gain;
    return S_OK;
}
HRESULT HidPidDevice::SetGain(DWORD gain) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    if (gain>10000) return E_INVALIDARG;
    if (!impl_->Opened()) return DIERR_NOTINITIALIZED;
    std::vector<protocol::Report> batch;
    batch.reserve(27);
    for (const auto& entry : impl_->entries) {
        if (!entry.handle) continue;
        std::vector<protocol::Report> reports;
        const HRESULT hr=protocol::EncodeEffect(entry.params,entry.storage,gain,reports); if (FAILED(hr)) return hr;
        // Only parameter amplitudes change. Do not republish Set Effect or Start.
        batch.insert(batch.end(),reports.begin(),reports.end()-1);
    }
    // All allocations finish before the first mutation, so an allocation
    // failure cannot leave some effects at the new gain and others at the old.
    for (const auto& report : batch) { const HRESULT written=impl_->Write(report); if (FAILED(written)) return written; }
    impl_->gain=gain;
    return S_OK;
}
HRESULT HidPidDevice::SetActuators(bool enabled) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    const HRESULT hr=impl_->Write(protocol::EncodeControl(enabled ? 3 : 4)); if (FAILED(hr)) return hr;
    impl_->enabled=enabled;
    return S_OK;
}
HRESULT HidPidDevice::Pause(bool paused) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    if (!impl_->Opened()) return DIERR_NOTINITIALIZED;
    if (impl_->paused == paused) return S_OK;
    const HRESULT hr=impl_->Write(protocol::EncodeControl(paused ? 5 : 6)); if (FAILED(hr)) return hr;
    const ULONGLONG now=GetTickCount64();
    if (paused) { for (auto& e : impl_->entries) impl_->Refresh(e); impl_->pausedAt=now; }
    else for (auto& e : impl_->entries) if (e.endsAt) e.endsAt+=now-impl_->pausedAt;
    impl_->paused=paused;
    return S_OK;
}
HRESULT HidPidDevice::GetState(DeviceState& state) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    state={}; if (!impl_->Opened()) return DIERR_NOTINITIALIZED;
    state.actuatorsEnabled=impl_->enabled; state.paused=impl_->paused;
    state.memoryLoad=impl_->pool.Used()*100/(impl_->pool.Config().bytes-impl_->pool.Config().alignment);
    for (auto& e : impl_->entries) if (e.handle) { ++state.effectCount; impl_->Refresh(e); state.anyPlaying=state.anyPlaying||e.playing; }
    return S_OK;
}
HRESULT HidPidDevice::IsPlaying(DWORD handle,bool& playing) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    playing=false; if (!impl_->Opened()) return DIERR_NOTINITIALIZED;
    auto* e=impl_->Find(handle); if (!e) return DIERR_NOTDOWNLOADED;
    impl_->Refresh(*e); playing=e->playing; return S_OK;
}
void HidPidDevice::Close() noexcept {
    try { std::lock_guard<std::mutex> guard(impl_->lock); impl_->Close(); }
    catch (...) {
        // Cleanup must not terminate X-Plane/Bridge even under resource pressure.
        if (impl_->device != INVALID_HANDLE_VALUE) CloseHandle(impl_->device);
        impl_->device=INVALID_HANDLE_VALUE;
    }
}
#ifdef SAITEK_PROTOCOL_TESTS
HRESULT HidPidDevice::OpenForTesting(TestWriter writer, void* context) {
    std::lock_guard<std::mutex> guard(impl_->lock);
    impl_->Close();
    if (!writer) return E_INVALIDARG;
    impl_->testWriter=writer; impl_->testContext=context; impl_->gain=10000;
    HRESULT hr=impl_->Write(protocol::EncodeControl(1));
    if (SUCCEEDED(hr)) hr=impl_->Write(protocol::EncodeControl(4));
    protocol::Report nominalGain{}; nominalGain[0]=0x43; nominalGain[1]=128;
    if (SUCCEEDED(hr)) hr=impl_->Write(nominalGain);
    return hr;
}
HRESULT HidPidDevice::WriteForTesting(HANDLE handle,const protocol::Report& report) {
    return Transfer(handle,report.data(),static_cast<DWORD>(report.size()),false);
}
#endif
}
