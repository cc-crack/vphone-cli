/*
 * vphoned — VM guest agent for vphone-cli.
 *
 * Runs inside the iOS VM as a LaunchDaemon. Communicates with the host
 * over vsock using length-prefixed JSON (vphone-control protocol).
 *
 * Auto-update: on each handshake the host sends its binary hash. If it
 * differs from our own, the host pushes a signed replacement. We write
 * it to CACHE_PATH and exit — launchd restarts us, and the bootstrap
 * code in main() exec's the cached binary.
 *
 * Build:
 *   make vphoned
 */

#include <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <net/if.h>
#include <netinet/in.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <spawn.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

#import "vphoned_accessibility.h"
#import "vphoned_apps.h"
#import "vphoned_clipboard.h"
#import "vphoned_devmode.h"
#import "vphoned_files.h"
#import "vphoned_hid.h"
#import "vphoned_install.h"
#import "vphoned_keychain.h"
#import "vphoned_location.h"
#import "vphoned_notify.h"
#import "vphoned_protocol.h"
#import "vphoned_settings.h"
#import "vphoned_url.h"
#import "vphoned_vcam.h"

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif

#define VMADDR_CID_ANY 0xFFFFFFFF
#define VPHONED_PORT 1337

#ifndef VPHONED_BUILD_HASH
#define VPHONED_BUILD_HASH "unknown"
#endif

static BOOL gClipboardAvailable = NO;
static BOOL gAppsAvailable = NO;
static BOOL gHIDAvailable = NO;

extern CFIndex _CFPreferencesGetAppIntegerValueWithContainer(
    CFStringRef key, CFStringRef applicationID, CFStringRef userName,
    CFStringRef hostName, CFStringRef container, Boolean *keyExists)
    __attribute__((weak_import));

static CFIndex vp_stub_CFPreferencesGetAppIntegerValueWithContainer(
    CFStringRef key, CFStringRef applicationID, CFStringRef userName,
    CFStringRef hostName, CFStringRef container, Boolean *keyExists) {
  if (getenv("VPHONED_STUB_METAL_PREFS")) {
    char keyBuf[256] = {0};
    char appBuf[256] = {0};
    if (key)
      CFStringGetCString(key, keyBuf, sizeof(keyBuf), kCFStringEncodingUTF8);
    if (applicationID)
      CFStringGetCString(applicationID, appBuf, sizeof(appBuf),
                         kCFStringEncodingUTF8);
    if (keyExists)
      *keyExists = 0;
    dprintf(STDOUT_FILENO,
            "{\"kind\":\"pref_stub\",\"function\":\"_CFPreferencesGetAppIntegerValueWithContainer\","
            "\"key\":\"%s\",\"app\":\"%s\"}\n",
            keyBuf, appBuf);
    return 0;
  }

  typedef CFIndex (*OrigFn)(CFStringRef, CFStringRef, CFStringRef, CFStringRef,
                            CFStringRef, Boolean *);
  static OrigFn orig = NULL;
  if (!orig)
    orig = (OrigFn)dlsym(RTLD_NEXT,
                         "_CFPreferencesGetAppIntegerValueWithContainer");
  return orig ? orig(key, applicationID, userName, hostName, container, keyExists)
              : 0;
}

static Boolean vp_stub_CFPreferencesGetAppBooleanValueWithContainer(
    CFStringRef key, CFStringRef applicationID, CFStringRef userName,
    CFStringRef hostName, CFStringRef container, Boolean *keyExists) {
  (void)key;
  (void)applicationID;
  (void)userName;
  (void)hostName;
  (void)container;
  if (keyExists)
    *keyExists = 0;
  dprintf(STDOUT_FILENO,
          "{\"kind\":\"pref_stub\",\"function\":\"_CFPreferencesGetAppBooleanValueWithContainer\"}\n");
  return false;
}

static CFPropertyListRef vp_stub_CFPreferencesCopyAppValueWithContainerAndConfiguration(
    CFStringRef key, CFStringRef applicationID, CFStringRef userName,
    CFStringRef hostName, CFStringRef container, CFStringRef configuration) {
  (void)key;
  (void)applicationID;
  (void)userName;
  (void)hostName;
  (void)container;
  (void)configuration;
  dprintf(STDOUT_FILENO,
          "{\"kind\":\"pref_stub\",\"function\":\"_CFPreferencesCopyAppValueWithContainerAndConfiguration\"}\n");
  return NULL;
}

static CFIndex vp_stub_CFPreferencesGetAppIntegerValue(
    CFStringRef key, CFStringRef applicationID, Boolean *keyExists) {
  (void)key;
  (void)applicationID;
  if (keyExists)
    *keyExists = 0;
  dprintf(STDOUT_FILENO,
          "{\"kind\":\"pref_stub\",\"function\":\"CFPreferencesGetAppIntegerValue\"}\n");
  return 0;
}

static Boolean vp_stub_CFPreferencesGetAppBooleanValue(
    CFStringRef key, CFStringRef applicationID, Boolean *keyExists) {
  (void)key;
  (void)applicationID;
  if (keyExists)
    *keyExists = 0;
  dprintf(STDOUT_FILENO,
          "{\"kind\":\"pref_stub\",\"function\":\"CFPreferencesGetAppBooleanValue\"}\n");
  return false;
}

static CFPropertyListRef vp_stub_CFPreferencesCopyAppValue(
    CFStringRef key, CFStringRef applicationID) {
  (void)key;
  (void)applicationID;
  dprintf(STDOUT_FILENO,
          "{\"kind\":\"pref_stub\",\"function\":\"CFPreferencesCopyAppValue\"}\n");
  return NULL;
}

__attribute__((used)) static struct {
  const void *replacement;
  const void *replacee;
} vp_interpose_cfpreferences[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)vp_stub_CFPreferencesGetAppIntegerValueWithContainer,
     (const void *)_CFPreferencesGetAppIntegerValueWithContainer},
};

#define INSTALL_PATH "/usr/bin/vphoned"
#define CACHE_PATH "/var/root/Library/Caches/vphoned"
#define CACHE_DIR "/var/root/Library/Caches"

extern char **environ;
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp,
                                       const char *service_name,
                                       mach_port_t *sp);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

typedef struct {
  const char *name;
  void *replacement;
} VPRebindSymbol;

struct VPDyldInterposeTuple {
  const void *replacement;
  const void *replacee;
};

typedef void (*VPDyldDynamicInterposeFn)(
    const struct mach_header *mh, const struct VPDyldInterposeTuple array[],
    size_t count);

static void *vp_replacement_for_symbol(const char *name) {
  static const VPRebindSymbol symbols[] = {
      {"_CFPreferencesGetAppIntegerValueWithContainer",
       (void *)vp_stub_CFPreferencesGetAppIntegerValueWithContainer},
      {"_CFPreferencesGetAppBooleanValueWithContainer",
       (void *)vp_stub_CFPreferencesGetAppBooleanValueWithContainer},
      {"_CFPreferencesCopyAppValueWithContainerAndConfiguration",
       (void *)vp_stub_CFPreferencesCopyAppValueWithContainerAndConfiguration},
      {"_CFPreferencesGetAppIntegerValue",
       (void *)vp_stub_CFPreferencesGetAppIntegerValue},
      {"_CFPreferencesGetAppBooleanValue",
       (void *)vp_stub_CFPreferencesGetAppBooleanValue},
      {"_CFPreferencesCopyAppValue",
       (void *)vp_stub_CFPreferencesCopyAppValue},
  };
  for (size_t i = 0; i < sizeof(symbols) / sizeof(symbols[0]); i++) {
    if (strcmp(name, symbols[i].name) == 0)
      return symbols[i].replacement;
  }
  return NULL;
}

static void vp_rebind_indirect_section(const struct mach_header_64 *mh,
                                       intptr_t slide,
                                       const struct symtab_command *symtabCmd,
                                       const struct dysymtab_command *dysymtabCmd,
                                       const struct segment_command_64 *linkedit,
                                       const struct section_64 *section,
                                       NSMutableArray *events) {
  if (!symtabCmd || !dysymtabCmd || !linkedit || !section)
    return;

  uint8_t *linkeditBase =
      (uint8_t *)(uintptr_t)(slide + linkedit->vmaddr - linkedit->fileoff);
  struct nlist_64 *symtab =
      (struct nlist_64 *)(void *)(linkeditBase + symtabCmd->symoff);
  char *strtab = (char *)(void *)(linkeditBase + symtabCmd->stroff);
  uint32_t *indirect =
      (uint32_t *)(void *)(linkeditBase + dysymtabCmd->indirectsymoff);
  void **pointers = (void **)(uintptr_t)(slide + section->addr);
  uint64_t count = section->size / sizeof(void *);
  NSUInteger matches = 0;
  kern_return_t lastProtectKr = KERN_SUCCESS;

  for (uint64_t i = 0; i < count; i++) {
    uint32_t symbolIndex = indirect[section->reserved1 + i];
    if (symbolIndex == INDIRECT_SYMBOL_ABS ||
        symbolIndex == INDIRECT_SYMBOL_LOCAL ||
        symbolIndex == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS) ||
        symbolIndex >= symtabCmd->nsyms) {
      continue;
    }

    uint32_t strx = symtab[symbolIndex].n_un.n_strx;
    if (strx >= symtabCmd->strsize)
      continue;

    const char *name = strtab + strx;
    void *replacement = vp_replacement_for_symbol(name);
    if (!replacement)
      continue;

    vm_address_t slot = (vm_address_t)(uintptr_t)&pointers[i];
    vm_address_t page = slot & ~(vm_page_size - 1);
    kern_return_t protectKr =
        vm_protect(mach_task_self(), page, vm_page_size, false,
                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    lastProtectKr = protectKr;
    if (protectKr == KERN_SUCCESS) {
      pointers[i] = replacement;
      matches++;
    }

    [events addObject:@{
      @"kind" : @"pref_rebind_symbol",
      @"section" : [NSString stringWithUTF8String:section->sectname] ?: @"",
      @"symbol" : [NSString stringWithUTF8String:name] ?: @"",
      @"slot" : [NSString stringWithFormat:@"0x%llx",
                                           (unsigned long long)slot],
      @"protect_kr" : @(protectKr),
      @"installed" : @(protectKr == KERN_SUCCESS),
    }];
  }

  if (matches > 0 || lastProtectKr != KERN_SUCCESS) {
    [events addObject:@{
      @"kind" : @"pref_rebind_section",
      @"section" : [NSString stringWithUTF8String:section->sectname] ?: @"",
      @"matches" : @(matches),
      @"last_protect_kr" : @(lastProtectKr),
    }];
  }

  (void)mh;
}

static NSArray *vp_rebind_metal_preference_imports(NSString *metalPath) {
  NSMutableArray *events = [NSMutableArray array];
  const struct mach_header_64 *targetHeader = NULL;
  intptr_t targetSlide = 0;
  NSString *targetName = nil;

  uint32_t imageCount = _dyld_image_count();
  for (uint32_t i = 0; i < imageCount; i++) {
    const char *name = _dyld_get_image_name(i);
    if (!name)
      continue;
    NSString *imageName = [NSString stringWithUTF8String:name] ?: @"";
    if ([imageName isEqualToString:metalPath] ||
        [imageName hasSuffix:@"/System/Library/Frameworks/Metal.framework/Metal"] ||
        [imageName rangeOfString:@"Metal.framework/Metal"].location != NSNotFound) {
      targetHeader = (const struct mach_header_64 *)_dyld_get_image_header(i);
      targetSlide = _dyld_get_image_vmaddr_slide(i);
      targetName = imageName;
      break;
    }
  }

  if (!targetHeader || targetHeader->magic != MH_MAGIC_64) {
    [events addObject:@{ @"kind" : @"pref_rebind",
                         @"found_image" : @NO }];
    return events;
  }

  VPDyldDynamicInterposeFn dynamicInterpose =
      (VPDyldDynamicInterposeFn)dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose");
  if (!dynamicInterpose)
    dynamicInterpose =
        (VPDyldDynamicInterposeFn)dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose");
  if (dynamicInterpose) {
    struct VPDyldInterposeTuple tuples[6];
    size_t tupleCount = 0;
    const char *names[] = {
        "_CFPreferencesGetAppIntegerValueWithContainer",
        "_CFPreferencesGetAppBooleanValueWithContainer",
        "_CFPreferencesCopyAppValueWithContainerAndConfiguration",
        "CFPreferencesGetAppIntegerValue",
        "CFPreferencesGetAppBooleanValue",
        "CFPreferencesCopyAppValue",
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
      void *replacee = dlsym(RTLD_DEFAULT, names[i]);
      void *replacement = vp_replacement_for_symbol(names[i]);
      if (replacee && replacement && tupleCount < sizeof(tuples) / sizeof(tuples[0])) {
        tuples[tupleCount++] =
            (struct VPDyldInterposeTuple){replacement, replacee};
        [events addObject:@{
          @"kind" : @"pref_dynamic_interpose_symbol",
          @"symbol" : [NSString stringWithUTF8String:names[i]] ?: @"",
          @"replacee" : [NSString stringWithFormat:@"0x%llx",
                                                   (unsigned long long)(uintptr_t)replacee],
          @"replacement" : [NSString stringWithFormat:@"0x%llx",
                                                      (unsigned long long)(uintptr_t)replacement],
        }];
      }
    }
    if (tupleCount > 0)
      dynamicInterpose((const struct mach_header *)targetHeader, tuples,
                       tupleCount);
    [events addObject:@{
      @"kind" : @"pref_dynamic_interpose",
      @"available" : @YES,
      @"tuple_count" : @(tupleCount),
    }];
  } else {
    [events addObject:@{ @"kind" : @"pref_dynamic_interpose",
                         @"available" : @NO }];
  }

  const struct symtab_command *symtabCmd = NULL;
  const struct dysymtab_command *dysymtabCmd = NULL;
  const struct segment_command_64 *linkedit = NULL;
  NSMutableArray<NSValue *> *sections = [NSMutableArray array];

  const uint8_t *cursor =
      (const uint8_t *)targetHeader + sizeof(struct mach_header_64);
  for (uint32_t i = 0; i < targetHeader->ncmds; i++) {
    const struct load_command *lc = (const struct load_command *)cursor;
    if (lc->cmd == LC_SYMTAB)
      symtabCmd = (const struct symtab_command *)lc;
    else if (lc->cmd == LC_DYSYMTAB)
      dysymtabCmd = (const struct dysymtab_command *)lc;
    else if (lc->cmd == LC_SEGMENT_64) {
      const struct segment_command_64 *seg =
          (const struct segment_command_64 *)lc;
      if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
        linkedit = seg;
      } else {
        const struct section_64 *sect =
            (const struct section_64 *)(void *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++) {
          uint32_t type = sect[j].flags & SECTION_TYPE;
          if (type == S_LAZY_SYMBOL_POINTERS ||
              type == S_NON_LAZY_SYMBOL_POINTERS) {
            [sections addObject:[NSValue valueWithPointer:&sect[j]]];
          }
        }
      }
    }
    cursor += lc->cmdsize;
  }

  [events addObject:@{
    @"kind" : @"pref_rebind_image",
    @"found_image" : @YES,
    @"image" : targetName ?: @"",
    @"has_symtab" : @(symtabCmd != NULL),
    @"has_dysymtab" : @(dysymtabCmd != NULL),
    @"has_linkedit" : @(linkedit != NULL),
    @"section_count" : @(sections.count),
  }];

  for (NSValue *value in sections) {
    const struct section_64 *section =
        (const struct section_64 *)value.pointerValue;
    vp_rebind_indirect_section(targetHeader, targetSlide, symtabCmd,
                               dysymtabCmd, linkedit, section, events);
  }
  return events;
}

struct sockaddr_vm {
  __uint8_t svm_len;
  sa_family_t svm_family;
  __uint16_t svm_reserved1;
  __uint32_t svm_port;
  __uint32_t svm_cid;
};

static void start_optional_services(void) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      NSLog(@"vphoned: initializing optional services");

      NSLog(@"vphoned: loading HID support");
      gHIDAvailable = vp_hid_load();
      if (!gHIDAvailable)
        NSLog(@"vphoned: HID unavailable, continuing without input injection");

      NSLog(@"vphoned: loading devmode support");
      if (!vp_devmode_load())
        NSLog(@"vphoned: XPC unavailable, devmode disabled");

      NSLog(@"vphoned: loading location support");
      vp_location_load();

      NSLog(@"vphoned: loading clipboard support");
      gClipboardAvailable = vp_clipboard_load();

      NSLog(@"vphoned: loading apps support");
      gAppsAvailable = vp_apps_load();

      NSLog(@"vphoned: loading virtual camera support");
      vp_vcam_start();

      NSLog(@"vphoned: optional services initialized");
    }
  });
}

// MARK: - Self-hash

static NSString *sha256_of_file(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0)
    return nil;

  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);

  uint8_t buf[32768];
  ssize_t n;
  while ((n = read(fd, buf, sizeof(buf))) > 0)
    CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
  close(fd);

  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &ctx);

  NSMutableString *hex =
      [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
    [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

static const char *self_executable_path(void) {
  static char path[4096];
  uint32_t size = sizeof(path);
  if (_NSGetExecutablePath(path, &size) != 0)
    return NULL;
  return path;
}

// MARK: - Network

/// Returns the first non-loopback IPv4 address, preferring en* interfaces
/// (Wi-Fi/cellular over virtual). Returns nil if no usable address is found.
static NSString *primary_ipv4_address(void) {
  struct ifaddrs *ifap = NULL;
  if (getifaddrs(&ifap) != 0 || ifap == NULL)
    return nil;

  NSString *preferred = nil;
  NSString *fallback = nil;

  for (struct ifaddrs *cur = ifap; cur != NULL; cur = cur->ifa_next) {
    if (cur->ifa_addr == NULL || cur->ifa_addr->sa_family != AF_INET)
      continue;
    if ((cur->ifa_flags & IFF_UP) == 0 ||
        (cur->ifa_flags & IFF_LOOPBACK) != 0)
      continue;

    char buf[INET_ADDRSTRLEN] = {0};
    struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
    if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf)))
      continue;

    NSString *addr = [NSString stringWithUTF8String:buf];
    NSString *name = [NSString stringWithUTF8String:cur->ifa_name];
    if ([name hasPrefix:@"en"] || [name hasPrefix:@"pdp_ip"]) {
      preferred = addr;
      break;
    }
    if (!fallback)
      fallback = addr;
  }

  freeifaddrs(ifap);
  return preferred ?: fallback;
}

// MARK: - Diagnostics

static NSString *first_executable_path(NSArray<NSString *> *paths) {
  for (NSString *path in paths) {
    if (access(path.UTF8String, X_OK) == 0)
      return path;
  }
  return nil;
}

