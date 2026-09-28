// Executes the production COM implementation with an in-memory transport.
// No test path can open a HID handle, write reports or register the DLL.
#include "../HidPidDevice.h"
#include <cstdio>
#include <map>
#include <stdexcept>

class TestDevice {
public:
    static TestDevice* latest;
    static unsigned opens;
    static unsigned closes;
    struct Entry { saitek::EffectParams params; bool playing = false; };
    std::map<DWORD, Entry> entries;
    bool open = false;
    bool enabled = false;
    bool paused = false;
    bool poisonNext = false;
    bool fullNext = false;
    bool failNextActuator = false;
    unsigned downloads = 0;
    unsigned starts = 0;
    unsigned stops = 0;
    unsigned stopAll = 0;
    unsigned actuatorWrites = 0;
    DWORD gain = 10000;
    HRESULT Open(const wchar_t*) { open = true; latest = this; ++opens; return S_OK; }
    void Close() noexcept { if (open) { ++closes; open = false; } entries.clear(); }
    ~TestDevice() { Close(); }
    HRESULT Download(DWORD handle, const saitek::EffectParams& value) {
        if (poisonNext) { poisonNext = false; open = false; entries.clear(); return HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED); }
        if (fullNext) { fullNext = false; return DIERR_DEVICEFULL; }
        auto old = entries.find(handle);
        if (old != entries.end() && old->second.playing &&
            (old->second.params.durationUs != value.durationUs || old->second.params.axesMask != value.axesMask)) return DIERR_EFFECTPLAYING;
        bool playing = old != entries.end() && old->second.playing;
        entries[handle] = {value, playing}; ++downloads; return S_OK;
    }
    HRESULT Start(DWORD handle, DWORD) { auto item = entries.find(handle); if (item == entries.end()) return DIERR_NOTDOWNLOADED; item->second.playing = true; ++starts; return S_OK; }
    HRESULT Stop(DWORD handle) { auto item = entries.find(handle); if (item == entries.end()) return DIERR_NOTDOWNLOADED; item->second.playing = false; ++stops; return S_OK; }
    HRESULT StopAll() { for (auto& item : entries) item.second.playing = false; ++stopAll; return S_OK; }
    HRESULT Destroy(DWORD handle) { entries.erase(handle); return S_OK; }
    HRESULT Reset() { entries.clear(); paused = false; enabled = false; return S_OK; }
    HRESULT SetGain(DWORD value) { gain = value; return S_OK; }
    HRESULT SetActuators(bool value) {
        ++actuatorWrites;
        if (failNextActuator) { failNextActuator = false; return E_FAIL; }
        enabled = value; return S_OK;
    }
    HRESULT Pause(bool value) { paused = value; return S_OK; }
    HRESULT GetState(saitek::DeviceState& state) {
        if (!open) return HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);
        state = {}; state.actuatorsEnabled = enabled; state.paused = paused;
        state.effectCount = static_cast<DWORD>(entries.size());
        for (const auto& item : entries) state.anyPlaying |= item.second.playing;
        return S_OK;
    }
    HRESULT IsPlaying(DWORD handle, bool& playing) {
        if (!open) return HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);
        auto item = entries.find(handle); if (item == entries.end()) return DIERR_NOTDOWNLOADED;
        playing = item->second.playing; return S_OK;
    }
};
TestDevice* TestDevice::latest = nullptr;
unsigned TestDevice::opens = 0;
unsigned TestDevice::closes = 0;
#define SAITEK_DRIVER_TEST
#include "../SaitekFfbDriver.cpp"

