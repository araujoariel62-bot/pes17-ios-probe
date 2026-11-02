// MemProbe: checks whether an iPhone can host the memory layout of the PES 2017
// recompilation runtime (pes2017-recomp/runtime/guest_memory.cpp) before any
// porting work starts:
//   1. reserve the whole 4 GB guest space in one piece,
//   2. alias one 512 MB "physical bank" at three windows (0x80000000,
//      0xA0000000, 0xC0000000), first with Mach vm_remap, then with a shared
//      file mapping (the runtime's fallback for when memfd_create is missing),
//   3. mprotect + SIGSEGV/SIGBUS write watch (runtime/gpu/memory_watch.cpp),
//   4. on request, how much memory can really be touched before iOS kills the
//      app; every step goes to disk first, so the next launch reports it.
// The report is shown on screen, can be copied, and is saved to Documents
// (visible in the Files app).

#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/vm_map.h>
#include <os/proc.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>

// The runtime's layout (runtime/guest_memory.h).
static const uint64_t kSpace        = 0x100000000ull;
static const uint64_t kCachedBase   = 0x80000000ull;
static const uint64_t kPhysicalBase = 0xA0000000ull;
static const uint64_t kApertureBase = 0xC0000000ull;
static const uint64_t kBankSize     = 0x20000000ull;   // 512 MB
static const uint64_t kFarBase      = 0x20000000ull;
static const uint64_t kFarEnd       = 0x80000000ull;   // 1.5 GB, backed on touch
static const uint64_t MB            = 1024ull * 1024ull;

static NSMutableString* g_report;

static void Line(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Line(NSString* format, ...)
{
    va_list args;
    va_start(args, format);
    NSString* text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [g_report appendFormat:@"%@\n", text];
    NSLog(@"[probe] %@", text);
}

static NSString* DocumentsPath(NSString* name)
{
    NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:name];
}

static double AvailableMB(void) { return os_proc_available_memory() / (double)MB; }

// ---- 0. Device ---------------------------------------------------------------

static NSString* Sysctl(const char* name)
{
    char value[256] = {0};
    size_t size = sizeof(value);
    if (sysctlbyname(name, value, &size, NULL, 0) != 0) return @"?";
    return [NSString stringWithUTF8String:value];
}

static void ReportDevice(void)
{
    Line(@"== 0. Aparelho");
    Line(@"modelo: %@ (%@)", Sysctl("hw.machine"), Sysctl("hw.model"));
    Line(@"iOS: %@ (build %@)", UIDevice.currentDevice.systemVersion, Sysctl("kern.osversion"));
    Line(@"RAM fisica: %.0f MB", NSProcessInfo.processInfo.physicalMemory / (double)MB);
    Line(@"pagina: %ld bytes", sysconf(_SC_PAGESIZE));
    Line(@"memoria disponivel ao app agora: %.0f MB", AvailableMB());

    // What the provisioning profile grants (the sideloading tool writes it).
    NSString* profilePath = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    NSData* profile = profilePath ? [NSData dataWithContentsOfFile:profilePath] : nil;
    if (!profile) { Line(@"perfil: nenhum embedded.mobileprovision"); return; }
    NSString* text = [[NSString alloc] initWithData:profile encoding:NSISOLatin1StringEncoding];
    for (NSString* key in @[ @"com.apple.developer.kernel.increased-memory-limit",
                             @"com.apple.developer.kernel.extended-virtual-addressing" ])
        Line(@"perfil concede %@: %@", key,
             [text containsString:key] ? @"SIM" : @"nao");
}

// ---- 1. Address space --------------------------------------------------------