static NSMutableDictionary *run_program_capture(NSString *program,
                                                NSArray<NSString *> *args,
                                                NSString *responseType,
                                                id reqId,
                                                NSTimeInterval timeout) {
  int outPipe[2];
  if (pipe(outPipe) != 0) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"pipe failed: %s", strerror(errno)];
    return r;
  }

  NSUInteger argc = args.count + 2;
  char **argv = calloc(argc, sizeof(char *));
  argv[0] = strdup(program.UTF8String ?: "");
  for (NSUInteger i = 0; i < args.count; i++)
    argv[i + 1] = strdup(args[i].UTF8String ?: "");
  argv[argc - 1] = NULL;

  pid_t pid = 0;
  pid = fork();
  if (pid == 0) {
    close(outPipe[0]);
    dup2(outPipe[1], STDOUT_FILENO);
    dup2(outPipe[1], STDERR_FILENO);
    close(outPipe[1]);
    execv(argv[0], argv);
    _exit(127);
  }

  for (NSUInteger i = 0; i < argc; i++)
    free(argv[i]);
  free(argv);
  close(outPipe[1]);

  if (pid < 0) {
    close(outPipe[0]);
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"fork failed: %s", strerror(errno)];
    return r;
  }

  int flags = fcntl(outPipe[0], F_GETFL, 0);
  if (flags >= 0)
    fcntl(outPipe[0], F_SETFL, flags | O_NONBLOCK);

  NSMutableData *output = [NSMutableData data];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  BOOL timedOut = NO;
  int status = 0;

  for (;;) {
    uint8_t buf[4096];
    ssize_t n = read(outPipe[0], buf, sizeof(buf));
    if (n > 0) {
      if (output.length < 128 * 1024) {
        NSUInteger take = MIN((NSUInteger)n, 128 * 1024 - output.length);
        [output appendBytes:buf length:take];
      }
      continue;
    }

    pid_t waited = waitpid(pid, &status, WNOHANG);
    if (waited == pid)
      break;

    if ([deadline timeIntervalSinceNow] <= 0) {
      kill(pid, SIGKILL);
      waitpid(pid, &status, 0);
      timedOut = YES;
      break;
    }

    usleep(10000);
  }

  for (;;) {
    uint8_t buf[4096];
    ssize_t n = read(outPipe[0], buf, sizeof(buf));
    if (n <= 0)
      break;
    if (output.length < 128 * 1024) {
      NSUInteger take = MIN((NSUInteger)n, 128 * 1024 - output.length);
      [output appendBytes:buf length:take];
    }
  }
  close(outPipe[0]);

  NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";
  NSMutableDictionary *r = vp_make_response(responseType, reqId);
  r[@"output"] = text;
  r[@"timed_out"] = @(timedOut);
  if (WIFEXITED(status))
    r[@"exit_status"] = @(WEXITSTATUS(status));
  else if (WIFSIGNALED(status))
    r[@"signal"] = @(WTERMSIG(status));
  return r;
}

static NSDictionary *handle_diag_processes(NSDictionary *msg) {
  NSString *match = msg[@"match"];
  NSString *matchLower = match.length > 0 ? match.lowercaseString : nil;
  int maxPid = [msg[@"max_pid"] intValue];
  if (maxPid <= 0)
    maxPid = 512;
  if (maxPid > 4096)
    maxPid = 4096;

  NSMutableArray *items = [NSMutableArray array];
  for (int pid = 1; pid <= maxPid; pid++) {
    char name[256] = {0};
    int n = proc_name(pid, name, sizeof(name));
    if (n <= 0 || name[0] == '\0')
      continue;
    NSString *procName = [NSString stringWithUTF8String:name] ?: @"";
    if (matchLower &&
        [procName.lowercaseString rangeOfString:matchLower].location ==
            NSNotFound) {
      continue;
    }
    [items addObject:@{ @"pid" : @(pid), @"name" : procName }];
  }

  NSMutableDictionary *r = vp_make_response(@"diag_processes", msg[@"id"]);
  r[@"processes"] = items;
  r[@"max_pid"] = @(maxPid);
  return r;
}

static size_t bounded_cstring_length(const char *start, const char *end) {
  const char *p = start;
  while (p < end && *p != '\0')
    p++;
  return (size_t)(p - start);
}

static NSString *string_from_cstring_range(const char *start, const char *end) {
  size_t len = bounded_cstring_length(start, end);
  if (len == 0)
    return @"";
  NSString *s = [[NSString alloc] initWithBytes:start
                                         length:len
                                       encoding:NSUTF8StringEncoding];
  return s ?: @"";
}

static NSDictionary *handle_diag_procinfo(NSDictionary *msg) {
  int pid = [msg[@"pid"] intValue];
  if (pid <= 0) {
    NSMutableDictionary *r = vp_make_response(@"err", msg[@"id"]);
    r[@"msg"] = @"invalid pid";
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"diag_procinfo", msg[@"id"]);
  r[@"pid"] = @(pid);

  char name[256] = {0};
  int nameLen = proc_name(pid, name, sizeof(name));
  if (nameLen > 0 && name[0] != '\0')
    r[@"name"] = [NSString stringWithUTF8String:name] ?: @"";

  char path[4096] = {0};
  int pathLen = proc_pidpath(pid, path, sizeof(path));
  if (pathLen > 0 && path[0] != '\0')
    r[@"path"] = [NSString stringWithUTF8String:path] ?: @"";
  else
    r[@"path_error"] = [NSString stringWithFormat:@"%s", strerror(errno)];

  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t size = 0;
  if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) {
    r[@"procargs_error"] = [NSString stringWithFormat:@"%s", strerror(errno)];
    return r;
  }

  NSMutableData *data = [NSMutableData dataWithLength:size];
  if (sysctl(mib, 3, data.mutableBytes, &size, NULL, 0) != 0 ||
      size < sizeof(int)) {
    r[@"procargs_error"] = [NSString stringWithFormat:@"%s", strerror(errno)];
    return r;
  }

  const char *base = (const char *)data.bytes;
  const char *end = base + size;
  int argc = 0;
  memcpy(&argc, base, sizeof(argc));
  r[@"argc"] = @(argc);

  const char *p = base + sizeof(argc);
  if (p >= end)
    return r;

  NSString *execPath = string_from_cstring_range(p, end);
  if (execPath.length > 0)
    r[@"exec_path_from_args"] = execPath;

  p += bounded_cstring_length(p, end);
  if (p < end)
    p++;
  while (p < end && *p == '\0')
    p++;

  NSMutableArray *args = [NSMutableArray array];
  for (int i = 0; i < argc && p < end; i++) {
    while (p < end && *p == '\0')
      p++;
    if (p >= end)
      break;
    NSString *arg = string_from_cstring_range(p, end);
    [args addObject:arg];
    p += bounded_cstring_length(p, end);
    if (p < end)
      p++;
  }
  r[@"args"] = args;
  return r;
}

static NSDictionary *handle_diag_launchctl(NSDictionary *msg) {
  NSMutableDictionary *disabled = vp_make_response(@"err", msg[@"id"]);
  disabled[@"msg"] = @"diag_launchctl disabled: posix_spawn blocks in this guest";
  return disabled;

  NSString *label = msg[@"label"];
  NSString *action = msg[@"action"] ?: @"print";
  NSSet *allowedLabels = [NSSet setWithArray:@[
    @"com.apple.SpringBoard",
    @"com.apple.backboardd",
    @"com.apple.mobile.lockdown",
    @"com.apple.runningboardd",
    @"com.apple.assertiond",
  ]];
  NSSet *allowedActions =
      [NSSet setWithArray:@[ @"print", @"blame", @"kickstart" ]];

  if (![allowedLabels containsObject:label] ||
      ![allowedActions containsObject:action]) {
    NSMutableDictionary *r = vp_make_response(@"err", msg[@"id"]);
    r[@"msg"] = @"unsupported launchctl diagnostic";
    return r;
  }

  NSString *target = [@"system/" stringByAppendingString:label];
  NSArray *args = nil;
  if ([action isEqualToString:@"kickstart"])
    args = @[ @"kickstart", @"-kp", target ];
  else
    args = @[ action, target ];
  NSString *launchctl = first_executable_path(@[ @"/bin/launchctl", @"/sbin/launchctl" ]);
  if (!launchctl) {
    NSMutableDictionary *r = vp_make_response(@"err", msg[@"id"]);
    r[@"msg"] = @"launchctl not found";
    return r;
  }
  return run_program_capture(launchctl, args, @"diag_launchctl", msg[@"id"], 3.0);
}

static NSDictionary *handle_diag_exec(NSDictionary *msg) {
  NSString *program = msg[@"program"];
  NSArray *args = [msg[@"args"] isKindOfClass:[NSArray class]] ? msg[@"args"] : @[];
  NSNumber *timeoutValue = msg[@"timeout"];
  NSTimeInterval timeout = timeoutValue ? timeoutValue.doubleValue : 3.0;
  if (timeout <= 0 || timeout > 20)
    timeout = 3.0;

  NSSet *allowedPrograms = [NSSet setWithArray:@[
    @"/bin/launchctl",
    @"/sbin/launchctl",
    @"/bin/ps",
    @"/usr/bin/log",
    @"/usr/sbin/ioreg",
    @"/usr/bin/mg",
    @"/usr/bin/sysctl",
  ]];
  if (![allowedPrograms containsObject:program]) {
    NSMutableDictionary *r = vp_make_response(@"err", msg[@"id"]);
    r[@"msg"] = @"unsupported diagnostic program";
    return r;
  }

  NSMutableArray<NSString *> *cleanArgs = [NSMutableArray arrayWithCapacity:args.count];
  for (id arg in args) {
    if (![arg isKindOfClass:[NSString class]]) {
      NSMutableDictionary *r = vp_make_response(@"err", msg[@"id"]);
      r[@"msg"] = @"diag_exec args must be strings";
      return r;
    }
    [cleanArgs addObject:(NSString *)arg];
  }

  return run_program_capture(program, cleanArgs, @"diag_exec", msg[@"id"], timeout);
}

static NSDictionary *handle_diag_spawn(NSDictionary *msg) {
  NSString *program = msg[@"program"];
  NSArray *args = [msg[@"args"] isKindOfClass:[NSArray class]] ? msg[@"args"] : @[];

  BOOL allowed = [program isEqualToString:@"/usr/sbin/cfprefsd"] &&
                 args.count == 1 &&
                 [args[0] isKindOfClass:[NSString class]] &&
                 [(NSString *)args[0] isEqualToString:@"daemon"];
  if (!allowed) {
    NSMutableDictionary *r = vp_make_response(@"err", msg[@"id"]);
    r[@"msg"] = @"unsupported diagnostic spawn";
    return r;
  }

  NSUInteger argc = args.count + 2;
  char **argv = calloc(argc, sizeof(char *));
  argv[0] = strdup(program.UTF8String ?: "");
  for (NSUInteger i = 0; i < args.count; i++)
    argv[i + 1] = strdup(((NSString *)args[i]).UTF8String ?: "");
  argv[argc - 1] = NULL;

  pid_t pid = fork();
  if (pid == 0) {
    int nullFd = open("/dev/null", O_RDWR);
    if (nullFd >= 0) {
      dup2(nullFd, STDIN_FILENO);
      dup2(nullFd, STDOUT_FILENO);
      dup2(nullFd, STDERR_FILENO);
      if (nullFd > STDERR_FILENO)
        close(nullFd);
    }
    execv(argv[0], argv);
    _exit(127);
  }

  for (NSUInteger i = 0; i < argc; i++)
    free(argv[i]);
  free(argv);

  if (pid < 0) {
    NSMutableDictionary *r = vp_make_response(@"err", msg[@"id"]);
    r[@"msg"] = [NSString stringWithFormat:@"fork failed: %s", strerror(errno)];
    return r;
  }

  usleep(100000);
  int status = 0;
  pid_t waited = waitpid(pid, &status, WNOHANG);

  NSMutableDictionary *r = vp_make_response(@"diag_spawn", msg[@"id"]);
  r[@"program"] = program ?: @"";
  r[@"args"] = args ?: @[];
  r[@"pid"] = @(pid);
  r[@"running"] = @(waited == 0);
  if (waited == pid) {
    if (WIFEXITED(status))
      r[@"exit_status"] = @(WEXITSTATUS(status));
    else if (WIFSIGNALED(status))
      r[@"signal"] = @(WTERMSIG(status));
  }
  return r;
}

static NSDictionary *handle_diag_bootstrap(NSDictionary *msg) {
  NSArray *services = [msg[@"services"] isKindOfClass:[NSArray class]]
                          ? msg[@"services"]
                          : @[
                              @"com.apple.cfprefsd.daemon",
                              @"com.apple.cfprefsd.daemon.system",
                            ];
  NSSet *allowedServices = [NSSet setWithArray:@[
    @"com.apple.cfprefsd.daemon",
    @"com.apple.cfprefsd.daemon.system",
  ]];

  NSMutableArray *items = [NSMutableArray array];
  for (id item in services) {
    if (![item isKindOfClass:[NSString class]])
      continue;
    NSString *service = (NSString *)item;
    if (![allowedServices containsObject:service])
      continue;

    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port,
                                         (char *)service.UTF8String, &port);
    if (port != MACH_PORT_NULL)
      mach_port_deallocate(mach_task_self(), port);
    [items addObject:@{
      @"service" : service,
      @"kr" : @(kr),
      @"kr_name" : [NSString stringWithUTF8String:mach_error_string(kr)] ?: @"",
      @"found" : @(kr == KERN_SUCCESS),
    }];
  }

  NSMutableDictionary *r = vp_make_response(@"diag_bootstrap", msg[@"id"]);
  r[@"services"] = items;
  return r;
}

typedef void (^VPStageSetter)(NSString *stage);
typedef NSDictionary *(^VPChildProbeBlock)(VPStageSetter setStage);

static NSDictionary *run_diag_bundle_probe(id reqId, NSString *bundlePath);
static NSArray *apv_install_trace(Class cls, NSMutableArray *trace);
static NSMutableArray *gAPVTraceLog = nil;

static void vp_write_child_probe_event(int fd, NSDictionary *event) {
  NSError *error = nil;
  NSData *json = [NSJSONSerialization dataWithJSONObject:event ?: @{}
                                                 options:0
                                                   error:&error];
  if (!json)
    return;

  const uint8_t *bytes = json.bytes;
  NSUInteger remaining = json.length;
  while (remaining > 0) {
    ssize_t n = write(fd, bytes, remaining);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return;
    }
    bytes += n;
    remaining -= (NSUInteger)n;
  }

  char nl = '\n';
  while (write(fd, &nl, 1) < 0 && errno == EINTR) {
  }
}

typedef struct {
  mach_port_t targetThread;
  int fd;
  useconds_t delayUs;
} VPThreadSamplerContext;

static void *vp_thread_sampler_main(void *opaque) {
  VPThreadSamplerContext *ctx = (VPThreadSamplerContext *)opaque;
  usleep(ctx->delayUs);

  arm_thread_state64_t state;
  mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
  memset(&state, 0, sizeof(state));

  kern_return_t suspendKr = thread_suspend(ctx->targetThread);
  kern_return_t stateKr =
      thread_get_state(ctx->targetThread, ARM_THREAD_STATE64,
                       (thread_state_t)&state, &count);

  uint64_t pc = state.__pc;
  uint64_t lr = state.__lr;
  uint64_t sp = state.__sp;
  uint64_t fp = state.__fp;

  Dl_info info;
  memset(&info, 0, sizeof(info));
  int dlOk = dladdr((void *)(uintptr_t)pc, &info);
  uintptr_t imageBase = dlOk ? (uintptr_t)info.dli_fbase : 0;
  uintptr_t symbolAddr = dlOk ? (uintptr_t)info.dli_saddr : 0;
  const char *image = (dlOk && info.dli_fname) ? info.dli_fname : "";
  const char *symbol = (dlOk && info.dli_sname) ? info.dli_sname : "";

  dprintf(ctx->fd,
          "{\"kind\":\"sample\",\"suspend_kr\":%d,\"state_kr\":%d,"
          "\"pc\":\"0x%llx\",\"lr\":\"0x%llx\",\"sp\":\"0x%llx\","
          "\"fp\":\"0x%llx\",\"image\":\"%s\",\"image_base\":\"0x%llx\","
          "\"symbol\":\"%s\",\"symbol_addr\":\"0x%llx\","
          "\"image_offset\":\"0x%llx\",\"symbol_offset\":\"0x%llx\","
          "\"frames\":[",
          suspendKr, stateKr, (unsigned long long)pc, (unsigned long long)lr,
          (unsigned long long)sp, (unsigned long long)fp, image,
          (unsigned long long)imageBase, symbol, (unsigned long long)symbolAddr,
          (unsigned long long)(imageBase ? pc - imageBase : 0),
          (unsigned long long)(symbolAddr ? pc - symbolAddr : 0));

  uint64_t curFp = fp;
  for (int i = 0; i < 32 && curFp != 0; i++) {
    uint64_t words[2] = {0, 0};
    vm_size_t outSize = 0;
    kern_return_t readKr =
        vm_read_overwrite(mach_task_self(), (vm_address_t)curFp, sizeof(words),
                          (vm_address_t)words, &outSize);
    if (readKr != KERN_SUCCESS || outSize != sizeof(words))
      break;

    uint64_t nextFp = words[0];
    uint64_t ret = words[1];
    if (ret == 0)
      break;

    Dl_info frameInfo;
    memset(&frameInfo, 0, sizeof(frameInfo));
    int frameDlOk = dladdr((void *)(uintptr_t)ret, &frameInfo);
    uintptr_t frameImageBase =
        frameDlOk ? (uintptr_t)frameInfo.dli_fbase : 0;
    uintptr_t frameSymbolAddr =
        frameDlOk ? (uintptr_t)frameInfo.dli_saddr : 0;
    const char *frameImage =
        (frameDlOk && frameInfo.dli_fname) ? frameInfo.dli_fname : "";
    const char *frameSymbol =
        (frameDlOk && frameInfo.dli_sname) ? frameInfo.dli_sname : "";

    dprintf(ctx->fd,
            "%s{\"ra\":\"0x%llx\",\"fp\":\"0x%llx\",\"image\":\"%s\","
            "\"image_base\":\"0x%llx\",\"symbol\":\"%s\","
            "\"symbol_addr\":\"0x%llx\",\"image_offset\":\"0x%llx\","
            "\"symbol_offset\":\"0x%llx\"}",
            i == 0 ? "" : ",", (unsigned long long)ret,
            (unsigned long long)curFp, frameImage,
            (unsigned long long)frameImageBase, frameSymbol,
            (unsigned long long)frameSymbolAddr,
            (unsigned long long)(frameImageBase ? ret - frameImageBase : 0),
            (unsigned long long)(frameSymbolAddr ? ret - frameSymbolAddr : 0));

    if (nextFp <= curFp || nextFp - curFp > 1024 * 1024)
      break;
    curFp = nextFp;
  }

  dprintf(ctx->fd, "]}\n");
  _exit(124);
  return NULL;
}