namespace {
unsigned checks = 0;
void Check(bool success, const char* label) {
    ++checks;
    if (!success) { std::printf("FAIL check=%s\n", label); throw std::runtime_error(label); }
}
struct Fixture {
    DWORD axes[2] = {0x01000002, 0x01000102}; // Exact native IDs, including reserved bits.
    LONG directions[2] = {9000, 0};
    DICONSTANTFORCE constant{1000};
    DICONDITION conditions[2]{};
    DIEFFECT effect{};
    Fixture() {
        effect.dwSize = sizeof(effect); effect.dwFlags = DIEFF_POLAR; // Actual DirectInput strips OBJECTIDS.
        effect.dwDuration = 750000; effect.dwGain = 500;
        effect.dwTriggerButton = DIEB_NOTRIGGER;
        effect.cAxes = 2; effect.rgdwAxes = axes; effect.rglDirection = directions;
        effect.cbTypeSpecificParams = sizeof(constant); effect.lpvTypeSpecificParams = &constant;
    }
};
void ContractTests() {
    Check(DllCanUnloadNow() == S_OK, "initial unload");
    void* none = reinterpret_cast<void*>(1);
    Check(DllGetClassObject(GUID_NULL, IID_IClassFactory, &none) == CLASS_E_CLASSNOTAVAILABLE && none == nullptr, "wrong CLSID");
    IClassFactory* factory = nullptr;
    Check(DllGetClassObject(kDriverClass, IID_IClassFactory, reinterpret_cast<void**>(&factory)) == S_OK, "factory");
    Check(DllCanUnloadNow() == S_FALSE, "factory owns module");
    Check(factory->LockServer(TRUE) == S_OK && factory->LockServer(FALSE) == S_OK, "server lock balance");
    Check(factory->LockServer(FALSE) == E_UNEXPECTED, "server lock underflow rejected");
    Check(factory->CreateInstance(factory, kEffectDriverIid, &none) == CLASS_E_NOAGGREGATION, "aggregation rejected");
    IDirectInputEffectDriver* driver = nullptr;
    Check(factory->CreateInstance(nullptr, kEffectDriverIid, reinterpret_cast<void**>(&driver)) == S_OK, "driver instance");
    factory->Release();
    Check(DllCanUnloadNow() == S_FALSE, "driver owns module");
    wchar_t path[] = L"\\\\?\\hid#vid_06a3&pid_ffb5#test#{test}";
    DIHIDFFINITINFO info{sizeof(info), path, GUID_NULL};
    Check(driver->DeviceID(0x800, 7, 1, 0, &info) == S_OK, "begin external ID");
    Check(TestDevice::opens == 0 && TestDevice::latest == nullptr, "begin no hardware ownership");
    Check(driver->DeviceID(0x800, 7, 1, 0, &info) == DIERR_ACQUIRED, "duplicate begin stable");
    Check(driver->SetGain(8, 100) == DIERR_NOTINITIALIZED, "wrong external ID");
    Check(driver->SetGain(7, 9000) == S_OK && TestDevice::opens == 0, "gain initialization remains passive");
    Check(driver->SendForceFeedbackCommand(7, DISFFC_STOPALL) == S_OK &&
        driver->SendForceFeedbackCommand(7, DISFFC_SETACTUATORSOFF) == S_OK &&
        driver->SendForceFeedbackCommand(7, DISFFC_RESET) == S_OK && TestDevice::opens == 0, "unopened cleanup no ownership");
    Fixture f;
    DWORD handle = 0;
    Check(driver->DownloadEffect(7, 0x26, &handle, &f.effect, DIEP_ALLPARAMS | DIEP_NODOWNLOAD | DIEP_START) == S_OK && handle != 0, "NODOWNLOAD overrides START");
    Check(TestDevice::opens == 0 && TestDevice::latest == nullptr, "NODOWNLOAD no transport");
    f.constant.lMagnitude = 9000;
    f.axes[0] = 0xffffffff;
    Check(driver->StartEffect(7, handle, 0, 1) == S_OK, "start cached owned effect");
    TestDevice* transport = TestDevice::latest;
    Check(transport && !transport->enabled, "passive OFF survives RESET and lazy muted Start");
    Check(transport->entries.at(handle).params.constantMagnitude == 1000 && transport->entries.at(handle).params.axesMask == 3, "deep owned source buffers");
    Check(transport->starts == 1 && transport->downloads == 1, "one explicit start");
    f.axes[0] = 0x01000002;
    unsigned stops = transport->stops;
    Check(driver->DownloadEffect(7, 0x26, &handle, &f.effect, DIEP_TYPESPECIFICPARAMS | DIEP_NORESTART) == S_OK, "live magnitude update");
    Check(transport->starts == 1 && transport->stops == stops && transport->entries.at(handle).params.constantMagnitude == 9000, "live update no restart");
    f.effect.dwDuration = 1000000;
    Check(driver->DownloadEffect(7, 0x26, &handle, &f.effect, DIEP_DURATION | DIEP_NORESTART) == DIERR_EFFECTPLAYING, "NORESTART layout refusal");
    Check(transport->entries.at(handle).params.durationUs == 750000 && transport->starts == 1, "failed update preserves old");
    Check(driver->DownloadEffect(7, 0x26, &handle, &f.effect, DIEP_DURATION) == S_OK, "restart allowed update");
    Check(transport->starts == 2 && transport->stops == stops + 1, "required restart once");
    DWORD status = 0;
    Check(driver->GetEffectStatus(7, handle, &status) == S_OK && status == DIEGES_PLAYING, "playing status");
    Check(driver->SendForceFeedbackCommand(7, DISFFC_PAUSE) == S_OK && transport->paused, "pause command");
    Check(driver->SendForceFeedbackCommand(7, DISFFC_CONTINUE) == S_OK && !transport->paused, "continue command");
    Check(driver->SendForceFeedbackCommand(7, DISFFC_SETACTUATORSON) == S_OK && transport->enabled, "explicit actuators");
    Check(driver->SetGain(7, 2000) == S_OK && transport->gain == 2000, "global gain forwarded once");
    Check(driver->SetGain(7, 10001) == E_INVALIDARG && transport->gain == 2000, "invalid gain no mutation");
    DWORD second = 0;
    Check(driver->DownloadEffect(7, 0x26, &second, &f.effect, DIEP_ALLPARAMS) == S_OK && second != handle, "unique handles");
    Check(driver->StartEffect(7, second, DIES_SOLO, 1) == S_OK && !transport->entries.at(handle).playing, "SOLO stops other effect");
    Check(driver->StartEffect(7, second, 0, 255) == E_INVALIDARG, "unrepresentable repeats rejected");
    Check(driver->StartEffect(7, second, 0, INFINITE) == S_OK, "explicit infinite repeats");
    Check(driver->DestroyEffect(7, handle) == S_OK && transport->entries.count(handle) == 0, "destroy releases physical");
    Check(driver->GetEffectStatus(7, handle, &status) == DIERR_INVALIDPARAM, "stale handle rejected");
    DWORD failureHandle = 0;
    transport->fullNext = true;
    Check(driver->DownloadEffect(7, 0x26, &failureHandle, &f.effect, DIEP_ALLPARAMS) == DIERR_DEVICEFULL && failureHandle == 0, "new failure no public handle");
    Check(driver->SendForceFeedbackCommand(7, DISFFC_RESET) == S_OK && transport->entries.empty(), "reset clears effects");
    Check(driver->StartEffect(7, second, 0, 1) == DIERR_INVALIDPARAM, "reset invalidates handles");
    DWORD afterReset = 0;
    Check(driver->DownloadEffect(7, 0x26, &afterReset, &f.effect, DIEP_ALLPARAMS) == S_OK && afterReset != second, "no stale handle reuse");
    transport->poisonNext = true;
    Check(FAILED(driver->DownloadEffect(7, 0x26, &afterReset, &f.effect, DIEP_ALLPARAMS)) && afterReset == 0, "I/O poison loses handle");
    DIDEVICESTATE state{sizeof(state), 0, 0};
    Check(FAILED(driver->GetForceFeedbackState(7, &state)) && state.dwState == DIGFFS_DEVICELOST, "lost device state");
    Check(driver->DeviceID(0x800, 7, 0, 0, nullptr) == S_OK, "end external ID");
    Check(driver->DeviceID(0x800, 7, 1, 0, &info) == S_OK, "reconnect creates clean context");
    Check(driver->GetEffectStatus(7, second, &status) == DIERR_INVALIDPARAM, "reconnect rejects prior handles");
    Check(driver->DeviceID(0x800, 7, 0, 0, nullptr) == S_OK, "reconnect end");
    driver->Release();
    Check(DllCanUnloadNow() == S_OK, "all COM references released");
}

void ParameterTests() {
    Fixture f;
    saitek::EffectParams p{};
    Check(Normalize(0x26, &f.effect, p) == S_OK && p.directionHundredths == 9000, "native POLAR object IDs no addressing flag");
    f.effect.cAxes = 1; f.directions[0] = 0;
    Check(Normalize(0x26, &f.effect, p) == S_OK && p.axesMask == 1 && p.directionHundredths == 9000, "one-axis native polar X");
    f.effect.dwFlags = DIEFF_CARTESIAN;
    Check(Normalize(0x26, &f.effect, p) == S_OK && p.directionHundredths == 9000, "one-axis Cartesian zero direction");
    f.axes[0] = 0x01000102;
    Check(Normalize(0x26, &f.effect, p) == S_OK && p.axesMask == 2 && p.directionHundredths == 18000, "one-axis Y maps physical Y");
    f.effect.dwFlags = DIEFF_OBJECTOFFSETS | DIEFF_CARTESIAN;
    Check(Normalize(0x26, &f.effect, p) == E_INVALIDARG, "driver rejects object offsets");
    f = Fixture(); // Pointers are rebound below because fixture assignment is intentionally shallow.
    f.effect.rgdwAxes = f.axes; f.effect.rglDirection = f.directions; f.effect.lpvTypeSpecificParams = &f.constant;
    f.axes[1] = f.axes[0];
    Check(Normalize(0x26, &f.effect, p) == E_INVALIDARG, "duplicate axes rejected");
    f.axes[1] = 0x01000102;
    f.effect.cbTypeSpecificParams = sizeof(DICONDITION);
    f.effect.lpvTypeSpecificParams = f.conditions;
    Check(Normalize(0x40, &f.effect, p) == DIERR_UNSUPPORTED, "rotated single condition unsupported");
    f.effect.cbTypeSpecificParams = sizeof(f.conditions);
    f.conditions[0].lPositiveCoefficient = 100; f.conditions[1].lPositiveCoefficient = 200;
    Check(Normalize(0x40, &f.effect, p) == S_OK && p.condition[0].lPositiveCoefficient == 100 && p.condition[1].lPositiveCoefficient == 200, "conditions mapped axes");
    f.axes[0] = 0x01000102; f.axes[1] = 0x01000002;
    Check(Normalize(0x40, &f.effect, p) == S_OK && p.condition[0].lPositiveCoefficient == 200 && p.condition[1].lPositiveCoefficient == 100, "reversed condition axis order");
    Check(Normalize(0x42, &f.effect, p) == DIERR_UNSUPPORTED, "unadvertised inertia rejected");
}

void ActuatorPolicyTests() {
    auto* driver = new EffectDriver;
    wchar_t path[] = L"\\\\?\\hid#vid_06a3&pid_ffb5#actuator-policy#{test}";
    DIHIDFFINITINFO info{sizeof(info), path, GUID_NULL};
    const unsigned beforeOpen = TestDevice::opens;
    Check(driver->DeviceID(0x800, 9, 1, 0, &info) == S_OK, "policy begin");
    DIDEVICESTATE state{sizeof(state), 0, 0};
    Check(driver->GetForceFeedbackState(9, &state) == S_OK && (state.dwState & DIGFFS_ACTUATORSOFF) &&
        TestDevice::opens == beforeOpen, "passive state never opens or enables");
    Fixture f;
    DWORD handle = 0;
    Check(driver->DownloadEffect(9, 0x26, &handle, &f.effect, DIEP_ALLPARAMS) == S_OK, "policy download");
    auto* transport = TestDevice::latest;
    Check(transport && !transport->enabled && transport->actuatorWrites == 0 && transport->starts == 0,
        "download never enables or starts");
    Check(driver->StartEffect(9, handle, 0, 0) == E_INVALIDARG && transport->actuatorWrites == 0,
        "invalid Start never enables");
    transport->failNextActuator = true;
    Check(driver->StartEffect(9, handle, 0, 1) == E_FAIL && !transport->enabled && transport->starts == 0,
        "failed enable prevents playback");
    Check(driver->StartEffect(9, handle, 0, 1) == S_OK && transport->enabled && transport->starts == 1,
        "ordinary Start enables lazily");
    const unsigned writes = transport->actuatorWrites;
    Check(driver->DownloadEffect(9, 0x26, &handle, &f.effect, DIEP_TYPESPECIFICPARAMS | DIEP_NORESTART) == S_OK &&
        transport->actuatorWrites == writes && transport->starts == 1, "live update no extra enable or Start");
    Check(driver->SendForceFeedbackCommand(9, DISFFC_RESET) == S_OK && !transport->enabled && transport->entries.empty(),
        "RESET removes effects and leaves physical actuators off");
    handle = 0;
    Check(driver->DownloadEffect(9, 0x26, &handle, &f.effect, DIEP_ALLPARAMS | DIEP_START) == S_OK && transport->enabled,
        "DIEP_START uses lazy enable after RESET");
    Check(driver->SendForceFeedbackCommand(9, DISFFC_SETACTUATORSOFF) == S_OK && !transport->enabled,
        "explicit OFF mutes");
    unsigned mutedWrites = transport->actuatorWrites;
    Check(driver->StartEffect(9, handle, 0, 1) == S_OK && !transport->enabled &&
        transport->actuatorWrites == mutedWrites && transport->entries.at(handle).playing,
        "Start under OFF plays muted without enabling");
    Check(driver->GetForceFeedbackState(9, &state) == S_OK && (state.dwState & DIGFFS_ACTUATORSOFF) &&
        !(state.dwState & DIGFFS_STOPPED), "muted playing status remains accurate");
    Check(driver->SendForceFeedbackCommand(9, DISFFC_STOPALL) == S_OK &&
        driver->SendForceFeedbackCommand(9, DISFFC_RESET) == S_OK, "muted STOPALL RESET");
    handle = 0;
    Check(driver->DownloadEffect(9, 0x26, &handle, &f.effect, DIEP_ALLPARAMS | DIEP_START) == S_OK &&
        !transport->enabled && transport->actuatorWrites == mutedWrites, "explicit OFF survives RESET");
    transport->failNextActuator = true;
    Check(driver->SendForceFeedbackCommand(9, DISFFC_SETACTUATORSON) == E_FAIL && !transport->enabled,
        "failed ON leaves mute intact");
    mutedWrites = transport->actuatorWrites;
    Check(driver->StartEffect(9, handle, 0, 1) == S_OK && !transport->enabled && transport->actuatorWrites == mutedWrites,
        "Start cannot clear mute after failed ON");
    Check(driver->SendForceFeedbackCommand(9, DISFFC_SETACTUATORSON) == S_OK && transport->enabled,
        "successful ON clears explicit mute");
    Check(driver->SendForceFeedbackCommand(9, DISFFC_RESET) == S_OK, "reset after ON");
    handle = 0;
    Check(driver->DownloadEffect(9, 0x26, &handle, &f.effect, DIEP_ALLPARAMS | DIEP_START) == S_OK && transport->enabled,
        "default Start behavior restored after ON");
    Check(driver->DeviceID(0x800, 9, 0, 0, nullptr) == S_OK, "policy end");
    driver->Release();
    Check(DllCanUnloadNow() == S_OK, "policy references released");
}
}
int main() {
    try { ContractTests(); ParameterTests(); ActuatorPolicyTests(); std::printf("PASS COM checks=%u hardware_access=0\n", checks); return 0; }
    catch (const std::exception& error) { std::printf("FAIL exception=%s checks=%u\n", error.what(), checks); return 1; }
}
