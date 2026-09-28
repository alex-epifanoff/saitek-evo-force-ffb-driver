#include "../native/HidPidDevice.h"
#include <algorithm>
#include <cstdio>
#include <stdexcept>
#include <string>

using namespace saitek;
using namespace saitek::protocol;
namespace {
unsigned checks=0;
void Check(bool value,const char* message) { ++checks; if (!value) throw std::runtime_error(message); }
WORD ReadWord(const Report& r,size_t p) { return static_cast<WORD>(r[p]|(static_cast<WORD>(r[p+1])<<8)); }
EffectParams Constant() { EffectParams p; p.durationUs=300000; p.constantMagnitude=10000; return p; }
struct Recorder {
    std::vector<Report> reports;
    size_t failAt=static_cast<size_t>(-1);
    HRESULT failure=HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);
    Recorder() { reports.reserve(256); }
    static HRESULT Write(const Report& report,void* context) {
        auto& self=*static_cast<Recorder*>(context);
        self.reports.push_back(report);
        return self.reports.size()==self.failAt ? self.failure : S_OK;
    }
    bool HasStart(size_t begin=0) const {
        return std::any_of(reports.begin()+static_cast<std::ptrdiff_t>(begin),reports.end(),[](const Report& r){return r[0]==0x51 && (r[2]==2||r[2]==3);});
    }
};
void AllocatorTests() {
    PoolAllocator pool;
    Block a,b,c;
    Check(pool.Allocate(1,a)&&a.offset==2&&a.bytes==2,"constant block alignment and offset-zero policy");
    Check(pool.Allocate(12,b)&&b.offset==4,"second block follows first");
    Check(pool.Allocate(8,c)&&c.offset==16,"third block follows second");
    Check(!pool.Free({a.offset,4}),"wrong-size free rejected");
    Check(pool.Free(b),"free middle block");
    Block replacement;
    Check(pool.Allocate(10,replacement)&&replacement.offset==4,"first-fit recovers middle gap");
    Check(!pool.Free(b),"double free rejected");
    Check(pool.Used()==20,"allocation accounting");
    pool.Clear();
    Check(pool.Allocate(298,a)&&a.offset==2,"usable pool fits exactly");
    Check(!pool.Allocate(1,b)&&pool.Used()==298,"exhaustion preserves allocations");
    Check(!pool.Allocate(0,b)&&!pool.Allocate(65535,b),"zero and overflow allocation rejected");
    pool.Clear();
    Check(pool.Allocate(286,a),"occupy all but 12 bytes");
    EffectParams p=Constant();
    EffectStorage s;
    Check(AllocateEffect(pool,1,p,s)==DIERR_DEVICEFULL&&pool.Used()==286&&s.slot==0,"implicit envelope exhaustion rolls back first allocation");
    p.hasEnvelope=true;
    Check(AllocateEffect(pool,1,p,s)==DIERR_DEVICEFULL&&pool.Used()==286&&s.slot==0,"explicit envelope exhaustion rolls back first allocation");
}
void EncoderTests() {
    PoolAllocator pool; EffectStorage storage; std::vector<Report> reports;
    auto p=Constant(); p.gain=5000;
    Check(SUCCEEDED(AllocateEffect(pool,1,p,storage)),"constant allocation");
    Check(SUCCEEDED(EncodeEffect(p,storage,5000,reports))&&reports.size()==3,"constant produces magnitude, neutral envelope, and SetEffect only");
    Check(reports[0][0]==0x0d&&ReadWord(reports[0],1)==2&&reports[0][3]==32,"combined gain applied once with rounding");
    const Report expected={0x0b,1,1,0xe0,0x2c,1,0,0,0,2,0,4,0,0,0};
    Check(reports.back()==expected,"SetEffect exact wire bytes incl duration and valid envelope offset");
    p.constantMagnitude=-10000; p.gain=10000;
    Check(SUCCEEDED(EncodeEffect(p,storage,10000,reports))&&reports[0][3]==129,"negative constant signed 8-bit minimum");
    p.durationUs=1;
    Check(SUCCEEDED(EncodeEffect(p,storage,10000,reports))&&ReadWord(reports.back(),4)==1,"nonzero microsecond duration rounds up instead of zero");
    p.durationUs=INFINITE;
    Check(SUCCEEDED(EncodeEffect(p,storage,10000,reports))&&ReadWord(reports.back(),4)==0xffff,"only explicit infinity becomes FFFF");
    p.durationUs=65534001;
    Check(FAILED(EncodeEffect(p,storage,10000,reports))&&reports.empty(),"unrepresentable finite duration rejected");
    p=Constant(); p.triggerButton=1; Check(FAILED(Validate(p)),"button-trigger replay rejected until lifecycle supported");
    p=Constant(); p.hasEnvelope=true; p.envelope.dwAttackTime=1001000; p.envelope.dwAttackLevel=5000; p.envelope.dwFadeTime=2000000; p.envelope.dwFadeLevel=10000;
    pool.Clear(); Check(SUCCEEDED(AllocateEffect(pool,2,p,storage)),"envelope allocation");
    Check(SUCCEEDED(EncodeEffect(p,storage,10000,reports))&&reports.size()==3,"envelope reports");
    Check(reports[1][0]==0x0c&&ReadWord(reports[1],1)==4&&ReadWord(reports[1],3)==1001&&reports[1][5]==64&&ReadWord(reports[1],6)==2000&&reports[1][8]==127,"envelope scaling/timing");
    Check(ReadWord(reports.back(),11)==4,"envelope address in second ordinal slot");
    p=Constant(); p.kind=EffectKind::Sine; p.periodic={10000,-5000,18000,1000000};
    pool.Clear(); Check(SUCCEEDED(AllocateEffect(pool,3,p,storage)),"periodic allocation");
    Check(SUCCEEDED(EncodeEffect(p,storage,10000,reports)),"periodic encode");
    Check(reports[0][0]==0x0e&&reports[0][3]==127&&reports[0][4]==192&&reports[0][5]==128&&ReadWord(reports[0],6)==1000&&reports.back()[2]==4,"periodic signed offset/phase/period/type");
    p=Constant(); p.kind=EffectKind::Spring;
    p.condition[0]={-10000,10000,-10000,10000,5000,10000};
    p.condition[1]={10000,-5000,5000,2500,7500,5000};
    pool.Clear(); Check(SUCCEEDED(AllocateEffect(pool,4,p,storage))&&storage.primary.offset==2&&storage.secondary.offset==10,"two-axis condition allocations distinct");
    Check(SUCCEEDED(EncodeEffect(p,storage,10000,reports))&&reports.size()==3,"two-axis spring reports");
    Check(reports[0][3]==100&&reports[0][4]==156&&ReadWord(reports[0],5)==65036&&ReadWord(reports[0],7)==1000&&reports[0][9]==100&&reports[0][10]==50,"condition coefficient offset deadband saturation");
    Check(reports[1][3]==206&&reports[1][4]==50&&ReadWord(reports[1],5)==500&&reports[2][3]==0xc0&&ReadWord(reports[2],11)==10,"Y condition independence; condition direction disabled");
    p.axesMask=2; pool.Clear();
    Check(SUCCEEDED(AllocateEffect(pool,5,p,storage))&&storage.primary.offset==0&&storage.secondary.offset==2,"Y-only condition uses second ordinal offset");
    Check(SUCCEEDED(EncodeEffect(p,storage,10000,reports))&&ReadWord(reports.back(),9)==0&&ReadWord(reports.back(),11)==2,"Y-only wire offsets");
    p=Constant(); auto next=p; next.constantMagnitude=1234; next.directionHundredths=9000;
    Check(CanUpdateInPlace(p,next),"force/direction can update without restart");
    next.durationUs++; Check(!CanUpdateInPlace(p,next),"timing change requires explicit restart");
    Report operation;
    Check(SUCCEEDED(EncodeOperation(9,true,INFINITE,operation))&&operation[2]==2&&operation[3]==255,"infinite iteration sentinel");
    Check(FAILED(EncodeOperation(0,true,1,operation))&&FAILED(EncodeOperation(1,true,255,operation)),"invalid slot and finite repeat overflow rejected");
}
void NeutralEnvelopeTests() {
    for (const EffectKind kind : {EffectKind::Constant,EffectKind::Square,EffectKind::Sine,EffectKind::Triangle,EffectKind::SawtoothUp,EffectKind::SawtoothDown}) {
        PoolAllocator pool; EffectStorage storage; std::vector<Report> reports;
        auto p=Constant(); p.kind=kind; p.periodic={10000,0,0,100000};
        // Unused DTO fields must not accidentally become an application envelope.
        p.envelope={sizeof(DIENVELOPE),10000,1000000,10000,2000000};
        const WORD primaryBytes=kind==EffectKind::Constant ? 2 : 12;
        Check(SUCCEEDED(AllocateEffect(pool,1,p,storage))&&storage.envelope.offset==2+primaryBytes&&storage.envelope.bytes==12&&pool.Used()==static_cast<DWORD>(primaryBytes)+12,"every directed type owns a distinct neutral envelope");
        Check(SUCCEEDED(EncodeEffect(p,storage,2500,reports))&&reports.size()==3&&!p.hasEnvelope,"implicit envelope preserves logical API state");
        Report neutral{}; neutral[0]=0x0c; neutral[1]=static_cast<BYTE>(storage.envelope.offset);
        Check(reports[1]==neutral&&ReadWord(reports.back(),11)==storage.envelope.offset,"neutral envelope exact zero fields and nonzero SetEffect reference");
        Check(reports[0][3]==32&&std::none_of(reports.begin(),reports.end(),[](const Report& r){return r[0]==0x51;}),"neutral envelope preserves effective gain without Start");
        const auto originalStorage=storage;
        storage.envelope={};
        Check(FAILED(EncodeEffect(p,storage,10000,reports))&&reports.empty(),"missing physical envelope is rejected before output");
        FreeEffect(pool,originalStorage);
        Check(pool.Used()==0&&SUCCEEDED(AllocateEffect(pool,1,p,storage))&&storage.primary.offset==originalStorage.primary.offset&&storage.envelope.offset==originalStorage.envelope.offset,"both parameter blocks freed and reused together");
        auto next=p; next.hasEnvelope=true; next.envelope={};
        Check(!CanUpdateInPlace(p,next),"logical envelope presence retains existing restart semantics");
    }
    PoolAllocator pool; EffectStorage storage; std::vector<Report> reports;
    auto p=Constant(); p.kind=EffectKind::Damper;
    Check(SUCCEEDED(AllocateEffect(pool,1,p,storage))&&storage.envelope.bytes==0&&pool.Used()==16,"condition layout remains two condition blocks without envelope");
    Check(SUCCEEDED(EncodeEffect(p,storage,10000,reports))&&reports.size()==3&&reports[0][0]==0x0f&&reports[1][0]==0x0f,"condition wire reports remain unchanged");
}
void LifecycleTests() {
    Recorder recorder; HidPidDevice device;
    Check(SUCCEEDED(device.OpenForTesting(Recorder::Write,&recorder)),"mock open");
    Check(recorder.reports.size()==3&&recorder.reports[0][1]==1&&recorder.reports[1][1]==4&&recorder.reports[2][0]==0x43&&recorder.reports[2][1]==128,"open reset/off/nominal hardware gain");
    auto p=Constant(); p.durationUs=INFINITE;
    Check(SUCCEEDED(device.Download(42,p))&&!recorder.HasStart(),"Download does not start");
    DeviceState state; Check(SUCCEEDED(device.GetState(state))&&state.effectCount==1&&!state.anyPlaying&&state.memoryLoad==14*100/298,"download status accounts for magnitude and neutral envelope");
    const size_t mutedBegin=recorder.reports.size();
    Check(SUCCEEDED(device.Start(42,1))&&recorder.reports.size()==mutedBegin+1&&recorder.reports.back()[0]==0x51,"disabled actuators permit muted Start without implicit enable");
    Check(SUCCEEDED(device.GetState(state))&&state.anyPlaying&&!state.actuatorsEnabled,"muted playback does not claim actuators enabled");
    Check(SUCCEEDED(device.SetActuators(true))&&SUCCEEDED(device.Start(42,1)),"explicit enable/start");
    size_t before=recorder.reports.size(); p.constantMagnitude=-5000;
    Check(SUCCEEDED(device.Download(42,p))&&!recorder.HasStart(before),"running magnitude update preserves playback without Start");
    bool playing=false; Check(SUCCEEDED(device.IsPlaying(42,playing))&&playing,"running update state");
    auto timing=p; timing.durationUs=100000;
    before=recorder.reports.size();
    Check(device.Download(42,timing)==DIERR_EFFECTPLAYING&&recorder.reports.size()==before,"incompatible live update has no I/O");
    before=recorder.reports.size();
    Check(SUCCEEDED(device.SetGain(5000))&&recorder.reports.size()==before+2&&recorder.reports[before][0]==0x0d&&recorder.reports.back()[0]==0x0c&&!recorder.HasStart(before),"live gain updates magnitude and neutral envelope only");
    Check(ReadWord(recorder.reports.back(),1)==4&&std::all_of(recorder.reports.back().begin()+3,recorder.reports.back().end(),[](BYTE b){return b==0;}),"live gain keeps neutral envelope neutral at its original address");
    Check(SUCCEEDED(device.StopAll())&&SUCCEEDED(device.IsPlaying(42,playing))&&!playing,"stop-all preserves downloaded state");
    Check(SUCCEEDED(device.Destroy(42))&&device.IsPlaying(42,playing)==DIERR_NOTDOWNLOADED,"destroy invalidates handle");
    Check(SUCCEEDED(device.Download(43,p))&&ReadWord(recorder.reports[recorder.reports.size()-3],1)==2&&ReadWord(recorder.reports[recorder.reports.size()-2],1)==4,"magnitude and envelope memory reused only after stop/destroy");
    device.Close();
    Check(recorder.reports[recorder.reports.size()-2][1]==2&&recorder.reports.back()[1]==4,"close stop-all then off");
    Check(device.GetState(state)==DIERR_NOTINITIALIZED,"close invalidates state");
    for (const HRESULT fault : {HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED),HRESULT_FROM_WIN32(ERROR_TIMEOUT),HRESULT_FROM_WIN32(ERROR_WRITE_FAULT)}) {
        Check(SUCCEEDED(device.OpenForTesting(Recorder::Write,&recorder)),"reopen clean session");
        recorder.failure=fault; recorder.failAt=recorder.reports.size()+2;
        Check(device.Download(90,p)==fault,"partial download failure propagated");
        Check(recorder.reports[recorder.reports.size()-2][1]==2&&recorder.reports.back()[1]==4,"partial failure attempts stop/off");
        Check(device.Start(90,1)==DIERR_NOTINITIALIZED&&device.Download(91,p)==DIERR_NOTINITIALIZED,"fault poisons session, no memory reuse or replay");
        recorder.failAt=static_cast<size_t>(-1);
    }
    Check(SUCCEEDED(device.OpenForTesting(Recorder::Write,&recorder)),"open capacity test");
    for (DWORD id=1;id<=9;++id) Check(SUCCEEDED(device.Download(id,p)),"each of nine local slots downloads");
    before=recorder.reports.size();
    Check(device.Download(10,p)==DIERR_DEVICEFULL&&recorder.reports.size()==before,"tenth slot rejected before I/O");
    Check(SUCCEEDED(device.Destroy(4))&&SUCCEEDED(device.Download(10,p))&&recorder.reports.back()[1]==4,"freed physical slot reused");
    Check(SUCCEEDED(device.SetActuators(true)),"enable before reset state test");
    before=recorder.reports.size();
    Check(SUCCEEDED(device.Reset())&&SUCCEEDED(device.GetState(state))&&state.effectCount==0&&!state.actuatorsEnabled&&!state.paused,"reset clears allocations and disables tracked actuators");
    Check(recorder.reports.size()==before+3&&recorder.reports[before][0]==0x52&&recorder.reports[before][1]==1&&recorder.reports[before+1][0]==0x52&&recorder.reports[before+1][1]==4&&recorder.reports[before+2][0]==0x43,"reset wire order reset then off then nominal gain");
    p.durationUs=120000;
    Check(SUCCEEDED(device.Download(100,p)),"download finite effect after reset");
    before=recorder.reports.size();
    Check(SUCCEEDED(device.Start(100,1))&&recorder.reports.size()==before+1&&recorder.reports.back()[0]==0x51,"post-reset muted Start sends no enable command");
    Sleep(180);
    bool mutedPlaying=true;
    Check(SUCCEEDED(device.IsPlaying(100,mutedPlaying))&&!mutedPlaying&&SUCCEEDED(device.GetState(state))&&!state.actuatorsEnabled,"muted finite effect timer expires while remaining disabled");
    Check(SUCCEEDED(device.Download(100,p))&&SUCCEEDED(device.SetActuators(true))&&SUCCEEDED(device.Start(100,1))&&SUCCEEDED(device.Pause(true)),"start finite effect then pause");
    Sleep(180);
    Check(SUCCEEDED(device.IsPlaying(100,playing))&&playing,"pause freezes finite playback timer");
    Check(SUCCEEDED(device.Pause(false)),"continue finite effect"); Sleep(180);
    Check(SUCCEEDED(device.IsPlaying(100,playing))&&!playing,"continued finite effect expires");
    Check(SUCCEEDED(device.Start(100,1))&&SUCCEEDED(device.SetActuators(false)),"actuators off during finite playback"); Sleep(180);
    Check(SUCCEEDED(device.IsPlaying(100,playing))&&!playing,"actuators off does not freeze timer");
    Check(SUCCEEDED(device.SetActuators(true))&&SUCCEEDED(device.Start(100,1)),"restart finite effect"); Sleep(180);
    Check(SUCCEEDED(device.Pause(true))&&SUCCEEDED(device.IsPlaying(100,playing))&&!playing,"pause refreshes an already expired unpolled effect");
}
void CancellationTest() {
    // Isolated named pipe, never a HID/device path. Fill its write quota and
    // exercise the same overlapped timeout/cancellation lifetime as HID output.
    const std::wstring name=L"\\\\.\\pipe\\SaitekFfbTest-"+std::to_wstring(GetCurrentProcessId());
    HANDLE server=CreateNamedPipeW(name.c_str(),PIPE_ACCESS_OUTBOUND|FILE_FLAG_OVERLAPPED,PIPE_TYPE_BYTE|PIPE_WAIT,1,1,1,0,nullptr);
    Check(server!=INVALID_HANDLE_VALUE,"create isolated pipe");
    HANDLE client=CreateFileW(name.c_str(),GENERIC_READ,0,nullptr,OPEN_EXISTING,0,nullptr);
    Check(client!=INVALID_HANDLE_VALUE,"connect isolated pipe");
    // A waiting reader permits the small write to complete immediately. The
    // transport must still obtain its completed length from OVERLAPPED state.
    std::array<BYTE,ReportBytes> received{};
    struct Reader { HANDLE handle; BYTE* data; DWORD read=0; BOOL ok=FALSE; } reader{client,received.data()};
    HANDLE readerThread=CreateThread(nullptr,0,[](void* p)->DWORD {
        auto* r=static_cast<Reader*>(p);
        r->ok=ReadFile(r->handle,r->data,static_cast<DWORD>(ReportBytes),&r->read,nullptr);
        return 0;
    },&reader,0,nullptr);
    Check(readerThread!=nullptr,"create private pipe reader");
    Report successful{}; successful[0]=0x0b;successful[14]=0xa5;
    Check(SUCCEEDED(HidPidDevice::WriteForTesting(server,successful)),"completed overlapped write reports exact byte count");
    Check(WaitForSingleObject(readerThread,2000)==WAIT_OBJECT_0&&reader.ok&&reader.read==ReportBytes&&received==successful,"successful private pipe payload verified");
    CloseHandle(readerThread);
    OVERLAPPED filling{}; filling.hEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    std::array<BYTE,65536> filler{}; DWORD written=0;
    const BOOL completed=WriteFile(server,filler.data(),static_cast<DWORD>(filler.size()),&written,&filling);
    Check(!completed&&GetLastError()==ERROR_IO_PENDING,"pipe writer pending without reader");
    const ULONGLONG started=GetTickCount64();
    const HRESULT result=HidPidDevice::WriteForTesting(server,Report{});
    Check(result==HRESULT_FROM_WIN32(ERROR_TIMEOUT)&&GetTickCount64()-started<4000,"bounded pending write cancelled");
    CancelIoEx(server,&filling);
    Check(WaitForSingleObject(filling.hEvent,2000)==WAIT_OBJECT_0,"test filler cancellation completed before stack release");
    CloseHandle(filling.hEvent); CloseHandle(client); CloseHandle(server);
}
}
int main() {
    try { AllocatorTests(); EncoderTests(); NeutralEnvelopeTests(); LifecycleTests(); CancellationTest(); std::printf("PASS %u protocol/lifecycle checks; no hardware opened.\n",checks); return 0; }
    catch (const std::exception& e) { std::fprintf(stderr,"FAIL: %s (after %u checks)\n",e.what(),checks); return 1; }
}