static void vp_start_thread_sampler(int fd, int delayMs) {
  if (delayMs <= 0)
    return;

  VPThreadSamplerContext *ctx = calloc(1, sizeof(*ctx));
  if (!ctx)
    return;

  ctx->targetThread = mach_thread_self();
  ctx->fd = fd;
  ctx->delayUs = (useconds_t)delayMs * 1000;

  pthread_t thread;
  int err = pthread_create(&thread, NULL, vp_thread_sampler_main, ctx);
  if (err == 0)
    pthread_detach(thread);
  else
    free(ctx);
}

static void vp_patch_function_return_zero(const char *symbol) {
  void *fn = dlsym(RTLD_DEFAULT, symbol);
  if (!fn) {
    dprintf(STDOUT_FILENO,
            "{\"kind\":\"code_patch\",\"symbol\":\"%s\",\"found\":false}\n",
            symbol ?: "");
    return;
  }

  vm_size_t pageSize = (vm_size_t)getpagesize();
  vm_address_t page = (vm_address_t)((uintptr_t)fn & ~((uintptr_t)pageSize - 1));
  kern_return_t protectKr =
      vm_protect(mach_task_self(), page, pageSize, false,
                 VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);

  if (protectKr == KERN_SUCCESS) {
    uint32_t patch[] = {
        0xaa1f03e0, // mov x0, xzr
        0xd65f03c0, // ret
    };
    memcpy(fn, patch, sizeof(patch));
    sys_icache_invalidate(fn, sizeof(patch));
  }

  kern_return_t restoreKr =
      vm_protect(mach_task_self(), page, pageSize, false,
                 VM_PROT_READ | VM_PROT_EXECUTE);
  dprintf(STDOUT_FILENO,
          "{\"kind\":\"code_patch\",\"symbol\":\"%s\",\"found\":true,"
          "\"addr\":\"%p\",\"protect_kr\":%d,\"restore_kr\":%d}\n",
          symbol ?: "", fn, protectKr, restoreKr);
}

static void vp_patch_metal_preference_functions(void) {
  const char *symbols[] = {
      "_CFPreferencesGetAppIntegerValueWithContainer",
      "_CFPreferencesGetAppBooleanValueWithContainer",
      "_CFPreferencesCopyAppValueWithContainerAndConfiguration",
      "CFPreferencesGetAppIntegerValue",
      "CFPreferencesGetAppBooleanValue",
      "CFPreferencesCopyAppValue",
  };
  for (size_t i = 0; i < sizeof(symbols) / sizeof(symbols[0]); i++)
    vp_patch_function_return_zero(symbols[i]);
}

static NSMutableDictionary *
run_child_probe_capture(NSString *responseType, id reqId, NSTimeInterval timeout,
                        VPChildProbeBlock block) {
  int outPipe[2];
  if (pipe(outPipe) != 0) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"pipe failed: %s", strerror(errno)];
    return r;
  }

  pid_t pid = fork();
  if (pid < 0) {
    close(outPipe[0]);
    close(outPipe[1]);
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"fork failed: %s", strerror(errno)];
    return r;
  }

  if (pid == 0) {
    close(outPipe[0]);
    int childWriteFd = outPipe[1];
    @autoreleasepool {
      __block NSString *childStage = @"child_start";
      VPStageSetter setStage = ^(NSString *newStage) {
        childStage = [newStage copy] ?: @"";
        vp_write_child_probe_event(childWriteFd, @{
          @"kind" : @"stage",
          @"stage" : childStage
        });
      };

      NSDictionary *result = block ? block(setStage) : @{};
      vp_write_child_probe_event(childWriteFd, @{
        @"kind" : @"result",
        @"stage" : childStage ?: @"",
        @"result" : result ?: @{}
      });
    }
    close(childWriteFd);
    _exit(0);
  }

  close(outPipe[1]);
  int flags = fcntl(outPipe[0], F_GETFL, 0);
  if (flags >= 0)
    fcntl(outPipe[0], F_SETFL, flags | O_NONBLOCK);

  NSMutableData *pending = [NSMutableData data];
  NSMutableArray *events = [NSMutableArray array];
  __block NSDictionary *probeResult = nil;
  __block NSString *lastStage = @"child_start";

  void (^consumeLines)(BOOL) = ^(BOOL flush) {
    for (;;) {
      const uint8_t *bytes = pending.bytes;
      NSUInteger length = pending.length;
      const uint8_t *newline = length > 0 ? memchr(bytes, '\n', length) : NULL;
      if (!newline) {
        if (!flush || length == 0)
          break;
        newline = bytes + length;
      }

      NSUInteger lineLength = (NSUInteger)(newline - bytes);
      NSData *line = [pending subdataWithRange:NSMakeRange(0, lineLength)];
      NSUInteger removeLength = lineLength + (newline < bytes + length ? 1 : 0);
      [pending replaceBytesInRange:NSMakeRange(0, removeLength)
                         withBytes:NULL
                            length:0];
      if (line.length == 0)
        continue;

      NSError *error = nil;
      id obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
      if (![obj isKindOfClass:[NSDictionary class]])
        continue;

      NSDictionary *event = (NSDictionary *)obj;
      [events addObject:event];
      NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]]
                           ? event[@"kind"]
                           : @"";
      if ([kind isEqualToString:@"stage"]) {
        NSString *stage = [event[@"stage"] isKindOfClass:[NSString class]]
                              ? event[@"stage"]
                              : @"";
        if (stage.length > 0)
          lastStage = stage;
      } else if ([kind isEqualToString:@"result"]) {
        NSDictionary *result =
            [event[@"result"] isKindOfClass:[NSDictionary class]]
                ? event[@"result"]
                : @{};
        probeResult = result;
        NSString *stage = [event[@"stage"] isKindOfClass:[NSString class]]
                              ? event[@"stage"]
                              : @"";
        if (stage.length > 0)
          lastStage = stage;
      }

      if (!flush && pending.length == 0)
        break;
    }
  };

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  BOOL timedOut = NO;
  int status = 0;

  for (;;) {
    uint8_t buf[4096];
    ssize_t n = read(outPipe[0], buf, sizeof(buf));
    if (n > 0) {
      if (pending.length < 512 * 1024) {
        NSUInteger take = MIN((NSUInteger)n, 512 * 1024 - pending.length);
        [pending appendBytes:buf length:take];
      }
      consumeLines(NO);
      continue;
    }

    if (n < 0 && errno == EINTR)
      continue;

    pid_t waited = waitpid(pid, &status, WNOHANG);
    if (waited == pid)
      break;

    if ([deadline timeIntervalSinceNow] <= 0) {
      kill(pid, SIGKILL);
      waitpid(pid, &status, 0);
      timedOut = YES;
      break;
    }

    usleep(10000);
  }

  for (;;) {
    uint8_t buf[4096];
    ssize_t n = read(outPipe[0], buf, sizeof(buf));
    if (n <= 0)
      break;
    if (pending.length < 512 * 1024) {
      NSUInteger take = MIN((NSUInteger)n, 512 * 1024 - pending.length);
      [pending appendBytes:buf length:take];
    }
  }
  consumeLines(YES);
  close(outPipe[0]);

  NSMutableDictionary *r =
      [probeResult mutableCopy] ?: vp_make_response(responseType, reqId);
  r[@"isolated"] = @YES;
  r[@"child_pid"] = @(pid);
  r[@"timed_out"] = @(timedOut);
  if (!r[@"stage"])
    r[@"stage"] = lastStage ?: @"";
  if (events.count > 0)
    r[@"child_events"] = events;
  if (WIFEXITED(status))
    r[@"exit_status"] = @(WEXITSTATUS(status));
  else if (WIFSIGNALED(status))
    r[@"signal"] = @(WTERMSIG(status));
  return r;
}

static void vp_consume_child_probe_lines(NSMutableData *pending,
                                         NSMutableArray *events,
                                         NSDictionary *__strong *probeResult,
                                         NSString *__strong *lastStage,
                                         BOOL flush) {
  for (;;) {
    const uint8_t *bytes = pending.bytes;
    NSUInteger length = pending.length;
    const uint8_t *newline = length > 0 ? memchr(bytes, '\n', length) : NULL;
    if (!newline) {
      if (!flush || length == 0)
        break;
      newline = bytes + length;
    }

    NSUInteger lineLength = (NSUInteger)(newline - bytes);
    NSData *line = [pending subdataWithRange:NSMakeRange(0, lineLength)];
    NSUInteger removeLength = lineLength + (newline < bytes + length ? 1 : 0);
    [pending replaceBytesInRange:NSMakeRange(0, removeLength)
                       withBytes:NULL
                          length:0];
    if (line.length == 0)
      continue;

    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
    if (![obj isKindOfClass:[NSDictionary class]])
      continue;

    NSDictionary *event = (NSDictionary *)obj;
    [events addObject:event];
    NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]]
                         ? event[@"kind"]
                         : @"";
    if ([kind isEqualToString:@"stage"]) {
      NSString *stage = [event[@"stage"] isKindOfClass:[NSString class]]
                            ? event[@"stage"]
                            : @"";
      if (stage.length > 0)
        *lastStage = stage;
    } else if ([kind isEqualToString:@"result"]) {
      NSDictionary *result = [event[@"result"] isKindOfClass:[NSDictionary class]]
                                 ? event[@"result"]
                                 : @{};
      *probeResult = result;
      NSString *stage = [event[@"stage"] isKindOfClass:[NSString class]]
                            ? event[@"stage"]
                            : @"";
      if (stage.length > 0)
        *lastStage = stage;
    }

    if (!flush && pending.length == 0)
      break;
  }
}

static NSMutableDictionary *
run_exec_child_probe_capture(NSString *responseType, id reqId,
                             NSTimeInterval timeout,
                             NSArray<NSString *> *arguments) {
  const char *selfPath = self_executable_path();
  if (!selfPath) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"self executable path unavailable";
    return r;
  }

  NSUInteger argc = arguments.count + 2;
  char **argv = calloc(argc, sizeof(char *));
  argv[0] = strdup(selfPath);
  for (NSUInteger i = 0; i < arguments.count; i++)
    argv[i + 1] = strdup(arguments[i].UTF8String ?: "");
  argv[argc - 1] = NULL;

  int outPipe[2];
  if (pipe(outPipe) != 0) {
    for (NSUInteger i = 0; i < argc; i++)
      free(argv[i]);
    free(argv);
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"pipe failed: %s", strerror(errno)];
    return r;
  }

  pid_t pid = fork();
  if (pid < 0) {
    close(outPipe[0]);
    close(outPipe[1]);
    for (NSUInteger i = 0; i < argc; i++)
      free(argv[i]);
    free(argv);
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"fork failed: %s", strerror(errno)];
    return r;
  }

  if (pid == 0) {
    close(outPipe[0]);
    dup2(outPipe[1], STDOUT_FILENO);
    dup2(outPipe[1], STDERR_FILENO);
    close(outPipe[1]);
    execv(argv[0], argv);
    _exit(127);
  }

  for (NSUInteger i = 0; i < argc; i++)
    free(argv[i]);
  free(argv);
  close(outPipe[1]);

  int flags = fcntl(outPipe[0], F_GETFL, 0);
  if (flags >= 0)
    fcntl(outPipe[0], F_SETFL, flags | O_NONBLOCK);

  NSMutableData *pending = [NSMutableData data];
  NSMutableArray *events = [NSMutableArray array];
  NSDictionary *probeResult = nil;
  NSString *lastStage = @"exec_child_start";
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  BOOL timedOut = NO;
  int status = 0;

  for (;;) {
    uint8_t buf[4096];
    ssize_t n = read(outPipe[0], buf, sizeof(buf));
    if (n > 0) {
      if (pending.length < 512 * 1024) {
        NSUInteger take = MIN((NSUInteger)n, 512 * 1024 - pending.length);
        [pending appendBytes:buf length:take];
      }
      vp_consume_child_probe_lines(pending, events, &probeResult, &lastStage, NO);
      continue;
    }

    if (n < 0 && errno == EINTR)
      continue;

    pid_t waited = waitpid(pid, &status, WNOHANG);
    if (waited == pid)
      break;

    if ([deadline timeIntervalSinceNow] <= 0) {
      kill(pid, SIGKILL);
      waitpid(pid, &status, 0);
      timedOut = YES;
      break;
    }

    usleep(10000);
  }

  for (;;) {
    uint8_t buf[4096];
    ssize_t n = read(outPipe[0], buf, sizeof(buf));
    if (n <= 0)
      break;
    if (pending.length < 512 * 1024) {
      NSUInteger take = MIN((NSUInteger)n, 512 * 1024 - pending.length);
      [pending appendBytes:buf length:take];
    }
  }
  vp_consume_child_probe_lines(pending, events, &probeResult, &lastStage, YES);
  close(outPipe[0]);

  NSMutableDictionary *r =
      [probeResult mutableCopy] ?: vp_make_response(responseType, reqId);
  r[@"isolated"] = @YES;
  r[@"isolation"] = @"fork_exec";
  r[@"child_pid"] = @(pid);
  r[@"timed_out"] = @(timedOut);
  if (!r[@"stage"])
    r[@"stage"] = lastStage ?: @"";
  if (events.count > 0)
    r[@"child_events"] = events;
  if (WIFEXITED(status))
    r[@"exit_status"] = @(WEXITSTATUS(status));
  else if (WIFSIGNALED(status))
    r[@"signal"] = @(WTERMSIG(status));
  return r;
}

typedef id (*VPObjCStringIMP)(id, SEL);
static VPObjCStringIMP gIOGPUMetalDeviceNameOrig = NULL;
static VPObjCStringIMP gIOGPUMetalDeviceProductNameOrig = NULL;
static VPObjCStringIMP gIOGPUMetalDeviceVendorNameOrig = NULL;
static VPObjCStringIMP gAppleParavirtDeviceNameOrig = NULL;
static VPObjCStringIMP gAppleParavirtDeviceProductNameOrig = NULL;
static VPObjCStringIMP gAppleParavirtDeviceVendorNameOrig = NULL;

static id vp_stub_iogpu_name(id self, SEL _cmd) {
  (void)self;
  if (sel_isEqual(_cmd, NSSelectorFromString(@"productName")))
    return @"Apple Paravirt GPU";
  if (sel_isEqual(_cmd, NSSelectorFromString(@"vendorName")))
    return @"Apple";
  return @"Apple Paravirt GPU";
}

static void vp_swizzle_string_method(Class cls, NSString *name,
                                     VPObjCStringIMP *original,
                                     IMP replacement,
                                     NSMutableArray *events) {
  SEL sel = NSSelectorFromString(name);
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) {
    [events addObject:@{ @"class" : NSStringFromClass(cls) ?: @"",
                         @"method" : name,
                         @"installed" : @NO }];
    return;
  }
  if (!*original)
    *original = (VPObjCStringIMP)method_setImplementation(method, replacement);
  [events addObject:@{ @"class" : NSStringFromClass(cls) ?: @"",
                       @"method" : name,
                       @"installed" : @(*original != NULL) }];
}

static NSArray *vp_install_iogpu_name_stubs(void) {
  NSMutableArray *events = [NSMutableArray array];
  Class cls = NSClassFromString(@"IOGPUMetalDevice");
  if (cls) {
    vp_swizzle_string_method(cls, @"name", &gIOGPUMetalDeviceNameOrig,
                             (IMP)vp_stub_iogpu_name, events);
    vp_swizzle_string_method(cls, @"productName",
                             &gIOGPUMetalDeviceProductNameOrig,
                             (IMP)vp_stub_iogpu_name, events);
    vp_swizzle_string_method(cls, @"vendorName",
                             &gIOGPUMetalDeviceVendorNameOrig,
                             (IMP)vp_stub_iogpu_name, events);
  } else {
    [events addObject:@{ @"class" : @"IOGPUMetalDevice",
                         @"installed" : @NO }];
  }

  Class apvCls = NSClassFromString(@"AppleParavirtDevice");
  if (apvCls) {
    vp_swizzle_string_method(apvCls, @"name", &gAppleParavirtDeviceNameOrig,
                             (IMP)vp_stub_iogpu_name, events);
    vp_swizzle_string_method(apvCls, @"productName",
                             &gAppleParavirtDeviceProductNameOrig,
                             (IMP)vp_stub_iogpu_name, events);
    vp_swizzle_string_method(apvCls, @"vendorName",
                             &gAppleParavirtDeviceVendorNameOrig,
                             (IMP)vp_stub_iogpu_name, events);
  } else {
    [events addObject:@{ @"class" : @"AppleParavirtDevice",
                         @"installed" : @NO }];
  }
  return events;
}