static uint8_t* ReserveGuestSpace(void)
{
    void* base = mmap(NULL, kSpace, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    return base == MAP_FAILED ? NULL : (uint8_t*)base;
}

static void ReportAddressSpace(void)
{
    Line(@"");
    Line(@"== 1. Espaco de enderecos");
    uint8_t* base = ReserveGuestSpace();
    if (base) Line(@"reservar 4 GB (como o runtime): OK em %p", base);
    else      Line(@"reservar 4 GB (como o runtime): FALHOU, errno %d (%s)", errno, strerror(errno));
    if (base)
    {
        // What is left for everything else (code, renderer, textures) while
        // the guest space is held: count 64 MB blocks until mmap refuses.
        enum { kMaxBlocks = 256 };
        void* blocks[kMaxBlocks];
        int count = 0;
        while (count < kMaxBlocks)
        {
            void* block = mmap(NULL, 64 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
            if (block == MAP_FAILED) break;
            blocks[count++] = block;
        }
        Line(@"com os 4 GB reservados, espaco de enderecos livre: ~%d MB%@", count * 64,
             count == kMaxBlocks ? @" (ou mais)" : @"");
        for (int i = 0; i < count; i++) munmap(blocks[i], 64 * MB);
        munmap(base, kSpace);
    }
    void* none = mmap(NULL, kSpace, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    Line(@"reservar 4 GB sem acesso (PROT_NONE): %@", none == MAP_FAILED ? @"FALHOU" : @"OK");
    if (none != MAP_FAILED) munmap(none, kSpace);

    // The largest single reservation, for how much room is left.
    uint64_t low = 0, high = 64ull * 1024 * MB;
    while (high - low > 256 * MB)
    {
        const uint64_t mid = (low + high) / 2;
        void* p = mmap(NULL, mid, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
        if (p == MAP_FAILED) high = mid;
        else { munmap(p, mid); low = mid; }
    }
    Line(@"maior reserva unica: ~%.1f GB", low / (1024.0 * MB));
}

// ---- 2. The aliased physical bank --------------------------------------------

static bool CheckAliasing(uint8_t* base, NSString* how)
{
    const uint64_t offsets[] = { 0, 0x1234000, kBankSize - 4096 };
    bool ok = true;
    for (int i = 0; i < 3; i++)
    {
        const uint64_t offset = offsets[i];
        const uint32_t value = 0xC0FFEE00u + (uint32_t)i;
        *(volatile uint32_t*)(base + kCachedBase + offset) = value;
        const uint32_t physical = *(volatile uint32_t*)(base + kPhysicalBase + offset);
        const uint32_t aperture = *(volatile uint32_t*)(base + kApertureBase + offset);
        // And back the other way.
        *(volatile uint32_t*)(base + kApertureBase + offset + 4) = ~value;
        const uint32_t cached = *(volatile uint32_t*)(base + kCachedBase + offset + 4);
        if (physical != value || aperture != value || cached != ~value) ok = false;
    }
    Line(@"%@: as 3 janelas veem a mesma memoria: %@", how, ok ? @"SIM" : @"NAO");
    return ok;
}

// Mach: one shared anonymous region, remapped (not copied) into the other two
// windows. No file, nothing written to flash.
static bool MapBankMach(uint8_t* base, NSMutableString* error)
{
    void* bank = mmap(base + kCachedBase, kBankSize, PROT_READ | PROT_WRITE,
                      MAP_FIXED | MAP_SHARED | MAP_ANON, -1, 0);
    if (bank == MAP_FAILED) { [error appendFormat:@"mmap MAP_SHARED|MAP_ANON: %s", strerror(errno)]; return false; }
    const uint64_t windows[] = { kPhysicalBase, kApertureBase };
    for (int i = 0; i < 2; i++)
    {
        vm_address_t target = (vm_address_t)(base + windows[i]);
        vm_prot_t current = 0, maximum = 0;
        const kern_return_t kr = vm_remap(mach_task_self(), &target, (vm_size_t)kBankSize, 0,
                                          VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                                          (vm_address_t)bank, FALSE, &current, &maximum, VM_INHERIT_SHARE);
        if (kr != KERN_SUCCESS) { [error appendFormat:@"vm_remap: %s (%d)", mach_error_string(kr), kr]; return false; }
        if (target != (vm_address_t)(base + windows[i])) { [error appendString:@"vm_remap moved the window"]; return false; }
    }
    return true;
}

// File: the runtime's own fallback, an unlinked file mapped shared three times.
static bool MapBankFile(uint8_t* base, NSMutableString* error)
{
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"physical.bank"];
    const int fd = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { [error appendFormat:@"open: %s", strerror(errno)]; return false; }
    unlink(path.fileSystemRepresentation);
    bool ok = ftruncate(fd, (off_t)kBankSize) == 0;
    if (!ok) [error appendFormat:@"ftruncate: %s", strerror(errno)];
    const uint64_t windows[] = { kCachedBase, kPhysicalBase, kApertureBase };
    for (int i = 0; ok && i < 3; i++)
    {
        ok = mmap(base + windows[i], kBankSize, PROT_READ | PROT_WRITE,
                  MAP_SHARED | MAP_FIXED, fd, 0) != MAP_FAILED;
        if (!ok) [error appendFormat:@"mmap janela %llX: %s", windows[i], strerror(errno)];
    }
    close(fd);
    return ok;
}

// ---- 3. Write watch ----------------------------------------------------------

static volatile uint8_t* g_watchStart;
static volatile size_t   g_watchLength;
static volatile int      g_watchFaults;
static struct sigaction  g_previousSegv, g_previousBus;

static void OnFault(int signal, siginfo_t* info, void* context)
{
    uint8_t* address = (uint8_t*)info->si_addr;
    if (g_watchStart && address >= g_watchStart && address < g_watchStart + g_watchLength)
    {
        const long page = sysconf(_SC_PAGESIZE);
        uint8_t* pageStart = (uint8_t*)((uintptr_t)address & ~(uintptr_t)(page - 1));
        mprotect(pageStart, (size_t)page, PROT_READ | PROT_WRITE);
        g_watchFaults++;
        return;
    }
    // Not ours: hand it on, as the runtime's handler does.
    struct sigaction* previous = signal == SIGBUS ? &g_previousBus : &g_previousSegv;
    sigaction(signal, previous, NULL);
    raise(signal);
}

static void CheckWriteWatch(uint8_t* window, NSString* how)
{
    const long page = sysconf(_SC_PAGESIZE);
    struct sigaction action = {0};
    action.sa_sigaction = OnFault;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, &g_previousSegv);
    sigaction(SIGBUS, &action, &g_previousBus);

    const int pages = 8;
    g_watchFaults = 0;
    g_watchStart = window;
    g_watchLength = (size_t)(page * pages);
    const bool protectedOk = mprotect(window, (size_t)(page * pages), PROT_READ) == 0;
    if (protectedOk)
        for (int i = 0; i < pages; i++) window[i * page + 16] = (uint8_t)i;   // each write faults once
    const int faults = g_watchFaults;
    bool dataOk = true;
    for (int i = 0; i < pages; i++) if (window[i * page + 16] != (uint8_t)i) dataOk = false;

    g_watchStart = NULL;
    sigaction(SIGSEGV, &g_previousSegv, NULL);
    sigaction(SIGBUS, &g_previousBus, NULL);
    if (!protectedOk) Line(@"%@: mprotect FALHOU (%s)", how, strerror(errno));
    else Line(@"%@: vigia de escrita %d/%d faltas capturadas, dados %@", how, faults, pages, dataOk ? @"OK" : @"ERRADOS");
}

static void ReportBank(void)
{
    Line(@"");
    Line(@"== 2/3. Banco fisico de 512 MB em 3 janelas + vigia de escrita");
    for (int method = 0; method < 2; method++)
    {
        NSString* how = method == 0 ? @"Mach vm_remap" : @"arquivo compartilhado";
        uint8_t* base = ReserveGuestSpace();
        if (!base) { Line(@"%@: sem os 4 GB, nao da para testar", how); return; }
        NSMutableString* error = [NSMutableString string];
        const bool mapped = method == 0 ? MapBankMach(base, error) : MapBankFile(base, error);
        if (!mapped) Line(@"%@: FALHOU: %@", how, error);
        else
        {
            CheckAliasing(base, how);
            CheckWriteWatch(base + kCachedBase + 0x100000, how);
        }
        munmap(base, kSpace);
    }
}

// ---- 4. Load test ------------------------------------------------------------
// Touches memory in 128 MB steps until 4.5 GB or until iOS stops the app.
// Each step is written and synced to a file before it is attempted.

static NSString* LoadLogPath(void) { return DocumentsPath(@"carga.log"); }

static void AppendLoadLog(NSString* text)
{
    NSString* path = LoadLogPath();
    const int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    const char* bytes = [text stringByAppendingString:@"\n"].UTF8String;
    write(fd, bytes, strlen(bytes));
    fsync(fd);
    close(fd);
}

static void RunLoadTest(void)
{
    [NSFileManager.defaultManager removeItemAtPath:LoadLogPath() error:nil];
    AppendLoadLog(@"teste de carga iniciado");
    uint8_t* base = ReserveGuestSpace();
    NSMutableString* error = [NSMutableString string];
    if (!base || !MapBankMach(base, error)) { AppendLoadLog([NSString stringWithFormat:@"sem layout do runtime: %@", error]); return; }

    const long page = sysconf(_SC_PAGESIZE);
    const uint64_t step = 128 * MB;
    uint64_t touched = 0;
    // As the game fills it: the bank, then the far heap (both inside the 4 GB
    // guest space), then host memory outside it in 128 MB blocks, as the
    // renderer, textures and caches would take it. The outside blocks are
    // separate mappings, so running out of address space shows up as a
    // failed block, not as the whole test ending early.
    struct { uint8_t* start; uint64_t size; } regions[] = {
        { base + kCachedBase, kBankSize },
        { base + kFarBase, kFarEnd - kFarBase },
    };
    for (int r = 0; r < 2; r++)
        for (uint64_t offset = 0; offset < regions[r].size; offset += step)
        {
            AppendLoadLog([NSString stringWithFormat:@"guest: tocando %llu MB (disponivel antes: %.0f MB)",
                           (touched + step) / MB, AvailableMB()]);
            for (uint64_t p = 0; p < step; p += (uint64_t)page) regions[r].start[offset + p] = 1;
            touched += step;
        }

    enum { kMaxBlocks = 64 };
    void* blocks[kMaxBlocks];
    int blockCount = 0;
    NSString* reason = @"limite do teste (8 GB) alcancado";
    while (blockCount < kMaxBlocks)
    {
        void* block = mmap(NULL, step, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (block == MAP_FAILED)
        {
            reason = [NSString stringWithFormat:@"sem espaco de enderecos para mais um bloco (errno %d)", errno];
            break;
        }
        blocks[blockCount++] = block;
        AppendLoadLog([NSString stringWithFormat:@"host: tocando +%d MB, total %llu MB (disponivel antes: %.0f MB)",
                       blockCount * 128, (touched + step) / MB, AvailableMB()]);
        for (uint64_t p = 0; p < step; p += (uint64_t)page) ((uint8_t*)block)[p] = 1;
        touched += step;
    }
    AppendLoadLog([NSString stringWithFormat:@"FIM: %llu MB tocados (%d MB fora do guest) sem o app ser encerrado; parou por: %@",
                   touched / MB, blockCount * 128, reason]);
    for (int i = 0; i < blockCount; i++) munmap(blocks[i], step);
    munmap(base, kSpace);
}

static void ReportPreviousLoadTest(void)
{
    NSString* log = [NSString stringWithContentsOfFile:LoadLogPath() encoding:NSUTF8StringEncoding error:nil];
    Line(@"");
    Line(@"== 4. Teste de carga anterior");
    if (!log) { Line(@"(ainda nao rodou; toque em \"Teste de carga\")"); return; }
    NSArray<NSString*>* lines = [log componentsSeparatedByString:@"\n"];
    NSString* last = @"";
    NSString* beforeLast = @"";
    for (NSString* l in lines) if (l.length) { beforeLast = last; last = l; }
    if ([last hasPrefix:@"FIM"]) Line(@"ultimo passo: %@\n%@", beforeLast, last);
    else Line(@"o app foi encerrado pelo iOS durante: %@", last);
}

// ---- UI ----------------------------------------------------------------------

@interface ProbeViewController : UIViewController
@property(nonatomic, strong) UITextView* output;
@end

@implementation ProbeViewController

- (UIButton*)button:(NSString*)title action:(SEL)action
{
    UIButtonConfiguration* configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = title;
    UIButton* button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.output = [[UITextView alloc] init];
    self.output.editable = NO;
    self.output.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];

    UIStackView* buttons = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self button:@"Rodar testes" action:@selector(runTests)],
        [self button:@"Copiar" action:@selector(copyReport)],
        [self button:@"Teste de carga" action:@selector(confirmLoadTest)],
    ]];
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 8;

    UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[ buttons, self.output ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
    ]];
    [self runTests];
}

- (void)runTests
{
    g_report = [NSMutableString stringWithString:@"MemProbe 1.1 (PES 2017 recomp -> iOS)\n\n"];
    ReportDevice();
    ReportAddressSpace();
    ReportBank();
    ReportPreviousLoadTest();
    [g_report writeToFile:DocumentsPath(@"relatorio.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    self.output.text = g_report;
}

- (void)copyReport
{
    UIPasteboard.generalPasteboard.string = self.output.text;
}

- (void)confirmLoadTest
{
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:@"Teste de carga"
                         message:@"O app vai ocupar memoria ate o iOS encerra-lo. Isso e esperado. Depois, abra o app de novo para ver o resultado."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Comecar" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* a) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            RunLoadTest();
            dispatch_async(dispatch_get_main_queue(), ^{ [self runTests]; });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options
{
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController = [[ProbeViewController alloc] init];
    [self.window makeKeyAndVisible];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
@end

int main(int argc, char* argv[])
{
    @autoreleasepool
    {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