static NSDictionary *run_diag_metal_probe(id reqId, NSString *metalPath,
                                          NSString *mode,
                                          BOOL stubNames,
                                          BOOL stubMetalPrefs,
                                          VPStageSetter setStage) {
  NSMutableDictionary *r = vp_make_response(@"diag_metal", reqId);
  r[@"path"] = metalPath;
  r[@"mode"] = mode ?: @"create_default";
  r[@"stub_names"] = @(stubNames);
  r[@"stub_metal_prefs"] = @(stubMetalPrefs);

  setStage(@"dlopen_metal");
  void *metal = dlopen(metalPath.UTF8String, RTLD_LAZY | RTLD_LOCAL);
  if (!metal) {
    r[@"metal_loaded"] = @NO;
    r[@"stage"] = @"dlopen_metal";
    r[@"dlerror"] = [NSString stringWithUTF8String:dlerror() ?: "unknown"];
    return r;
  }
  r[@"metal_loaded"] = @YES;

  if (stubMetalPrefs) {
    setStage(@"rebind_metal_prefs");
    NSArray *prefRebind = vp_rebind_metal_preference_imports(metalPath);
    r[@"pref_rebind"] = prefRebind;
    if (getenv("VPHONED_STUB_METAL_PREFS")) {
      for (NSDictionary *event in prefRebind)
        vp_write_child_probe_event(STDOUT_FILENO, event);
    }
  }

  if (stubNames) {
    setStage(@"load_apv_bundle");
    r[@"apv_bundle"] = run_diag_bundle_probe(
        reqId, @"/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle");
    setStage(@"install_name_stubs");
    r[@"name_stubs"] = vp_install_iogpu_name_stubs();
    Class apvCls = NSClassFromString(@"AppleParavirtDevice");
    if (apvCls) {
      NSMutableArray *trace = [NSMutableArray array];
      r[@"apv_trace_install"] = apv_install_trace(apvCls, trace);
    }
  }

  setStage(@"dlsym_MTLCreateSystemDefaultDevice");
  typedef id (*MTLCreateSystemDefaultDeviceFn)(void);
  typedef CFArrayRef (*MTLCopyAllDevicesFn)(void);
  typedef void (*MTLPrivateVoidFn)(void);
  dlerror();
  MTLCreateSystemDefaultDeviceFn createDevice =
      (MTLCreateSystemDefaultDeviceFn)dlsym(metal, "MTLCreateSystemDefaultDevice");
  MTLCopyAllDevicesFn copyAllDevices =
      (MTLCopyAllDevicesFn)dlsym(metal, "MTLCopyAllDevices");
  if (!createDevice) {
    r[@"device_available"] = @NO;
    r[@"stage"] = @"dlsym_MTLCreateSystemDefaultDevice";
    r[@"dlsym_error"] = [NSString stringWithUTF8String:dlerror() ?: "unknown"];
    return r;
  }
  r[@"copy_all_devices_symbol"] = @(copyAllDevices != NULL);

  if ([mode isEqualToString:@"copy_all"]) {
    if (!copyAllDevices) {
      r[@"stage"] = @"dlsym_MTLCopyAllDevices";
      return r;
    }
    setStage([NSString stringWithFormat:@"copy_all_devices@0x%llx",
                                        (unsigned long long)(uintptr_t)
                                            copyAllDevices]);
    CFArrayRef devices = copyAllDevices();
    r[@"devices"] = @(devices != NULL);
    if (devices) {
      r[@"device_count"] = @(CFArrayGetCount(devices));
      CFRelease(devices);
    }
    r[@"stage"] = @"done";
    return r;
  }

  if ([mode isEqualToString:@"init_array"] ||
      [mode isEqualToString:@"register_devices"]) {
    if (![metalPath isEqualToString:@"/System/Library/Frameworks/Metal.framework/Metal"]) {
      r[@"stage"] = @"unsupported_private_mode_path";
      return r;
    }
    uintptr_t createAddr = (uintptr_t)createDevice;
    uintptr_t unslidCreate = 0x1860c6fd8ULL;
    uintptr_t unslidTarget =
        [mode isEqualToString:@"init_array"] ? 0x1860c6ae8ULL : 0x1860c70acULL;
    uintptr_t targetAddr = createAddr + (unslidTarget - unslidCreate);
    r[@"private_target"] = mode;
    r[@"private_target_addr"] = [NSString stringWithFormat:@"0x%llx",
                                                           (unsigned long long)targetAddr];
    setStage([NSString stringWithFormat:@"%@@0x%llx", mode,
                                        (unsigned long long)targetAddr]);
    ((MTLPrivateVoidFn)targetAddr)();
    r[@"stage"] = @"done";
    return r;
  }

  setStage([NSString stringWithFormat:@"create_default_device@0x%llx",
                                      (unsigned long long)(uintptr_t)
                                          createDevice]);
  id device = createDevice();
  if (!device) {
    r[@"device_available"] = @NO;
    r[@"device_null"] = @YES;
    r[@"stage"] = @"create_default_device";
    return r;
  }

  setStage(@"query_device");
  r[@"device_available"] = @YES;
  if (gAPVTraceLog) {
    @synchronized(gAPVTraceLog) {
      r[@"apv_trace"] = [gAPVTraceLog copy];
    }
    gAPVTraceLog = nil;
  }
  if ([device respondsToSelector:@selector(name)]) {
    typedef NSString *(*StringMsgSend)(id, SEL);
    NSString *name = ((StringMsgSend)objc_msgSend)(device, @selector(name));
    if (name)
      r[@"device_name"] = name;
  }
  if ([device respondsToSelector:@selector(registryID)]) {
    typedef uint64_t (*UInt64MsgSend)(id, SEL);
    uint64_t registryID =
        ((UInt64MsgSend)objc_msgSend)(device, @selector(registryID));
    r[@"registry_id"] = [NSString stringWithFormat:@"%llu",
                                                   (unsigned long long)registryID];
  }
  if ([device respondsToSelector:@selector(hasUnifiedMemory)]) {
    typedef BOOL (*BoolMsgSend)(id, SEL);
    BOOL unified =
        ((BoolMsgSend)objc_msgSend)(device, @selector(hasUnifiedMemory));
    r[@"unified_memory"] = @(unified);
  }

  setStage(@"new_command_queue");
  id queue = nil;
  if ([device respondsToSelector:@selector(newCommandQueue)]) {
    typedef id (*IdMsgSend)(id, SEL);
    queue = ((IdMsgSend)objc_msgSend)(device, @selector(newCommandQueue));
  }
  r[@"command_queue"] = @(queue != nil);
  r[@"stage"] = @"done";

  return r;
}

static NSDictionary *handle_diag_metal(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *metalPath = msg[@"path"];
  if (![metalPath isKindOfClass:[NSString class]] || metalPath.length == 0)
    metalPath = @"/System/Library/Frameworks/Metal.framework/Metal";
  NSSet *allowedPaths = [NSSet setWithArray:@[
    @"/System/Library/Frameworks/Metal.framework/Metal",
    @"/usr/lib/vphone-gpu/Metal372.dylib",
  ]];
  if (![allowedPaths containsObject:metalPath]) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"unsupported Metal path";
    return r;
  }

  NSNumber *timeoutValue = msg[@"timeout"];
  NSTimeInterval timeout = timeoutValue ? timeoutValue.doubleValue : 5.0;
  if (timeout <= 0 || timeout > 15)
    timeout = 5.0;
  BOOL stubNames = [msg[@"stub_names"] boolValue];
  BOOL isolate = msg[@"isolate"] ? [msg[@"isolate"] boolValue] : YES;
  int sampleMs = [msg[@"sample_ms"] intValue];
  if (sampleMs < 0 || sampleMs > 14000)
    sampleMs = 0;
  if (isolate && sampleMs == 0)
    sampleMs = 2500;
  BOOL avoidPrefsDaemon = [msg[@"avoid_prefs_daemon"] boolValue];
  BOOL stubMetalPrefs = [msg[@"stub_metal_prefs"] boolValue];
  NSString *mode = [msg[@"mode"] isKindOfClass:[NSString class]]
                       ? msg[@"mode"]
                       : @"create_default";
  NSSet *allowedModes = [NSSet setWithArray:@[
    @"create_default",
    @"copy_all",
    @"init_array",
    @"register_devices",
  ]];
  if (![allowedModes containsObject:mode])
    mode = @"create_default";

  if (isolate) {
    NSMutableDictionary *r = run_exec_child_probe_capture(
        @"diag_metal", reqId, timeout,
        @[ @"--diag-metal-child",
           metalPath ?: @"",
           mode ?: @"create_default",
           stubNames ? @"1" : @"0",
           [reqId description] ?: @"",
           [NSString stringWithFormat:@"%d", sampleMs],
           avoidPrefsDaemon ? @"1" : @"0",
           stubMetalPrefs ? @"1" : @"0" ]);
    if (!r[@"path"])
      r[@"path"] = metalPath;
    if (!r[@"mode"])
      r[@"mode"] = mode;
    r[@"stub_names"] = @(stubNames);
    r[@"isolated"] = @YES;
    r[@"sample_ms"] = @(sampleMs);
    r[@"avoid_prefs_daemon"] = @(avoidPrefsDaemon);
    r[@"stub_metal_prefs"] = @(stubMetalPrefs);
    return r;
  }

  __block NSDictionary *probeResult = nil;
  __block NSString *stage = @"queued";
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      probeResult = run_diag_metal_probe(reqId, metalPath, mode, stubNames, stubMetalPrefs, ^(NSString *newStage) {
        stage = [newStage copy];
        NSLog(@"vphoned: diag_metal stage=%@", stage);
      });
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    NSMutableDictionary *r = vp_make_response(@"diag_metal", reqId);
    r[@"timed_out"] = @YES;
    r[@"stage"] = stage ?: @"unknown";
    r[@"path"] = metalPath;
    r[@"mode"] = mode;
    r[@"stub_names"] = @(stubNames);
    r[@"isolated"] = @NO;
    r[@"sample_ms"] = @(sampleMs);
    r[@"avoid_prefs_daemon"] = @(avoidPrefsDaemon);
    r[@"stub_metal_prefs"] = @(stubMetalPrefs);
    NSMutableArray *trace = gAPVTraceLog;
    if (trace) {
      @synchronized(trace) {
        r[@"apv_trace"] = [trace copy];
      }
    }
    return r;
  }

  NSMutableDictionary *r = [probeResult mutableCopy] ?: vp_make_response(@"diag_metal", reqId);
  r[@"timed_out"] = @NO;
  r[@"isolated"] = @NO;
  r[@"sample_ms"] = @(sampleMs);
  r[@"avoid_prefs_daemon"] = @(avoidPrefsDaemon);
  r[@"stub_metal_prefs"] = @(stubMetalPrefs);
  return r;
}

static int run_diag_metal_child_main(int argc, char *argv[]) {
  @autoreleasepool {
    NSString *metalPath =
        argc > 2 ? [NSString stringWithUTF8String:argv[2] ?: ""] : @"";
    if (metalPath.length == 0)
      metalPath = @"/System/Library/Frameworks/Metal.framework/Metal";

    NSString *mode =
        argc > 3 ? [NSString stringWithUTF8String:argv[3] ?: ""] : @"";
    if (mode.length == 0)
      mode = @"create_default";

    BOOL stubNames = argc > 4 && strcmp(argv[4], "1") == 0;
    NSString *reqId =
        argc > 5 ? [NSString stringWithUTF8String:argv[5] ?: ""] : @"child";
    int sampleMs = argc > 6 ? atoi(argv[6]) : 0;
    BOOL avoidPrefsDaemon = argc > 7 && strcmp(argv[7], "1") == 0;
    BOOL stubMetalPrefs = argc > 8 && strcmp(argv[8], "1") == 0;
    if (avoidPrefsDaemon) {
      setenv("CFPREFERENCES_AVOID_DAEMON", "1", 1);
      setenv("CFFIXED_USER_HOME", "/var/root", 0);
    }
    if (stubMetalPrefs) {
      setenv("VPHONED_STUB_METAL_PREFS", "1", 1);
      vp_patch_metal_preference_functions();
    }
    vp_start_thread_sampler(STDOUT_FILENO, sampleMs);

    __block NSString *stage = @"child_start";
    NSDictionary *result = run_diag_metal_probe(
        reqId, metalPath, mode, stubNames, stubMetalPrefs, ^(NSString *newStage) {
          stage = [newStage copy] ?: @"";
          vp_write_child_probe_event(STDOUT_FILENO, @{
            @"kind" : @"stage",
            @"stage" : stage
          });
        });
    vp_write_child_probe_event(STDOUT_FILENO, @{
      @"kind" : @"result",
      @"stage" : stage ?: @"",
      @"result" : result ?: @{}
    });
  }
  return 0;
}

static NSDictionary *handle_diag_iokit(NSDictionary *msg) {
  NSMutableDictionary *r = vp_make_response(@"diag_iokit", msg[@"id"]);
  NSArray *requested = [msg[@"classes"] isKindOfClass:[NSArray class]]
                           ? msg[@"classes"]
                           : nil;
  NSArray *classes = requested ?: @[
    @"AppleParavirtGPU",
    @"AppleParavirtGPUMetalIOGPUFamily",
    @"IOGPUDevice",
    @"IOGPU",
    @"IOAccelerator",
    @"IOAccelerator2D",
    @"AGXAccelerator",
    @"AGXDevice",
    @"IOMobileFramebuffer",
    @"IOMobileFramebufferService",
    @"IOFramebuffer",
    @"AppleCLCD"
  ];

  NSMutableArray *items = [NSMutableArray arrayWithCapacity:classes.count];
  for (id item in classes) {
    if (![item isKindOfClass:[NSString class]])
      continue;
    NSString *className = (NSString *)item;
    CFMutableDictionaryRef matching =
        IOServiceMatching(className.UTF8String);
    if (!matching) {
      [items addObject:@{ @"class" : className, @"matching" : @NO }];
      continue;
    }

    io_iterator_t iter = IO_OBJECT_NULL;
    kern_return_t kr =
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter);
    if (kr != KERN_SUCCESS) {
      [items addObject:@{
        @"class" : className,
        @"matching" : @YES,
        @"kr" : @(kr)
      }];
      continue;
    }

    NSMutableArray *samples = [NSMutableArray array];
    uint32_t count = 0;
    io_object_t obj;
    while ((obj = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
      count++;
      if (samples.count < 5) {
        char name[256] = {0};
        char klass[256] = {0};
        char path[1024] = {0};
        IORegistryEntryGetName(obj, name);
        IOObjectGetClass(obj, klass);
        IORegistryEntryGetPath(obj, kIOServicePlane, path);
        [samples addObject:@{
          @"name" : [NSString stringWithUTF8String:name] ?: @"",
          @"class" : [NSString stringWithUTF8String:klass] ?: @"",
          @"path" : [NSString stringWithUTF8String:path] ?: @""
        }];
      }
      IOObjectRelease(obj);
    }
    IOObjectRelease(iter);

    [items addObject:@{
      @"class" : className,
      @"count" : @(count),
      @"samples" : samples
    }];
  }

  r[@"items"] = items;
  return r;
}

static NSString *hex_string_for_data(NSData *data, NSUInteger maxBytes) {
  const uint8_t *bytes = data.bytes;
  NSUInteger count = MIN(data.length, maxBytes);
  NSMutableString *hex = [NSMutableString stringWithCapacity:count * 2];
  for (NSUInteger i = 0; i < count; i++)
    [hex appendFormat:@"%02x", bytes[i]];
  return hex;
}

static id plist_safe_value(id value, NSUInteger depth) {
  if (!value || depth > 3)
    return value ? [value description] : @"";

  if ([value isKindOfClass:[NSString class]] ||
      [value isKindOfClass:[NSNumber class]])
    return value;

  if ([value isKindOfClass:[NSData class]]) {
    NSData *data = (NSData *)value;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"type"] = @"data";
    d[@"length"] = @(data.length);
    d[@"hex"] = hex_string_for_data(data, 64);
    if (data.length > 64)
      d[@"truncated"] = @YES;
    return d;
  }

  if ([value isKindOfClass:[NSArray class]]) {
    NSMutableArray *a = [NSMutableArray array];
    NSUInteger count = 0;
    for (id item in (NSArray *)value) {
      if (count++ >= 32) {
        [a addObject:@"<truncated>"];
        break;
      }
      [a addObject:plist_safe_value(item, depth + 1) ?: @""];
    }
    return a;
  }

  if ([value isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSArray *keys = [[(NSDictionary *)value allKeys]
        sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
          return [[a description] compare:[b description]];
        }];
    NSUInteger count = 0;
    for (id key in keys) {
      if (count++ >= 48) {
        d[@"<truncated>"] = @YES;
        break;
      }
      NSString *k = [key description] ?: @"";
      d[k] = plist_safe_value([(NSDictionary *)value objectForKey:key],
                              depth + 1) ?: @"";
    }
    return d;
  }

  return [value description] ?: @"";
}

static NSDictionary *handle_diag_iokit_props(NSDictionary *msg) {
  NSMutableDictionary *r = vp_make_response(@"diag_iokit_props", msg[@"id"]);
  NSArray *requested = [msg[@"classes"] isKindOfClass:[NSArray class]]
                           ? msg[@"classes"]
                           : nil;
  NSArray *classes = requested ?: @[
    @"AppleParavirtGPU",
    @"IOMobileFramebuffer",
    @"IOMobileFramebufferService",
    @"IOGPUDevice",
    @"IOGPU",
    @"IOFramebuffer",
  ];

  int maxObjects = [msg[@"max_objects"] intValue];
  if (maxObjects <= 0 || maxObjects > 8)
    maxObjects = 3;

  NSMutableArray *items = [NSMutableArray arrayWithCapacity:classes.count];
  for (id item in classes) {
    if (![item isKindOfClass:[NSString class]])
      continue;
    NSString *className = (NSString *)item;
    CFMutableDictionaryRef matching = IOServiceMatching(className.UTF8String);
    if (!matching) {
      [items addObject:@{ @"class" : className, @"matching" : @NO }];
      continue;
    }

    io_iterator_t iter = IO_OBJECT_NULL;
    kern_return_t kr =
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter);
    if (kr != KERN_SUCCESS) {
      [items addObject:@{
        @"class" : className,
        @"matching" : @YES,
        @"kr" : @(kr)
      }];
      continue;
    }

    NSMutableArray *samples = [NSMutableArray array];
    uint32_t count = 0;
    io_object_t obj;
    while ((obj = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
      count++;
      if (samples.count < (NSUInteger)maxObjects) {
        char name[256] = {0};
        char klass[256] = {0};
        char path[1024] = {0};
        IORegistryEntryGetName(obj, name);
        IOObjectGetClass(obj, klass);
        IORegistryEntryGetPath(obj, kIOServicePlane, path);

        NSMutableDictionary *sample = [NSMutableDictionary dictionary];
        sample[@"name"] = [NSString stringWithUTF8String:name] ?: @"";
        sample[@"class"] = [NSString stringWithUTF8String:klass] ?: @"";
        sample[@"path"] = [NSString stringWithUTF8String:path] ?: @"";

        CFMutableDictionaryRef props = NULL;
        kern_return_t propKr =
            IORegistryEntryCreateCFProperties(obj, &props, kCFAllocatorDefault, 0);
        sample[@"properties_kr"] = @(propKr);
        if (propKr == KERN_SUCCESS && props) {
          NSDictionary *dict = CFBridgingRelease(props);
          sample[@"properties"] = plist_safe_value(dict, 0) ?: @{};
        }

        [samples addObject:sample];
      }
      IOObjectRelease(obj);
    }
    IOObjectRelease(iter);

    [items addObject:@{
      @"class" : className,
      @"count" : @(count),
      @"samples" : samples
    }];
  }

  r[@"items"] = items;
  return r;
}

static NSDictionary *run_diag_iokit_open_probe(id reqId, NSString *className,
                                               uint32_t userClientType) {
  NSMutableDictionary *r = vp_make_response(@"diag_iokit_open", reqId);
  r[@"class"] = className;
  r[@"user_client_type"] = @(userClientType);

  CFMutableDictionaryRef matching = IOServiceMatching(className.UTF8String);
  if (!matching) {
    r[@"matching"] = @NO;
    return r;
  }

  io_service_t service =
      IOServiceGetMatchingService(kIOMainPortDefault, matching);
  if (service == IO_OBJECT_NULL) {
    r[@"service_found"] = @NO;
    return r;
  }
  r[@"service_found"] = @YES;

  char name[256] = {0};
  char klass[256] = {0};
  char path[1024] = {0};
  IORegistryEntryGetName(service, name);
  IOObjectGetClass(service, klass);
  IORegistryEntryGetPath(service, kIOServicePlane, path);
  r[@"service_name"] = [NSString stringWithUTF8String:name] ?: @"";
  r[@"service_class"] = [NSString stringWithUTF8String:klass] ?: @"";
  r[@"service_path"] = [NSString stringWithUTF8String:path] ?: @"";

  io_connect_t connect = IO_OBJECT_NULL;
  kern_return_t kr =
      IOServiceOpen(service, mach_task_self(), userClientType, &connect);
  r[@"open_kr"] = @(kr);
  if (connect != IO_OBJECT_NULL) {
    r[@"connect"] = @YES;
    IOServiceClose(connect);
  } else {
    r[@"connect"] = @NO;
  }
  IOObjectRelease(service);
  return r;
}

static NSDictionary *handle_diag_iokit_open(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *className = msg[@"class"];
  NSSet *allowedClasses = [NSSet setWithArray:@[
    @"AppleParavirtGPU",
    @"IOGPU",
    @"IOMobileFramebuffer",
    @"IOMobileFramebufferService",
  ]];
  if (![className isKindOfClass:[NSString class]] ||
      ![allowedClasses containsObject:className]) {
    className = @"AppleParavirtGPU";
  }

  int typeValue = [msg[@"user_client_type"] intValue];
  if (typeValue < 0 || typeValue > 32)
    typeValue = 0;
  uint32_t userClientType = (uint32_t)typeValue;

  NSNumber *timeoutValue = msg[@"timeout"];
  NSTimeInterval timeout = timeoutValue ? timeoutValue.doubleValue : 3.0;
  if (timeout <= 0 || timeout > 10)
    timeout = 3.0;

  __block NSDictionary *probeResult = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      probeResult =
          run_diag_iokit_open_probe(reqId, className, userClientType);
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    NSMutableDictionary *r = vp_make_response(@"diag_iokit_open", reqId);
    r[@"class"] = className;
    r[@"user_client_type"] = @(userClientType);
    r[@"timed_out"] = @YES;
    return r;
  }

  NSMutableDictionary *r = [probeResult mutableCopy] ?: vp_make_response(@"diag_iokit_open", reqId);
  r[@"timed_out"] = @NO;
  return r;
}

static NSDictionary *run_diag_iogpu_device_probe(id reqId, NSString *className,
                                                 uint32_t options) {
  NSMutableDictionary *r = vp_make_response(@"diag_iogpu_device", reqId);
  r[@"class"] = className;
  r[@"options"] = @(options);

  void *iogs = dlopen("/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU",
                      RTLD_LAZY | RTLD_LOCAL);
  if (!iogs) {
    r[@"iogs_loaded"] = @NO;
    r[@"dlerror"] = [NSString stringWithUTF8String:dlerror() ?: "unknown"];
    return r;
  }
  r[@"iogs_loaded"] = @YES;

  typedef void *(*CreateWithOptionsFn)(io_service_t, uint32_t);
  typedef void (*ReleaseFn)(void *);
  typedef io_connect_t (*GetConnectFn)(void *);
  typedef kern_return_t (*GetConfigFn)(void *, uint32_t *, uint32_t *,
                                      uint32_t *, uint32_t *, uint32_t *);

  dlerror();
  CreateWithOptionsFn create =
      (CreateWithOptionsFn)dlsym(iogs, "IOGPUDeviceCreateWithOptions");
  ReleaseFn release = (ReleaseFn)dlsym(iogs, "IOGPUDeviceRelease");
  GetConnectFn getConnect = (GetConnectFn)dlsym(iogs, "IOGPUDeviceGetConnect");
  GetConfigFn getConfig = (GetConfigFn)dlsym(iogs, "IOGPUDeviceGetConfig");
  if (!create) {
    r[@"symbol_found"] = @NO;
    r[@"dlsym_error"] = [NSString stringWithUTF8String:dlerror() ?: "unknown"];
    return r;
  }
  r[@"symbol_found"] = @YES;

  CFMutableDictionaryRef matching = IOServiceMatching(className.UTF8String);
  if (!matching) {
    r[@"matching"] = @NO;
    return r;
  }

  io_service_t service =
      IOServiceGetMatchingService(kIOMainPortDefault, matching);
  if (service == IO_OBJECT_NULL) {
    r[@"service_found"] = @NO;
    return r;
  }
  r[@"service_found"] = @YES;

  char name[256] = {0};
  char klass[256] = {0};
  char path[1024] = {0};
  IORegistryEntryGetName(service, name);
  IOObjectGetClass(service, klass);
  IORegistryEntryGetPath(service, kIOServicePlane, path);
  r[@"service_name"] = [NSString stringWithUTF8String:name] ?: @"";
  r[@"service_class"] = [NSString stringWithUTF8String:klass] ?: @"";
  r[@"service_path"] = [NSString stringWithUTF8String:path] ?: @"";

  void *device = create(service, options);
  IOObjectRelease(service);
  r[@"device"] = @(device != NULL);
  if (!device)
    return r;

  if (getConnect) {
    io_connect_t connect = getConnect(device);
    r[@"connect"] = @(connect != IO_OBJECT_NULL);
    r[@"connect_port"] = @(connect);
  }

  if (getConfig) {
    uint32_t a = 0, b = 0, c = 0, d = 0, e = 0;
    kern_return_t kr = getConfig(device, &a, &b, &c, &d, &e);
    r[@"config_kr"] = @(kr);
    r[@"config"] = @[ @(a), @(b), @(c), @(d), @(e) ];
  }

  if (release)
    release(device);
  return r;
}

static NSDictionary *handle_diag_iogpu_device(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *className = msg[@"class"];
  NSSet *allowedClasses =
      [NSSet setWithArray:@[ @"AppleParavirtGPU", @"IOGPU" ]];
  if (![className isKindOfClass:[NSString class]] ||
      ![allowedClasses containsObject:className]) {
    className = @"AppleParavirtGPU";
  }

  int optionsValue = [msg[@"options"] intValue];
  if (optionsValue < 0 || optionsValue > 0xffff)
    optionsValue = 0;
  uint32_t options = (uint32_t)optionsValue;

  NSNumber *timeoutValue = msg[@"timeout"];
  NSTimeInterval timeout = timeoutValue ? timeoutValue.doubleValue : 5.0;
  if (timeout <= 0 || timeout > 15)
    timeout = 5.0;

  __block NSDictionary *probeResult = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      probeResult = run_diag_iogpu_device_probe(reqId, className, options);
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    NSMutableDictionary *r = vp_make_response(@"diag_iogpu_device", reqId);
    r[@"class"] = className;
    r[@"options"] = @(options);
    r[@"timed_out"] = @YES;
    return r;
  }

  NSMutableDictionary *r = [probeResult mutableCopy] ?: vp_make_response(@"diag_iogpu_device", reqId);
  r[@"timed_out"] = @NO;
  return r;
}

static void add_iogpu_super_step(NSMutableArray *steps, NSDictionary *step) {
  @synchronized(steps) {
    [steps addObject:step ?: @{}];
  }
}

static NSDictionary *run_diag_iogpu_super_probe(id reqId, uint32_t options,
                                                NSMutableArray *steps,
                                                void (^setStage)(NSString *)) {
  NSMutableDictionary *r = vp_make_response(@"diag_iogpu_super", reqId);
  r[@"options"] = @(options);
  uint32_t userClientType = 1 | (options << 16);
  r[@"user_client_type"] = @(userClientType);

  setStage(@"service_lookup");
  io_service_t service =
      IOServiceGetMatchingService(kIOMainPortDefault,
                                  IOServiceMatching("AppleParavirtGPU"));
  if (service == IO_OBJECT_NULL) {
    r[@"stage"] = @"service_lookup";
    r[@"service_found"] = @NO;
    return r;
  }
  r[@"service_found"] = @YES;
  r[@"service_port"] = @(service);

  setStage(@"IOServiceOpen");
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOServiceOpen",
    @"user_client_type" : @(userClientType)
  });
  io_connect_t connect = IO_OBJECT_NULL;
  kern_return_t kr =
      IOServiceOpen(service, mach_task_self(), userClientType, &connect);
  r[@"open_kr"] = @(kr);
  r[@"connect"] = @(connect != IO_OBJECT_NULL);
  r[@"connect_port"] = @(connect);
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOServiceOpen:return",
    @"kr" : @(kr),
    @"connect" : @(connect != IO_OBJECT_NULL),
    @"connect_port" : @(connect)
  });
  IOObjectRelease(service);
  if (kr != KERN_SUCCESS || connect == IO_OBJECT_NULL) {
    r[@"stage"] = @"IOServiceOpen";
    return r;
  }

  NSArray<NSNumber *> *selectors = @[ @2, @0, @4 ];
  NSMutableArray *calls = [NSMutableArray arrayWithCapacity:selectors.count];
  for (NSNumber *selectorNumber in selectors) {
    uint32_t selector = selectorNumber.unsignedIntValue;
    NSString *stage = [NSString stringWithFormat:@"IOConnectCallStructMethod_%u",
                                                 selector];
    setStage(stage);

    uint8_t out[0x300] = {0};
    size_t outSize = selector == 2 ? 0x218 : (selector == 0 ? 0x40 : 0x20);
    size_t requestedSize = outSize;
    add_iogpu_super_step(steps, @{
      @"stage" : stage,
      @"selector" : @(selector),
      @"requested_size" : @(requestedSize)
    });
    kern_return_t callKr =
        IOConnectCallStructMethod(connect, selector, NULL, 0, out, &outSize);

    NSData *sample = [NSData dataWithBytes:out
                                    length:MIN((NSUInteger)outSize,
                                               (NSUInteger)64)];
    NSDictionary *call = @{
      @"selector" : @(selector),
      @"kr" : @(callKr),
      @"requested_size" : @(requestedSize),
      @"out_size" : @(outSize),
      @"sample" : hex_string_for_data(sample, 64) ?: @""
    };
    [calls addObject:call];
    add_iogpu_super_step(steps, @{
      @"stage" : [stage stringByAppendingString:@":return"],
      @"selector" : @(selector),
      @"kr" : @(callKr),
      @"out_size" : @(outSize)
    });

    if (callKr != KERN_SUCCESS)
      break;
  }

  setStage(@"IOServiceClose");
  IOServiceClose(connect);
  r[@"calls"] = calls;
  r[@"stage"] = @"done";
  return r;
}

static NSDictionary *handle_diag_iogpu_super(NSDictionary *msg) {
  id reqId = msg[@"id"];
  int optionsValue = [msg[@"options"] intValue];
  if (optionsValue < 0 || optionsValue > 0xffff)
    optionsValue = 0;
  uint32_t options = (uint32_t)optionsValue;

  NSNumber *timeoutValue = msg[@"timeout"];
  NSTimeInterval timeout = timeoutValue ? timeoutValue.doubleValue : 5.0;
  if (timeout <= 0 || timeout > 9)
    timeout = 5.0;

  __block NSDictionary *probeResult = nil;
  __block NSString *stage = @"start";
  NSMutableArray *steps = [NSMutableArray array];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      probeResult = run_diag_iogpu_super_probe(
          reqId, options, steps, ^(NSString *newStage) {
            stage = [newStage copy];
            NSLog(@"vphoned: diag_iogpu_super stage=%@", stage);
          });
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    NSMutableDictionary *r = vp_make_response(@"diag_iogpu_super", reqId);
    r[@"options"] = @(options);
    r[@"stage"] = stage ?: @"";
    r[@"timed_out"] = @YES;
    @synchronized(steps) {
      r[@"steps"] = [steps copy];
    }
    return r;
  }

  NSMutableDictionary *r = [probeResult mutableCopy] ?: vp_make_response(@"diag_iogpu_super", reqId);
  r[@"timed_out"] = @NO;
  @synchronized(steps) {
    r[@"steps"] = [steps copy];
  }
  return r;
}

static NSDictionary *run_diag_iogpu_queue_call_probe(id reqId, NSMutableArray *steps,
                                                     void (^setStage)(NSString *)) {
  NSMutableDictionary *r = vp_make_response(@"diag_iogpu_queue_call", reqId);

  setStage(@"service_lookup");
  io_service_t service =
      IOServiceGetMatchingService(kIOMainPortDefault,
                                  IOServiceMatching("AppleParavirtGPU"));
  if (service == IO_OBJECT_NULL) {
    r[@"stage"] = @"service_lookup";
    r[@"service_found"] = @NO;
    return r;
  }
  r[@"service_found"] = @YES;
  r[@"service_port"] = @(service);

  setStage(@"IOServiceOpen");
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOServiceOpen",
    @"user_client_type" : @1
  });
  io_connect_t connect = IO_OBJECT_NULL;
  kern_return_t kr = IOServiceOpen(service, mach_task_self(), 1, &connect);
  IOObjectRelease(service);
  r[@"open_kr"] = @(kr);
  r[@"connect"] = @(connect != IO_OBJECT_NULL);
  r[@"connect_port"] = @(connect);
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOServiceOpen:return",
    @"kr" : @(kr),
    @"connect" : @(connect != IO_OBJECT_NULL),
    @"connect_port" : @(connect)
  });
  if (kr != KERN_SUCCESS || connect == IO_OBJECT_NULL) {
    r[@"stage"] = @"IOServiceOpen";
    return r;
  }

  NSArray<NSNumber *> *setupSelectors = @[ @2, @0, @4 ];
  NSMutableArray *calls = [NSMutableArray array];
  for (NSNumber *selectorNumber in setupSelectors) {
    uint32_t selector = selectorNumber.unsignedIntValue;
    NSString *stage = [NSString stringWithFormat:@"IOConnectCallStructMethod_%u",
                                                 selector];
    setStage(stage);

    uint8_t out[0x300] = {0};
    size_t outSize = selector == 2 ? 0x218 : (selector == 0 ? 0x40 : 0x20);
    add_iogpu_super_step(steps, @{
      @"stage" : stage,
      @"selector" : @(selector),
      @"requested_size" : @(outSize)
    });
    kern_return_t callKr =
        IOConnectCallStructMethod(connect, selector, NULL, 0, out, &outSize);
    [calls addObject:@{ @"selector" : @(selector),
                        @"kr" : @(callKr),
                        @"out_size" : @(outSize) }];
    add_iogpu_super_step(steps, @{
      @"stage" : [stage stringByAppendingString:@":return"],
      @"selector" : @(selector),
      @"kr" : @(callKr),
      @"out_size" : @(outSize)
    });
    if (callKr != KERN_SUCCESS) {
      IOServiceClose(connect);
      r[@"calls"] = calls;
      r[@"stage"] = stage;
      return r;
    }
  }

  setStage(@"IOConnectCallMethod_6");
  uint8_t args[0x408] = {0};
  uint64_t queueOut[2] = {0, 0};
  size_t queueOutSize = sizeof(queueOut);
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOConnectCallMethod_6",
    @"selector" : @6,
    @"input_struct_size" : @(sizeof(args)),
    @"output_struct_size" : @(queueOutSize)
  });
  kern_return_t queueKr =
      IOConnectCallMethod(connect, 6, NULL, 0, args, sizeof(args), NULL, NULL,
                          queueOut, &queueOutSize);
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOConnectCallMethod_6:return",
    @"selector" : @6,
    @"kr" : @(queueKr),
    @"output_struct_size" : @(queueOutSize)
  });

  IOServiceClose(connect);
  r[@"calls"] = calls;
  r[@"queue_kr"] = @(queueKr);
  r[@"queue_out_size"] = @(queueOutSize);
  r[@"queue_out0"] = @(queueOut[0]);
  r[@"queue_out1"] = @(queueOut[1]);
  r[@"stage"] = @"done";
  return r;
}

static NSDictionary *handle_diag_iogpu_queue_call(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSNumber *timeoutValue = msg[@"timeout"];
  NSTimeInterval timeout = timeoutValue ? timeoutValue.doubleValue : 5.0;
  if (timeout <= 0 || timeout > 12)
    timeout = 5.0;

  __block NSDictionary *probeResult = nil;
  __block NSString *stage = @"start";
  NSMutableArray *steps = [NSMutableArray array];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      probeResult = run_diag_iogpu_queue_call_probe(
          reqId, steps, ^(NSString *newStage) {
            stage = [newStage copy];
            NSLog(@"vphoned: diag_iogpu_queue_call stage=%@", stage);
          });
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    NSMutableDictionary *r = vp_make_response(@"diag_iogpu_queue_call", reqId);
    r[@"stage"] = stage ?: @"";
    r[@"timed_out"] = @YES;
    @synchronized(steps) {
      r[@"steps"] = [steps copy];
    }
    return r;
  }

  NSMutableDictionary *r = [probeResult mutableCopy] ?: vp_make_response(@"diag_iogpu_queue_call", reqId);
  r[@"timed_out"] = @NO;
  @synchronized(steps) {
    r[@"steps"] = [steps copy];
  }
  return r;
}

static NSDictionary *run_diag_iogpu_queue_api_probe(id reqId,
                                                    NSMutableArray *steps,
                                                    void (^setStage)(NSString *)) {
  NSMutableDictionary *r = vp_make_response(@"diag_iogpu_queue_api", reqId);

  setStage(@"dlopen_iogpu");
  void *iogs = dlopen("/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU",
                      RTLD_LAZY | RTLD_LOCAL);
  if (!iogs) {
    r[@"stage"] = @"dlopen_iogpu";
    r[@"iogs_loaded"] = @NO;
    r[@"dlerror"] = [NSString stringWithUTF8String:dlerror() ?: "unknown"];
    return r;
  }
  r[@"iogs_loaded"] = @YES;

  typedef void *(*CreateWithOptionsFn)(io_service_t, uint32_t);
  typedef void (*ReleaseFn)(void *);
  typedef io_connect_t (*GetConnectFn)(void *);
  typedef void *(*CommandQueueCreateFn)(void *, void *, size_t);
  typedef uint64_t (*CommandQueueGetIDFn)(void *);
  typedef void *(*NotificationQueueCreateFn)(void *, uint32_t, uint32_t);
  typedef uint64_t (*NotificationQueueGetIDFn)(void *);

  setStage(@"dlsym_iogpu");
  CreateWithOptionsFn create =
      (CreateWithOptionsFn)dlsym(iogs, "IOGPUDeviceCreateWithOptions");
  ReleaseFn deviceRelease = (ReleaseFn)dlsym(iogs, "IOGPUDeviceRelease");
  GetConnectFn getConnect = (GetConnectFn)dlsym(iogs, "IOGPUDeviceGetConnect");
  CommandQueueCreateFn queueCreate =
      (CommandQueueCreateFn)dlsym(iogs, "IOGPUCommandQueueCreate");
  CommandQueueGetIDFn queueGetID =
      (CommandQueueGetIDFn)dlsym(iogs, "IOGPUCommandQueueGetID");
  ReleaseFn queueRelease = (ReleaseFn)dlsym(iogs, "IOGPUCommandQueueRelease");
  NotificationQueueCreateFn noteCreate =
      (NotificationQueueCreateFn)dlsym(iogs, "IOGPUNotificationQueueCreate");
  NotificationQueueGetIDFn noteGetID =
      (NotificationQueueGetIDFn)dlsym(iogs, "IOGPUNotificationQueueGetID");
  ReleaseFn noteRelease =
      (ReleaseFn)dlsym(iogs, "IOGPUNotificationQueueRelease");
  r[@"symbols"] = @{
    @"device_create" : @(create != NULL),
    @"device_release" : @(deviceRelease != NULL),
    @"get_connect" : @(getConnect != NULL),
    @"queue_create" : @(queueCreate != NULL),
    @"queue_get_id" : @(queueGetID != NULL),
    @"queue_release" : @(queueRelease != NULL),
    @"notification_create" : @(noteCreate != NULL),
    @"notification_get_id" : @(noteGetID != NULL),
    @"notification_release" : @(noteRelease != NULL)
  };
  if (!create || !getConnect || !queueCreate || !queueGetID || !noteCreate ||
      !noteGetID) {
    r[@"stage"] = @"dlsym_iogpu";
    return r;
  }

  setStage(@"service_lookup");
  io_service_t service =
      IOServiceGetMatchingService(kIOMainPortDefault,
                                  IOServiceMatching("AppleParavirtGPU"));
  if (service == IO_OBJECT_NULL) {
    r[@"stage"] = @"service_lookup";
    r[@"service_found"] = @NO;
    return r;
  }
  r[@"service_found"] = @YES;
  r[@"service_port"] = @(service);

  setStage(@"IOGPUDeviceCreateWithOptions");
  add_iogpu_super_step(steps, @{ @"stage" : @"IOGPUDeviceCreateWithOptions" });
  void *device = create(service, 0);
  IOObjectRelease(service);
  r[@"device"] = @(device != NULL);
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOGPUDeviceCreateWithOptions:return",
    @"device" : @(device != NULL),
    @"device_ptr" : [NSString stringWithFormat:@"%p", device]
  });
  if (!device) {
    r[@"stage"] = @"IOGPUDeviceCreateWithOptions";
    return r;
  }

  io_connect_t connect = getConnect(device);
  r[@"connect"] = @(connect != IO_OBJECT_NULL);
  r[@"connect_port"] = @(connect);

  uint8_t args[0x408] = {0};
  setStage(@"IOGPUCommandQueueCreate");
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOGPUCommandQueueCreate",
    @"args_size" : @(sizeof(args))
  });
  void *queue = queueCreate(device, args, sizeof(args));
  r[@"queue"] = @(queue != NULL);
  r[@"queue_ptr"] = [NSString stringWithFormat:@"%p", queue];
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOGPUCommandQueueCreate:return",
    @"queue" : @(queue != NULL),
    @"queue_ptr" : [NSString stringWithFormat:@"%p", queue]
  });
  if (!queue) {
    if (deviceRelease)
      deviceRelease(device);
    r[@"stage"] = @"IOGPUCommandQueueCreate";
    return r;
  }

  setStage(@"IOGPUCommandQueueGetID");
  uint64_t queueID = queueGetID(queue);
  r[@"queue_id"] = @(queueID);
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOGPUCommandQueueGetID:return",
    @"queue_id" : @(queueID)
  });

  setStage(@"IOGPUNotificationQueueCreate");
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOGPUNotificationQueueCreate",
    @"entry_count" : @0x100,
    @"entry_size" : @0x28
  });
  void *notification = noteCreate(device, 0x100, 0x28);
  r[@"notification"] = @(notification != NULL);
  r[@"notification_ptr"] = [NSString stringWithFormat:@"%p", notification];
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOGPUNotificationQueueCreate:return",
    @"notification" : @(notification != NULL),
    @"notification_ptr" : [NSString stringWithFormat:@"%p", notification]
  });
  if (!notification) {
    if (queueRelease)
      queueRelease(queue);
    if (deviceRelease)
      deviceRelease(device);
    r[@"stage"] = @"IOGPUNotificationQueueCreate";
    return r;
  }

  setStage(@"IOGPUNotificationQueueGetID");
  uint64_t notificationID = noteGetID(notification);
  r[@"notification_id"] = @(notificationID);
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOGPUNotificationQueueGetID:return",
    @"notification_id" : @(notificationID)
  });

  setStage(@"IOConnectCallMethod_24");
  uint64_t inputScalars[2] = { queueID, notificationID };
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOConnectCallMethod_24",
    @"selector" : @24,
    @"queue_id" : @(queueID),
    @"notification_id" : @(notificationID)
  });
  kern_return_t kr =
      IOConnectCallMethod(connect, 24, inputScalars, 2, NULL, 0, NULL, NULL,
                          NULL, NULL);
  r[@"register_kr"] = @(kr);
  add_iogpu_super_step(steps, @{
    @"stage" : @"IOConnectCallMethod_24:return",
    @"selector" : @24,
    @"kr" : @(kr)
  });

  if (noteRelease)
    noteRelease(notification);
  if (queueRelease)
    queueRelease(queue);
  if (deviceRelease)
    deviceRelease(device);
  r[@"stage"] = @"done";
  return r;
}

static NSDictionary *handle_diag_iogpu_queue_api(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSNumber *timeoutValue = msg[@"timeout"];
  NSTimeInterval timeout = timeoutValue ? timeoutValue.doubleValue : 6.0;
  if (timeout <= 0 || timeout > 15)
    timeout = 6.0;

  __block NSDictionary *probeResult = nil;
  __block NSString *stage = @"start";
  NSMutableArray *steps = [NSMutableArray array];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      probeResult = run_diag_iogpu_queue_api_probe(
          reqId, steps, ^(NSString *newStage) {
            stage = [newStage copy];
            NSLog(@"vphoned: diag_iogpu_queue_api stage=%@", stage);
          });
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    NSMutableDictionary *r = vp_make_response(@"diag_iogpu_queue_api", reqId);
    r[@"stage"] = stage ?: @"";
    r[@"timed_out"] = @YES;
    @synchronized(steps) {
      r[@"steps"] = [steps copy];
    }
    return r;
  }

  NSMutableDictionary *r = [probeResult mutableCopy] ?: vp_make_response(@"diag_iogpu_queue_api", reqId);
  r[@"timed_out"] = @NO;
  @synchronized(steps) {
    r[@"steps"] = [steps copy];
  }
  return r;
}

static void add_string_selector_result(NSMutableDictionary *r, id obj,
                                       NSString *key, SEL sel) {
  if (![obj respondsToSelector:sel])
    return;
  typedef id (*ObjMsgSend)(id, SEL);
  id value = ((ObjMsgSend)objc_msgSend)(obj, sel);
  if (value)
    r[key] = [value description] ?: @"";
}

static void add_bool_selector_result(NSMutableDictionary *r, id obj,
                                     NSString *key, SEL sel) {
  if (![obj respondsToSelector:sel])
    return;
  typedef BOOL (*BoolMsgSend)(id, SEL);
  BOOL value = ((BoolMsgSend)objc_msgSend)(obj, sel);
  r[key] = @(value);
}

static NSDictionary *run_diag_bundle_probe(id reqId, NSString *bundlePath);

typedef BOOL (*APVBoolMethodIMP)(id, SEL);
typedef void (*APVVoidMethodIMP)(id, SEL);
typedef id (*APVInitWithPortIMP)(id, SEL, io_connect_t);
typedef id (*APVCommandQueueInitIMP)(id, SEL, id, id);
typedef id (*APVCommandQueueArgsInitIMP)(id, SEL, id, id, void *, size_t);
typedef id (*APVCommandQueueInfoInitIMP)(id, SEL, id, id, BOOL);

static BOOL gAPVDisableInfoQueue = NO;
static const char *gAPVProbeStage = "idle";
static APVInitWithPortIMP gAPVDeviceInitOrig = NULL;
static APVInitWithPortIMP gIOGPUMetalDeviceInitOrig = NULL;
static APVCommandQueueInitIMP gIOGPUMetalCommandQueueInitOrig = NULL;
static APVCommandQueueArgsInitIMP gIOGPUMetalCommandQueueArgsInitOrig = NULL;
static APVCommandQueueInitIMP gAppleParavirtCommandQueueInitOrig = NULL;
static APVCommandQueueInfoInitIMP gAppleParavirtCommandQueueInfoInitOrig =
    NULL;
static APVBoolMethodIMP gAPVSetupCompilerOrig = NULL;
static APVBoolMethodIMP gAPVSetupDirtyRingOrig = NULL;
static APVVoidMethodIMP gAPVSetupDeviceInfoOrig = NULL;
static APVVoidMethodIMP gAPVSetupDeviceArchInfoOrig = NULL;
static APVVoidMethodIMP gAPVSetupResourcePoolsOrig = NULL;
static APVVoidMethodIMP gAPVSetupSerializerFeaturesOrig = NULL;
static APVVoidMethodIMP gAPVSetupSupportedHostGPUFamiliesOrig = NULL;

static void apv_trace_add(NSString *method, NSString *phase, id value) {
  NSMutableArray *log = gAPVTraceLog;
  if (!log)
    return;

  NSMutableDictionary *entry = [NSMutableDictionary dictionary];
  entry[@"method"] = method ?: @"";
  entry[@"phase"] = phase ?: @"";
  if (value)
    entry[@"value"] = value;

  @synchronized(log) {
    [log addObject:entry];
  }
}

static void apv_trace_set_stage(const char *stage) {
  gAPVProbeStage = stage ?: "";
  NSLog(@"vphoned: diag_apv_device stage=%s", gAPVProbeStage);
}

static NSString *apv_trace_current_stage(void) {
  const char *stage = gAPVProbeStage;
  return [NSString stringWithUTF8String:stage ?: ""] ?: @"";
}

static NSDictionary *apv_trace_object_summary(id obj) {
  if (!obj)
    return @{};
  return @{
    @"class" : NSStringFromClass([obj class]) ?: @"",
    @"ptr" : [NSString stringWithFormat:@"%p", obj]
  };
}

static id apv_trace_deviceInit(id self, SEL _cmd, io_connect_t port) {
  apv_trace_set_stage("AppleParavirtDevice.initWithAcceleratorPort:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"device_enter",
                @{ @"class" : NSStringFromClass([self class]) ?: @"",
                   @"port" : @(port) });
  id result =
      gAPVDeviceInitOrig ? gAPVDeviceInitOrig(self, _cmd, port) : nil;
  apv_trace_add(NSStringFromSelector(_cmd), @"device_return",
                @{ @"object" : @(result != nil) });
  apv_trace_set_stage("AppleParavirtDevice.initWithAcceleratorPort:return");
  return result;
}

static BOOL apv_trace_setupCompiler(id self, SEL _cmd) {
  apv_trace_set_stage("AppleParavirtDevice.setupCompiler:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"enter", nil);
  BOOL result = gAPVSetupCompilerOrig ? gAPVSetupCompilerOrig(self, _cmd) : NO;
  apv_trace_add(NSStringFromSelector(_cmd), @"return", @(result));
  apv_trace_set_stage("AppleParavirtDevice.setupCompiler:return");
  return result;
}

static id apv_trace_iogpuMetalDeviceInit(id self, SEL _cmd,
                                         io_connect_t port) {
  apv_trace_set_stage("IOGPUMetalDevice.initWithAcceleratorPort:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"super_enter",
                @{ @"class" : NSStringFromClass([self class]) ?: @"",
                   @"port" : @(port) });
  id result = gIOGPUMetalDeviceInitOrig
                  ? gIOGPUMetalDeviceInitOrig(self, _cmd, port)
                  : nil;
  apv_trace_add(NSStringFromSelector(_cmd), @"super_return",
                @{ @"object" : @(result != nil) });
  apv_trace_set_stage("IOGPUMetalDevice.initWithAcceleratorPort:return");
  return result;
}

static id apv_trace_iogpuCommandQueueInit(id self, SEL _cmd, id device,
                                          id descriptor) {
  apv_trace_set_stage("IOGPUMetalCommandQueue.initWithDevice:descriptor:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"iogpu_queue_enter",
                @{ @"class" : NSStringFromClass([self class]) ?: @"",
                   @"device" : apv_trace_object_summary(device),
                   @"descriptor" : apv_trace_object_summary(descriptor) });
  id result = gIOGPUMetalCommandQueueInitOrig
                  ? gIOGPUMetalCommandQueueInitOrig(self, _cmd, device,
                                                    descriptor)
                  : nil;
  apv_trace_add(NSStringFromSelector(_cmd), @"iogpu_queue_return",
                @{ @"object" : @(result != nil) });
  apv_trace_set_stage("IOGPUMetalCommandQueue.initWithDevice:descriptor:return");
  return result;
}

static id apv_trace_iogpuCommandQueueArgsInit(id self, SEL _cmd, id device,
                                              id descriptor, void *args,
                                              size_t argsSize) {
  apv_trace_set_stage(
      "IOGPUMetalCommandQueue.initWithDevice:descriptor:args:argsSize:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"iogpu_queue_args_enter",
                @{ @"class" : NSStringFromClass([self class]) ?: @"",
                   @"device" : apv_trace_object_summary(device),
                   @"descriptor" : apv_trace_object_summary(descriptor),
                   @"args" : [NSString stringWithFormat:@"%p", args],
                   @"args_size" : @(argsSize) });
  id result = gIOGPUMetalCommandQueueArgsInitOrig
                  ? gIOGPUMetalCommandQueueArgsInitOrig(
                        self, _cmd, device, descriptor, args, argsSize)
                  : nil;
  apv_trace_add(NSStringFromSelector(_cmd), @"iogpu_queue_args_return",
                @{ @"object" : @(result != nil) });
  apv_trace_set_stage(
      "IOGPUMetalCommandQueue.initWithDevice:descriptor:args:argsSize:return");
  return result;
}

static id apv_trace_appleParavirtCommandQueueInit(id self, SEL _cmd, id device,
                                                  id descriptor) {
  apv_trace_set_stage(
      "AppleParavirtCommandQueue.initWithDevice:descriptor:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"apv_queue_enter",
                @{ @"class" : NSStringFromClass([self class]) ?: @"",
                   @"device" : apv_trace_object_summary(device),
                   @"descriptor" : apv_trace_object_summary(descriptor) });
  id result = gAppleParavirtCommandQueueInitOrig
                  ? gAppleParavirtCommandQueueInitOrig(self, _cmd, device,
                                                       descriptor)
                  : nil;
  apv_trace_add(NSStringFromSelector(_cmd), @"apv_queue_return",
                @{ @"object" : @(result != nil) });
  apv_trace_set_stage(
      "AppleParavirtCommandQueue.initWithDevice:descriptor:return");
  return result;
}

static id apv_trace_appleParavirtCommandQueueInfoInit(id self, SEL _cmd,
                                                      id device,
                                                      id descriptor,
                                                      BOOL infoCommandQueue) {
  apv_trace_set_stage(
      "AppleParavirtCommandQueue.initWithDevice:descriptor:infoCommandQueue:"
      "enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"apv_info_queue_enter",
                @{ @"class" : NSStringFromClass([self class]) ?: @"",
                   @"device" : apv_trace_object_summary(device),
                   @"descriptor" : apv_trace_object_summary(descriptor),
                   @"info_command_queue" : @(infoCommandQueue) });
  id result = gAppleParavirtCommandQueueInfoInitOrig
                  ? gAppleParavirtCommandQueueInfoInitOrig(
                        self, _cmd, device, descriptor, infoCommandQueue)
                  : nil;
  apv_trace_add(NSStringFromSelector(_cmd), @"apv_info_queue_return",
                @{ @"object" : @(result != nil) });
  apv_trace_set_stage(
      "AppleParavirtCommandQueue.initWithDevice:descriptor:infoCommandQueue:"
      "return");
  return result;
}

static BOOL apv_trace_setupDirtyRing(id self, SEL _cmd) {
  apv_trace_set_stage("AppleParavirtDevice.setupDirtyRing:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"enter", nil);
  BOOL result = gAPVSetupDirtyRingOrig ? gAPVSetupDirtyRingOrig(self, _cmd) : NO;
  apv_trace_add(NSStringFromSelector(_cmd), @"return", @(result));
  apv_trace_set_stage("AppleParavirtDevice.setupDirtyRing:return");
  return result;
}

static void apv_trace_setupDeviceInfo(id self, SEL _cmd) {
  apv_trace_set_stage("AppleParavirtDevice.setupDeviceInfo:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"enter", nil);
  if (gAPVSetupDeviceInfoOrig)
    gAPVSetupDeviceInfoOrig(self, _cmd);
  apv_trace_add(NSStringFromSelector(_cmd), @"return", nil);
  apv_trace_set_stage("AppleParavirtDevice.setupDeviceInfo:return");
}

static void apv_trace_setupDeviceArchInfo(id self, SEL _cmd) {
  apv_trace_set_stage("AppleParavirtDevice.setupDeviceArchInfo:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"enter", nil);
  if (gAPVSetupDeviceArchInfoOrig)
    gAPVSetupDeviceArchInfoOrig(self, _cmd);
  apv_trace_add(NSStringFromSelector(_cmd), @"return", nil);
  apv_trace_set_stage("AppleParavirtDevice.setupDeviceArchInfo:return");
}

static void apv_trace_setupResourcePools(id self, SEL _cmd) {
  apv_trace_set_stage("AppleParavirtDevice.setupResourcePools:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"enter", nil);
  if (gAPVSetupResourcePoolsOrig)
    gAPVSetupResourcePoolsOrig(self, _cmd);
  apv_trace_add(NSStringFromSelector(_cmd), @"return", nil);
  apv_trace_set_stage("AppleParavirtDevice.setupResourcePools:return");
}

static void apv_trace_setupSerializerFeatures(id self, SEL _cmd) {
  apv_trace_set_stage("AppleParavirtDevice.setupSerializerFeatures:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"enter", nil);
  if (gAPVSetupSerializerFeaturesOrig)
    gAPVSetupSerializerFeaturesOrig(self, _cmd);
  apv_trace_set_stage(
      "AppleParavirtDevice.setupSerializerFeatures:after_original");
  SEL featuresSel = NSSelectorFromString(@"features");
  if ([self respondsToSelector:featuresSel]) {
    typedef const uint8_t *(*FeaturesMsgSend)(id, SEL);
    const uint8_t *features =
        ((FeaturesMsgSend)objc_msgSend)(self, featuresSel);
    if (features) {
      uint8_t before = features[0x1d];
      if (gAPVDisableInfoQueue)
        ((uint8_t *)features)[0x1d] = 0;
      apv_trace_add(NSStringFromSelector(_cmd), @"features",
                    @{ @"info_queue_byte_before" : @(before),
                       @"info_queue_byte_after" : @(features[0x1d]),
                       @"disable_info_queue" : @(gAPVDisableInfoQueue) });
    }
  }
  apv_trace_add(NSStringFromSelector(_cmd), @"return", nil);
  apv_trace_set_stage("AppleParavirtDevice.setupSerializerFeatures:return");
}

static void apv_trace_setupSupportedHostGPUFamilies(id self, SEL _cmd) {
  apv_trace_set_stage("AppleParavirtDevice.setupSupportedHostGPUFamilies:enter");
  apv_trace_add(NSStringFromSelector(_cmd), @"enter", nil);
  if (gAPVSetupSupportedHostGPUFamiliesOrig)
    gAPVSetupSupportedHostGPUFamiliesOrig(self, _cmd);
  apv_trace_add(NSStringFromSelector(_cmd), @"return", nil);
  apv_trace_set_stage("AppleParavirtDevice.setupSupportedHostGPUFamilies:return");
}

static void apv_swizzle_bool_method(Class cls, NSString *name,
                                    APVBoolMethodIMP *original,
                                    IMP replacement,
                                    NSMutableArray *events) {
  SEL sel = NSSelectorFromString(name);
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) {
    [events addObject:@{ @"method" : name, @"installed" : @NO }];
    return;
  }

  if (!*original)
    *original = (APVBoolMethodIMP)method_setImplementation(method, replacement);
  [events addObject:@{ @"method" : name, @"installed" : @(*original != NULL) }];
}

static void apv_swizzle_void_method(Class cls, NSString *name,
                                    APVVoidMethodIMP *original,
                                    IMP replacement,
                                    NSMutableArray *events) {
  SEL sel = NSSelectorFromString(name);
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) {
    [events addObject:@{ @"method" : name, @"installed" : @NO }];
    return;
  }

  if (!*original)
    *original = (APVVoidMethodIMP)method_setImplementation(method, replacement);
  [events addObject:@{ @"method" : name, @"installed" : @(*original != NULL) }];
}

static void apv_swizzle_init_method(Class cls, NSString *name,
                                    APVInitWithPortIMP *original,
                                    IMP replacement,
                                    NSMutableArray *events) {
  SEL sel = NSSelectorFromString(name);
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) {
    [events addObject:@{ @"method" : name,
                         @"class" : NSStringFromClass(cls) ?: @"",
                         @"installed" : @NO }];
    return;
  }

  if (!*original)
    *original = (APVInitWithPortIMP)method_setImplementation(method, replacement);
  [events addObject:@{ @"method" : name,
                       @"class" : NSStringFromClass(cls) ?: @"",
                       @"installed" : @(*original != NULL) }];
}

static void apv_swizzle_queue_init_method(Class cls, NSString *name,
                                          APVCommandQueueInitIMP *original,
                                          IMP replacement,
                                          NSMutableArray *events) {
  SEL sel = NSSelectorFromString(name);
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) {
    [events addObject:@{ @"method" : name,
                         @"class" : NSStringFromClass(cls) ?: @"",
                         @"installed" : @NO }];
    return;
  }

  if (!*original)
    *original = (APVCommandQueueInitIMP)method_setImplementation(method,
                                                                replacement);
  [events addObject:@{ @"method" : name,
                       @"class" : NSStringFromClass(cls) ?: @"",
                       @"installed" : @(*original != NULL) }];
}

static void
apv_swizzle_queue_args_init_method(Class cls, NSString *name,
                                   APVCommandQueueArgsInitIMP *original,
                                   IMP replacement,
                                   NSMutableArray *events) {
  SEL sel = NSSelectorFromString(name);
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) {
    [events addObject:@{ @"method" : name,
                         @"class" : NSStringFromClass(cls) ?: @"",
                         @"installed" : @NO }];
    return;
  }

  if (!*original)
    *original =
        (APVCommandQueueArgsInitIMP)method_setImplementation(method,
                                                            replacement);
  [events addObject:@{ @"method" : name,
                       @"class" : NSStringFromClass(cls) ?: @"",
                       @"installed" : @(*original != NULL) }];
}

static void
apv_swizzle_queue_info_init_method(Class cls, NSString *name,
                                   APVCommandQueueInfoInitIMP *original,
                                   IMP replacement,
                                   NSMutableArray *events) {
  SEL sel = NSSelectorFromString(name);
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) {
    [events addObject:@{ @"method" : name,
                         @"class" : NSStringFromClass(cls) ?: @"",
                         @"installed" : @NO }];
    return;
  }

  if (!*original)
    *original =
        (APVCommandQueueInfoInitIMP)method_setImplementation(method,
                                                            replacement);
  [events addObject:@{ @"method" : name,
                       @"class" : NSStringFromClass(cls) ?: @"",
                       @"installed" : @(*original != NULL) }];
}

static NSArray *apv_install_trace(Class cls, NSMutableArray *trace) {
  gAPVTraceLog = trace;

  NSMutableArray *events = [NSMutableArray array];
  apv_swizzle_init_method(cls, @"initWithAcceleratorPort:",
                          &gAPVDeviceInitOrig,
                          (IMP)apv_trace_deviceInit, events);

  Class superCls = NSClassFromString(@"IOGPUMetalDevice");
  if (superCls) {
    apv_swizzle_init_method(superCls, @"initWithAcceleratorPort:",
                            &gIOGPUMetalDeviceInitOrig,
                            (IMP)apv_trace_iogpuMetalDeviceInit, events);
  } else {
    [events addObject:@{ @"method" : @"initWithAcceleratorPort:",
                         @"class" : @"IOGPUMetalDevice",
                         @"installed" : @NO }];
  }

  Class superQueueCls = NSClassFromString(@"IOGPUMetalCommandQueue");
  if (superQueueCls) {
    apv_swizzle_queue_init_method(superQueueCls, @"initWithDevice:descriptor:",
                                  &gIOGPUMetalCommandQueueInitOrig,
                                  (IMP)apv_trace_iogpuCommandQueueInit, events);
    apv_swizzle_queue_args_init_method(
        superQueueCls, @"initWithDevice:descriptor:args:argsSize:",
        &gIOGPUMetalCommandQueueArgsInitOrig,
        (IMP)apv_trace_iogpuCommandQueueArgsInit, events);
  } else {
    [events addObject:@{ @"method" : @"initWithDevice:descriptor:",
                         @"class" : @"IOGPUMetalCommandQueue",
                         @"installed" : @NO }];
    [events
        addObject:@{ @"method" : @"initWithDevice:descriptor:args:argsSize:",
                     @"class" : @"IOGPUMetalCommandQueue",
                     @"installed" : @NO }];
  }

  Class apvQueueCls = NSClassFromString(@"AppleParavirtCommandQueue");
  if (apvQueueCls) {
    apv_swizzle_queue_init_method(
        apvQueueCls, @"initWithDevice:descriptor:",
        &gAppleParavirtCommandQueueInitOrig,
        (IMP)apv_trace_appleParavirtCommandQueueInit, events);
    apv_swizzle_queue_info_init_method(
        apvQueueCls, @"initWithDevice:descriptor:infoCommandQueue:",
        &gAppleParavirtCommandQueueInfoInitOrig,
        (IMP)apv_trace_appleParavirtCommandQueueInfoInit, events);
  } else {
    [events addObject:@{ @"method" : @"initWithDevice:descriptor:",
                         @"class" : @"AppleParavirtCommandQueue",
                         @"installed" : @NO }];
    [events
        addObject:@{ @"method" : @"initWithDevice:descriptor:infoCommandQueue:",
                     @"class" : @"AppleParavirtCommandQueue",
                     @"installed" : @NO }];
  }

  apv_swizzle_void_method(cls, @"setupDeviceInfo", &gAPVSetupDeviceInfoOrig,
                          (IMP)apv_trace_setupDeviceInfo, events);
  apv_swizzle_void_method(cls, @"setupDeviceArchInfo",
                          &gAPVSetupDeviceArchInfoOrig,
                          (IMP)apv_trace_setupDeviceArchInfo, events);
  apv_swizzle_bool_method(cls, @"setupCompiler", &gAPVSetupCompilerOrig,
                          (IMP)apv_trace_setupCompiler, events);
  apv_swizzle_void_method(cls, @"setupResourcePools", &gAPVSetupResourcePoolsOrig,
                          (IMP)apv_trace_setupResourcePools, events);
  apv_swizzle_bool_method(cls, @"setupDirtyRing", &gAPVSetupDirtyRingOrig,
                          (IMP)apv_trace_setupDirtyRing, events);
  apv_swizzle_void_method(cls, @"setupSerializerFeatures",
                          &gAPVSetupSerializerFeaturesOrig,
                          (IMP)apv_trace_setupSerializerFeatures, events);
  apv_swizzle_void_method(cls, @"setupSupportedHostGPUFamilies",
                          &gAPVSetupSupportedHostGPUFamiliesOrig,
                          (IMP)apv_trace_setupSupportedHostGPUFamilies, events);
  return events;
}

static NSDictionary *run_diag_apv_device_probe(id reqId, BOOL disableInfoQueue,
                                               BOOL skipQuery,
                                               BOOL skipNewCommandQueue) {
  apv_trace_set_stage("start");
  NSMutableDictionary *r = vp_make_response(@"diag_apv_device", reqId);
  r[@"disable_info_queue"] = @(disableInfoQueue);
  r[@"skip_query"] = @(skipQuery);
  r[@"skip_new_command_queue"] = @(skipNewCommandQueue);

  apv_trace_set_stage("bundle_load");
  NSDictionary *bundleResult = run_diag_bundle_probe(
      reqId, @"/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle");
  r[@"bundle"] = bundleResult ?: @{};
  if (![bundleResult[@"loaded"] boolValue]) {
    r[@"stage"] = @"bundle_load";
    return r;
  }

  apv_trace_set_stage("class_lookup");
  Class cls = NSClassFromString(@"AppleParavirtDevice");
  if (!cls) {
    r[@"class_found"] = @NO;
    r[@"stage"] = @"class_lookup";
    return r;
  }
  r[@"class_found"] = @YES;

  apv_trace_set_stage("dlopen_iogpu");
  void *iogs = dlopen("/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU",
                      RTLD_LAZY | RTLD_LOCAL);
  if (!iogs) {
    r[@"iogs_loaded"] = @NO;
    r[@"stage"] = @"dlopen_iogpu";
    r[@"dlerror"] = [NSString stringWithUTF8String:dlerror() ?: "unknown"];
    return r;
  }
  r[@"iogs_loaded"] = @YES;

  apv_trace_set_stage("dlsym_iogpu");
  typedef void *(*CreateWithOptionsFn)(io_service_t, uint32_t);
  typedef void (*ReleaseFn)(void *);
  typedef io_connect_t (*GetConnectFn)(void *);
  CreateWithOptionsFn create =
      (CreateWithOptionsFn)dlsym(iogs, "IOGPUDeviceCreateWithOptions");
  ReleaseFn release = (ReleaseFn)dlsym(iogs, "IOGPUDeviceRelease");
  GetConnectFn getConnect = (GetConnectFn)dlsym(iogs, "IOGPUDeviceGetConnect");
  if (!create || !getConnect) {
    r[@"stage"] = @"dlsym_iogpu";
    r[@"symbols_found"] = @NO;
    return r;
  }
  r[@"symbols_found"] = @YES;

  apv_trace_set_stage("service_lookup");
  io_service_t service =
      IOServiceGetMatchingService(kIOMainPortDefault,
                                  IOServiceMatching("AppleParavirtGPU"));
  if (service == IO_OBJECT_NULL) {
    r[@"stage"] = @"service_lookup";
    r[@"service_found"] = @NO;
    return r;
  }
  r[@"service_found"] = @YES;

  apv_trace_set_stage("iogpu_device_create");
  void *iogsDevice = create(service, 0);
  if (!iogsDevice) {
    IOObjectRelease(service);
    r[@"stage"] = @"iogpu_device_create";
    r[@"iogpu_device"] = @NO;
    return r;
  }
  r[@"iogpu_device"] = @YES;

  io_connect_t connect = getConnect(iogsDevice);
  r[@"connect"] = @(connect != IO_OBJECT_NULL);
  r[@"connect_port"] = @(connect);
  if (connect == IO_OBJECT_NULL) {
    if (release)
      release(iogsDevice);
    IOObjectRelease(service);
    r[@"stage"] = @"iogpu_get_connect";
    return r;
  }

  apv_trace_set_stage("alloc");
  r[@"stage"] = @"alloc";
  id obj = ((id (*)(Class, SEL))objc_msgSend)(cls, @selector(alloc));
  if (!obj) {
    if (release)
      release(iogsDevice);
    IOObjectRelease(service);
    r[@"allocated"] = @NO;
    return r;
  }
  r[@"allocated"] = @YES;

  apv_trace_set_stage("initWithAcceleratorPort");
  r[@"stage"] = @"initWithAcceleratorPort";
  SEL initSel = NSSelectorFromString(@"initWithAcceleratorPort:");
  if (![obj respondsToSelector:initSel]) {
    if (release)
      release(iogsDevice);
    IOObjectRelease(service);
    r[@"responds_init"] = @NO;
    return r;
  }
  r[@"responds_init"] = @YES;
  r[@"accelerator_port_kind"] = @"service";
  r[@"accelerator_port"] = @(service);

  NSMutableArray *trace = [NSMutableArray array];
  gAPVDisableInfoQueue = disableInfoQueue;
  apv_trace_set_stage("install_trace");
  r[@"trace_install"] = apv_install_trace(cls, trace);

  typedef id (*InitWithPortMsgSend)(id, SEL, io_connect_t);
  apv_trace_set_stage("call_initWithAcceleratorPort");
  id device = ((InitWithPortMsgSend)objc_msgSend)(obj, initSel, service);
  r[@"trace"] = [trace copy];
  gAPVTraceLog = nil;
  gAPVDisableInfoQueue = NO;

  r[@"device"] = @(device != nil);
  if (!device) {
    if (release)
      release(iogsDevice);
    IOObjectRelease(service);
    return r;
  }

  if (skipQuery) {
    if (release)
      release(iogsDevice);
    IOObjectRelease(service);
    apv_trace_set_stage("done");
    r[@"stage"] = @"done";
    return r;
  }

  apv_trace_set_stage("query");
  r[@"stage"] = @"query";
  apv_trace_set_stage("query_name");
  add_string_selector_result(r, device, @"name", @selector(name));
  apv_trace_set_stage("query_product_name");
  add_string_selector_result(r, device, @"product_name",
                             NSSelectorFromString(@"productName"));
  apv_trace_set_stage("query_vendor_name");
  add_string_selector_result(r, device, @"vendor_name",
                             NSSelectorFromString(@"vendorName"));
  apv_trace_set_stage("query_supports_open_gl");
  add_bool_selector_result(r, device, @"supports_open_gl",
                           NSSelectorFromString(@"supportsOpenGL"));
  apv_trace_set_stage("query_supports_dynamic_libraries");
  add_bool_selector_result(r, device, @"supports_dynamic_libraries",
                           NSSelectorFromString(@"supportsDynamicLibraries"));

  if (!skipNewCommandQueue && [device respondsToSelector:@selector(newCommandQueue)]) {
    apv_trace_set_stage("newCommandQueue");
    r[@"stage"] = @"newCommandQueue";
    typedef id (*ObjMsgSend)(id, SEL);
    id queue = ((ObjMsgSend)objc_msgSend)(device, @selector(newCommandQueue));
    r[@"command_queue"] = @(queue != nil);
  }

  if (release)
    release(iogsDevice);
  IOObjectRelease(service);
  apv_trace_set_stage("done");
  r[@"stage"] = @"done";
  return r;
}

static NSDictionary *handle_diag_apv_device(NSDictionary *msg) {
  id reqId = msg[@"id"];
  BOOL disableInfoQueue = [msg[@"disable_info_queue"] boolValue];
  BOOL skipQuery = [msg[@"skip_query"] boolValue];
  BOOL skipNewCommandQueue = [msg[@"skip_new_command_queue"] boolValue];
  NSNumber *timeoutValue = msg[@"timeout"];
  NSTimeInterval timeout = timeoutValue ? timeoutValue.doubleValue : 8.0;
  if (timeout <= 0 || timeout > 20)
    timeout = 8.0;

  __block NSDictionary *probeResult = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      probeResult = run_diag_apv_device_probe(reqId, disableInfoQueue, skipQuery,
                                              skipNewCommandQueue);
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    NSMutableDictionary *r = vp_make_response(@"diag_apv_device", reqId);
    r[@"timed_out"] = @YES;
    r[@"stage"] = apv_trace_current_stage();
    r[@"disable_info_queue"] = @(disableInfoQueue);
    r[@"skip_query"] = @(skipQuery);
    r[@"skip_new_command_queue"] = @(skipNewCommandQueue);
    NSMutableArray *trace = gAPVTraceLog;
    if (trace) {
      @synchronized(trace) {
        r[@"trace"] = [trace copy];
      }
    }
    gAPVTraceLog = nil;
    gAPVDisableInfoQueue = NO;
    return r;
  }

  NSMutableDictionary *r = [probeResult mutableCopy] ?: vp_make_response(@"diag_apv_device", reqId);
  r[@"timed_out"] = @NO;
  return r;
}

static NSString *version_string(uint32_t version) {
  return [NSString stringWithFormat:@"%u.%u.%u",
                                    (version >> 16) & 0xffff,
                                    (version >> 8) & 0xff,
                                    version & 0xff];
}

static void add_macho_image_info(NSMutableDictionary *r, const void *base) {
  if (!base)
    return;

  const struct mach_header_64 *mh = (const struct mach_header_64 *)base;
  if (mh->magic != MH_MAGIC_64 && mh->magic != MH_CIGAM_64)
    return;

  const uint8_t *p = (const uint8_t *)(mh + 1);
  for (uint32_t i = 0; i < mh->ncmds; i++) {
    const struct load_command *lc = (const struct load_command *)p;
    if (lc->cmdsize < sizeof(struct load_command))
      break;

    if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)) {
      const struct uuid_command *uc = (const struct uuid_command *)lc;
      r[@"uuid"] = [NSString
          stringWithFormat:
              @"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
              uc->uuid[0], uc->uuid[1], uc->uuid[2], uc->uuid[3],
              uc->uuid[4], uc->uuid[5], uc->uuid[6], uc->uuid[7],
              uc->uuid[8], uc->uuid[9], uc->uuid[10], uc->uuid[11],
              uc->uuid[12], uc->uuid[13], uc->uuid[14], uc->uuid[15]];
    } else if (lc->cmd == LC_ID_DYLIB &&
               lc->cmdsize >= sizeof(struct dylib_command)) {
      const struct dylib_command *dc = (const struct dylib_command *)lc;
      r[@"current_version"] = version_string(dc->dylib.current_version);
      r[@"compatibility_version"] =
          version_string(dc->dylib.compatibility_version);
    }

    p += lc->cmdsize;
  }
}

static NSDictionary *handle_diag_dlopen(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *path = msg[@"path"];
  NSString *symbol = msg[@"symbol"];
  NSSet *allowedPaths = [NSSet setWithArray:@[
    @"/System/Library/Frameworks/Metal.framework/Metal",
    @"/usr/lib/vphone-gpu/Metal372.dylib",
    @"/usr/lib/vphone-gpu/IOGPU13013.dylib",
    @"/usr/lib/vphone-gpu/libGPUSupportMercury.dylib",
    @"/usr/lib/vphone-gpu/MTLCompiler32023.dylib",
    @"/usr/lib/vphone-gpu/MTLCompiler32024.dylib",
    @"/usr/lib/vphone-gpu/libMTLCompilerHelper.dylib",
    @"/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle/AppleParavirtGPUMetalIOGPUFamily",
    @"/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU",
    @"/System/Library/PrivateFrameworks/GPUSupport.framework/libGPUSupportMercury.dylib",
    @"/System/Library/PrivateFrameworks/MTLCompiler.framework/Versions/32023/MTLCompiler",
    @"/System/Library/PrivateFrameworks/MTLCompiler.framework/Versions/32024/MTLCompiler",
    @"/System/Library/PrivateFrameworks/MTLCompiler.framework/libMTLCompilerHelper.dylib",
  ]];
  if (![path isKindOfClass:[NSString class]] ||
      ![allowedPaths containsObject:path]) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"unsupported dlopen path";
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"diag_dlopen", reqId);
  r[@"path"] = path;

  dlerror();
  void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_LOCAL);
  if (!handle) {
    r[@"loaded"] = @NO;
    r[@"dlerror"] = [NSString stringWithUTF8String:dlerror() ?: "unknown"];
    return r;
  }
  r[@"loaded"] = @YES;

  if ([symbol isKindOfClass:[NSString class]] && symbol.length > 0) {
    dlerror();
    void *sym = dlsym(handle, symbol.UTF8String);
    r[@"symbol"] = symbol;
    r[@"symbol_found"] = @(sym != NULL);
    const char *err = dlerror();
    if (err)
      r[@"dlsym_error"] = [NSString stringWithUTF8String:err] ?: @"";
    if (sym) {
      Dl_info info;
      if (dladdr(sym, &info) != 0) {
        if (info.dli_fname)
          r[@"image"] = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
        if (info.dli_sname)
          r[@"resolved_symbol"] =
              [NSString stringWithUTF8String:info.dli_sname] ?: @"";
        add_macho_image_info(r, info.dli_fbase);
      }
    }
  }

  uint32_t imageCount = _dyld_image_count();
  NSMutableArray *images = [NSMutableArray array];
  NSArray *needles = @[
    @"Metal.framework",
    @"IOGPU.framework",
    @"GPUSupport.framework",
    @"MTLCompiler.framework",
    @"AppleParavirtGPUMetalIOGPUFamily",
  ];
  for (uint32_t i = 0; i < imageCount && images.count < 32; i++) {
    const char *name = _dyld_get_image_name(i);
    if (!name)
      continue;
    NSString *image = [NSString stringWithUTF8String:name] ?: @"";
    for (NSString *needle in needles) {
      if ([image rangeOfString:needle].location != NSNotFound) {
        [images addObject:image];
        break;
      }
    }
  }
  r[@"images"] = images;
  return r;
}

static NSDictionary *run_diag_bundle_probe(id reqId, NSString *bundlePath) {
  NSMutableDictionary *r = vp_make_response(@"diag_bundle", reqId);
  r[@"path"] = bundlePath;

  NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
  if (!bundle) {
    r[@"bundle_found"] = @NO;
    return r;
  }

  r[@"bundle_found"] = @YES;
  if (bundle.bundleIdentifier)
    r[@"bundle_identifier"] = bundle.bundleIdentifier;
  if (bundle.executablePath)
    r[@"executable_path"] = bundle.executablePath;

  NSDictionary *info = bundle.infoDictionary ?: @{};
  NSMutableDictionary *infoOut = [NSMutableDictionary dictionary];
  for (NSString *key in @[
         @"CFBundleVersion",
         @"CFBundleShortVersionString",
         @"CFBundleExecutable",
         @"NSPrincipalClass",
         @"MinimumOSVersion",
         @"DTSDKName",
         @"DTPlatformVersion",
       ]) {
    id value = info[key];
    if (value)
      infoOut[key] = [value description] ?: @"";
  }
  r[@"info"] = infoOut;

  NSError *error = nil;
  BOOL loaded = [bundle loadAndReturnError:&error];
  r[@"loaded"] = @(loaded);
  if (error) {
    r[@"error_domain"] = error.domain ?: @"";
    r[@"error_code"] = @(error.code);
    r[@"error"] = error.localizedDescription ?: @"";
  }

  Class principal = bundle.principalClass;
  if (principal)
    r[@"principal_class"] = NSStringFromClass(principal);
  Class paravirtClass = NSClassFromString(@"AppleParavirtDevice");
  r[@"apple_paravirt_device_class"] = @(paravirtClass != Nil);

  uint32_t imageCount = _dyld_image_count();
  NSMutableArray *images = [NSMutableArray array];
  for (uint32_t i = 0; i < imageCount && images.count < 32; i++) {
    const char *name = _dyld_get_image_name(i);
    if (!name)
      continue;
    NSString *image = [NSString stringWithUTF8String:name] ?: @"";
    if ([image rangeOfString:@"AppleParavirtGPUMetalIOGPUFamily"].location !=
        NSNotFound) {
      [images addObject:image];
    }
  }
  r[@"images"] = images;

  return r;
}

static NSDictionary *handle_diag_bundle(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *bundlePath = msg[@"path"];
  NSSet *allowedPaths = [NSSet setWithArray:@[
    @"/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle",
  ]];
  if (![bundlePath isKindOfClass:[NSString class]] ||
      ![allowedPaths containsObject:bundlePath]) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"unsupported bundle path";
    return r;
  }

  NSNumber *timeoutValue = msg[@"timeout"];
  NSTimeInterval timeout = timeoutValue ? timeoutValue.doubleValue : 5.0;
  if (timeout <= 0 || timeout > 15)
    timeout = 5.0;

  __block NSDictionary *probeResult = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      probeResult = run_diag_bundle_probe(reqId, bundlePath);
      dispatch_semaphore_signal(sem);
    }
  });

  dispatch_time_t deadline =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
  if (dispatch_semaphore_wait(sem, deadline) != 0) {
    NSMutableDictionary *r = vp_make_response(@"diag_bundle", reqId);
    r[@"path"] = bundlePath;
    r[@"timed_out"] = @YES;
    return r;
  }

  NSMutableDictionary *r = [probeResult mutableCopy] ?: vp_make_response(@"diag_bundle", reqId);
  r[@"timed_out"] = @NO;
  return r;
}

// MARK: - Auto-update

/// Receive raw binary from host, write to CACHE_PATH, chmod +x.
static BOOL receive_update(int fd, NSUInteger size) {
  mkdir(CACHE_DIR, 0755);

  char tmp_path[] = CACHE_DIR "/vphoned.XXXXXX";
  int tmp_fd = mkstemp(tmp_path);
  if (tmp_fd < 0) {
    NSLog(@"vphoned: mkstemp failed: %s", strerror(errno));
    return NO;
  }

  uint8_t buf[32768];
  NSUInteger remaining = size;
  while (remaining > 0) {
    size_t chunk = remaining < sizeof(buf) ? remaining : sizeof(buf);
    if (!vp_read_fully(fd, buf, chunk)) {
      NSLog(@"vphoned: update read failed at %lu/%lu",
            (unsigned long)(size - remaining), (unsigned long)size);
      close(tmp_fd);
      unlink(tmp_path);
      return NO;
    }
    if (write(tmp_fd, buf, chunk) != (ssize_t)chunk) {
      NSLog(@"vphoned: update write failed: %s", strerror(errno));
      close(tmp_fd);
      unlink(tmp_path);
      return NO;
    }
    remaining -= chunk;
  }
  close(tmp_fd);
  chmod(tmp_path, 0755);

  if (rename(tmp_path, CACHE_PATH) != 0) {
    NSLog(@"vphoned: rename to cache failed: %s", strerror(errno));
    unlink(tmp_path);
    return NO;
  }

  NSLog(@"vphoned: update written to %s (%lu bytes)", CACHE_PATH,
        (unsigned long)size);
  return YES;
}

// MARK: - Command Dispatch

static NSDictionary *handle_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  if ([type isEqualToString:@"hid"]) {
    uint32_t page = [msg[@"page"] unsignedIntValue];
    uint32_t usage = [msg[@"usage"] unsignedIntValue];
    NSNumber *downVal = msg[@"down"];
    if (downVal != nil) {
      vp_hid_key(page, usage, [downVal boolValue]);
    } else {
      vp_hid_press(page, usage);
    }
    return vp_make_response(@"ok", reqId);
  }

  if ([type isEqualToString:@"devmode"]) {
    if (!vp_devmode_available()) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"XPC not available";
      return r;
    }
    NSString *action = msg[@"action"];
    if ([action isEqualToString:@"status"]) {
      BOOL enabled = vp_devmode_status();
      NSMutableDictionary *r = vp_make_response(@"ok", reqId);
      r[@"enabled"] = @(enabled);
      return r;
    }
    if ([action isEqualToString:@"enable"]) {
      BOOL alreadyEnabled = NO;
      BOOL ok = vp_devmode_arm(&alreadyEnabled);
      NSMutableDictionary *r = vp_make_response(ok ? @"ok" : @"err", reqId);
      if (ok) {
        r[@"already_enabled"] = @(alreadyEnabled);
        r[@"msg"] = alreadyEnabled
                        ? @"developer mode already enabled"
                        : @"developer mode armed, reboot to activate";
      } else {
        r[@"msg"] = @"failed to arm developer mode";
      }
      return r;
    }
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] =
        [NSString stringWithFormat:@"unknown devmode action: %@", action];
    return r;
  }

  if ([type isEqualToString:@"ping"]) {
    return vp_make_response(@"pong", reqId);
  }

  if ([type isEqualToString:@"location"]) {
    double lat = [msg[@"lat"] doubleValue];
    double lon = [msg[@"lon"] doubleValue];
    double alt = [msg[@"alt"] doubleValue];
    double hacc = [msg[@"hacc"] doubleValue];
    double vacc = [msg[@"vacc"] doubleValue];
    double speed = [msg[@"speed"] doubleValue];
    double course = [msg[@"course"] doubleValue];
    vp_location_simulate(lat, lon, alt, hacc, vacc, speed, course);
    return vp_make_response(@"ok", reqId);
  }

  if ([type isEqualToString:@"location_stop"]) {
    vp_location_clear();
    return vp_make_response(@"ok", reqId);
  }

  if ([type isEqualToString:@"version"]) {
    NSMutableDictionary *r = vp_make_response(@"version", reqId);
    r[@"hash"] = @VPHONED_BUILD_HASH;
    return r;
  }

  if ([type isEqualToString:@"ipa_install"]) {
    return vp_handle_custom_install(msg);
  }

  if ([type isEqualToString:@"diag_processes"]) {
    return handle_diag_processes(msg);
  }

  if ([type isEqualToString:@"diag_procinfo"]) {
    return handle_diag_procinfo(msg);
  }

  if ([type isEqualToString:@"diag_launchctl"]) {
    return handle_diag_launchctl(msg);
  }

  if ([type isEqualToString:@"diag_exec"]) {
    return handle_diag_exec(msg);
  }

  if ([type isEqualToString:@"diag_spawn"]) {
    return handle_diag_spawn(msg);
  }

  if ([type isEqualToString:@"diag_bootstrap"]) {
    return handle_diag_bootstrap(msg);
  }

  if ([type isEqualToString:@"diag_metal"]) {
    return handle_diag_metal(msg);
  }

  if ([type isEqualToString:@"diag_iokit"]) {
    return handle_diag_iokit(msg);
  }

  if ([type isEqualToString:@"diag_iokit_props"]) {
    return handle_diag_iokit_props(msg);
  }

  if ([type isEqualToString:@"diag_iokit_open"]) {
    return handle_diag_iokit_open(msg);
  }

  if ([type isEqualToString:@"diag_iogpu_device"]) {
    return handle_diag_iogpu_device(msg);
  }

  if ([type isEqualToString:@"diag_iogpu_super"]) {
    return handle_diag_iogpu_super(msg);
  }

  if ([type isEqualToString:@"diag_iogpu_queue_call"]) {
    return handle_diag_iogpu_queue_call(msg);
  }

  if ([type isEqualToString:@"diag_iogpu_queue_api"]) {
    return handle_diag_iogpu_queue_api(msg);
  }

  if ([type isEqualToString:@"diag_apv_device"]) {
    return handle_diag_apv_device(msg);
  }

  if ([type isEqualToString:@"diag_dlopen"]) {
    return handle_diag_dlopen(msg);
  }

  if ([type isEqualToString:@"diag_bundle"]) {
    return handle_diag_bundle(msg);
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = [NSString stringWithFormat:@"unknown type: %@", type];
  return r;
}

// MARK: - Client Session

/// Returns YES if daemon should exit for restart (after update).
static BOOL handle_client(int fd) {
  BOOL should_restart = NO;
  @autoreleasepool {
    NSDictionary *hello = vp_read_message(fd);
    if (!hello) {
      close(fd);
      return NO;
    }

    NSInteger version = [hello[@"v"] integerValue];
    NSString *type = hello[@"t"];

    if (![type isEqualToString:@"hello"]) {
      NSLog(@"vphoned: expected hello, got %@", type);
      close(fd);
      return NO;
    }

    if (version != PROTOCOL_VERSION) {
      NSLog(@"vphoned: version mismatch (client v%ld, daemon v%d)",
            (long)version, PROTOCOL_VERSION);
      vp_write_message(
          fd, @{
            @"v" : @PROTOCOL_VERSION,
            @"t" : @"err",
            @"msg" : @"version mismatch"
          });
      close(fd);
      return NO;
    }

    // Hash comparison for auto-update
    NSString *hostHash = hello[@"bin_hash"];
    BOOL needUpdate = NO;
    if (hostHash.length > 0) {
      const char *selfPath = self_executable_path();
      NSString *selfHash = selfPath ? sha256_of_file(selfPath) : nil;
      if (selfHash && ![selfHash isEqualToString:hostHash]) {
        NSLog(@"vphoned: hash mismatch (self=%@ host=%@)", selfHash, hostHash);
        needUpdate = YES;
      } else if (selfHash) {
        NSLog(@"vphoned: hash OK");
      }
    }

    // Build capabilities list
    NSMutableArray *caps =
        [NSMutableArray arrayWithObjects:@"devmode", @"file", @"keychain", nil];
    if (gHIDAvailable)
      [caps addObject:@"hid"];
    if (vp_location_available())
      [caps addObject:@"location"];
    if (vp_custom_installer_available())
      [caps addObject:@"ipa_install"];
    if (gClipboardAvailable)
      [caps addObject:@"clipboard"];
    if (gAppsAvailable)
      [caps addObject:@"apps"];
    [caps addObject:@"url"];
    [caps addObject:@"settings"];
    [caps addObject:@"diag"];

    NSMutableDictionary *helloResp = [@{
      @"v" : @PROTOCOL_VERSION,
      @"t" : @"hello",
      @"name" : @"vphoned",
      @"caps" : caps,
    } mutableCopy];
    NSString *ip = primary_ipv4_address();
    if (ip)
      helloResp[@"ip"] = ip;
    if (needUpdate)
      helloResp[@"need_update"] = @YES;

    if (!vp_write_message(fd, helloResp)) {
      close(fd);
      return NO;
    }
    NSLog(@"vphoned: client connected (v%d)%s", PROTOCOL_VERSION,
          needUpdate ? " [update pending]" : "");

    NSDictionary *msg;
    while ((msg = vp_read_message(fd)) != nil) {
      @autoreleasepool {
        NSString *t = msg[@"t"];
        NSLog(@"vphoned: recv cmd: %@", t);

        if ([t isEqualToString:@"update"]) {
          NSUInteger size = [msg[@"size"] unsignedIntegerValue];
          id reqId = msg[@"id"];
          NSLog(@"vphoned: receiving update (%lu bytes)", (unsigned long)size);
          if (size > 0 && size < 10 * 1024 * 1024 && receive_update(fd, size)) {
            NSMutableDictionary *r = vp_make_response(@"ok", reqId);
            r[@"msg"] = @"updated, restarting";
            vp_write_message(fd, r);
            should_restart = YES;
            break;
          } else {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = @"update failed";
            vp_write_message(fd, r);
          }
          continue;
        }

        // File operations (need fd for inline binary transfer)
        if ([t hasPrefix:@"file_"]) {
          NSDictionary *resp = vp_handle_file_command(fd, msg);
          if (resp && !vp_write_message(fd, resp))
            break;
          continue;
        }

        // Keychain operations
        if ([t hasPrefix:@"keychain_"]) {
          NSDictionary *resp = vp_handle_keychain_command(msg);
          if (resp && !vp_write_message(fd, resp))
            break;
          continue;
        }

        // Clipboard operations (need fd for inline binary transfer)
        if ([t hasPrefix:@"clipboard_"]) {
          NSDictionary *resp = vp_handle_clipboard_command(fd, msg);
          if (resp && !vp_write_message(fd, resp))
            break;
          continue;
        }

        // App management operations
        if ([t hasPrefix:@"app_"]) {
          NSDictionary *resp = vp_handle_apps_command(msg);
          if (resp && !vp_write_message(fd, resp))
            break;
          continue;
        }

        // URL opening
        if ([t isEqualToString:@"open_url"]) {
          NSDictionary *resp = vp_handle_url_command(msg);
          if (resp && !vp_write_message(fd, resp))
            break;
          continue;
        }

        // Settings operations
        if ([t hasPrefix:@"settings_"]) {
          NSDictionary *resp = vp_handle_settings_command(msg);
          if (resp && !vp_write_message(fd, resp))
            break;
          continue;
        }

        // Accessibility tree
        if ([t isEqualToString:@"accessibility_tree"]) {
          NSDictionary *resp = vp_handle_accessibility_command(msg);
          if (resp && !vp_write_message(fd, resp))
            break;
          continue;
        }

        // Low power mode sync
        if ([t isEqualToString:@"low_power_mode"]) {
          NSDictionary *resp = vp_handle_notify_command(msg);
          if (resp && !vp_write_message(fd, resp))
            break;
          continue;
        }

        NSDictionary *resp = handle_command(msg);
        if (resp && !vp_write_message(fd, resp))
          break;
      }
    }

    NSLog(@"vphoned: client disconnected%s",
          should_restart ? " (restarting for update)" : "");
    close(fd);
  }
  return should_restart;
}

// MARK: - Main

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (argc >= 2 && strcmp(argv[1], "--diag-metal-child") == 0)
      return run_diag_metal_child_main(argc, argv);

    // Bootstrap: if running from install path and a cached update exists, exec
    // it
    const char *selfPath = self_executable_path();
    NSLog(@"vphoned: starting (pid=%d, path=%s)", getpid(), selfPath ?: "?");

#if !LESS
    if (selfPath && strcmp(selfPath, INSTALL_PATH) == 0 &&
        access(CACHE_PATH, X_OK) == 0) {
      NSLog(@"vphoned: found cached binary at %s, exec'ing", CACHE_PATH);
      execv(CACHE_PATH, argv);
      NSLog(@"vphoned: execv failed: %s — continuing with installed binary",
            strerror(errno));
      unlink(CACHE_PATH);
    }
#endif

    int sock = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (sock < 0) {
      perror("vphoned: socket(AF_VSOCK)");
      return 1;
    }

    int one = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_vm addr = {
        .svm_len = sizeof(struct sockaddr_vm),
        .svm_family = AF_VSOCK,
        .svm_port = VPHONED_PORT,
        .svm_cid = VMADDR_CID_ANY,
    };

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
      perror("vphoned: bind");
      close(sock);
      return 1;
    }
    if (listen(sock, 2) < 0) {
      perror("vphoned: listen");
      close(sock);
      return 1;
    }

    NSLog(@"vphoned: listening on vsock port %d", VPHONED_PORT);
    start_optional_services();

    for (;;) {
      int client = accept(sock, NULL, NULL);
      if (client < 0) {
        perror("vphoned: accept");
        sleep(1);
        continue;
      }
      if (handle_client(client)) {
        NSLog(@"vphoned: exiting for update restart");
        close(sock);
        return 0;
      }
    }
  }
}
