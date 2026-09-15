#import <Cocoa/Cocoa.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <ServiceManagement/ServiceManagement.h>

static const NSInteger kMC203Vendor = 0x3554;
static const NSInteger kMC203Receiver = 0xF5D5;
static const NSInteger kMC203Wired = 0xF511;

static NSInteger HIDInteger(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    return [(__bridge NSNumber *)value integerValue];
}

static NSString *HexBytes(const uint8_t *bytes, CFIndex length) {
    NSMutableArray *items = [NSMutableArray array];
    for (CFIndex i = 0; i < length; i++) [items addObject:[NSString stringWithFormat:@"%02X", bytes[i]]];
    return [items componentsJoinedByString:@" "];
}

static uint8_t PacketChecksum(const uint8_t *bytes, CFIndex length) {
    uint8_t sum = 0;
    for (CFIndex i = 0; i < length; i++) sum += bytes[i];
    return (uint8_t)(0x55 - sum);
}

static void MC203Packet(uint8_t command, BOOL enabled, uint8_t packet[17]) {
    memset(packet, 0, 17);
    packet[0] = 0x08;
    packet[1] = command;
    if (command == 0x02) { packet[5] = 0x01; packet[6] = enabled ? 0x01 : 0x00; }
    packet[16] = PacketChecksum(packet, 16);
}

static NSInteger PercentageFromMillivolts(NSInteger mv, BOOL charging) {
    static const NSInteger points[] = {3050,3420,3480,3540,3600,3660,3720,3760,3800,3840,3880,3920,3940,3960,3980,4000,4020,4040,4060,4080,4110};
    const NSInteger count = sizeof(points) / sizeof(points[0]);
    // Fun voltage extension: 4110 mV remains 100%; above that, every roughly
    // 18 mV contributes one displayed point, capped at 120%. This represents
    // voltage headroom only, not battery capacity beyond 100%.
    if (mv >= points[count - 1]) return MIN(120, 100 + (mv - points[count - 1]) / 18);
    if (mv < points[0]) return 0;
    for (NSInteger i = 1; i < count; i++) if (mv < points[i]) {
        NSInteger result = (i - 1) * 5 + (mv - points[i - 1]) * 5 / (points[i] - points[i - 1]);
        return result == 15 ? 16 : MAX(0, MIN(100, result));
    }
    return 100;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate> {
    uint8_t _inputBuffer[128];
    IOHIDDeviceRef _device;
    BOOL _sessionReady;
}
@property NSStatusItem *statusItem;
@property NSMenuItem *batteryItem;
@property NSMenuItem *permissionItem;
@property NSMenuItem *loginItem;
@property NSTimer *refreshTimer;
@property NSTimer *replyTimer;
@property NSTimer *sessionTimer;
@property NSTimer *permissionTimer;
@property IOHIDManagerRef manager;
@property BOOL connected;
@property BOOL readable;
@property NSInteger percentage;
@property NSInteger millivolts;
@property BOOL charging;
@property BOOL fullyCharged;
@property NSDate *updated;
@property NSString *error;
@property NSMutableArray<NSString *> *diagnostics;
@property NSDateFormatter *dateFormatter;
@property BOOL showedPermissionAlert;
- (void)handleReport:(uint32_t)reportID bytes:(const uint8_t *)bytes length:(CFIndex)length result:(IOReturn)result;
@end

static void InputReport(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex length) {
    (void)sender; (void)type;
    AppDelegate *delegate = (__bridge AppDelegate *)context;
    [delegate handleReport:reportID bytes:report length:length result:result];
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.diagnostics = [NSMutableArray array];
    self.dateFormatter = [NSDateFormatter new];
    self.dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    self.dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.toolTip = @"鼠标电量（TAIDU MC203）";
    self.statusItem.menu = [self menu];
    [self updateDisplay];
    [self log:@"应用启动；只读取 TAIDU MC203 的原厂电量状态报告，不记录鼠标移动、按键或其他输入。"];
    [self checkPermission];
    // Ten seconds detects a cable change promptly without continually waking
    // the mouse or receiver, which one-second polling could do.
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
}

- (NSMenu *)menu {
    NSMenu *menu = [NSMenu new]; menu.delegate = self;
    self.batteryItem = [[NSMenuItem alloc] initWithTitle:@"MC203：检测中…" action:nil keyEquivalent:@""];
    [menu addItem:self.batteryItem]; [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"立即刷新" action:@selector(refresh:) keyEquivalent:@"r"]; refresh.target = self; [menu addItem:refresh];
    self.permissionItem = [[NSMenuItem alloc] initWithTitle:@"输入监控权限：检查中…" action:@selector(openSettings:) keyEquivalent:@""]; self.permissionItem.target = self; [menu addItem:self.permissionItem];
    self.loginItem = [[NSMenuItem alloc] initWithTitle:@"开机自动启动" action:@selector(toggleLogin:) keyEquivalent:@""]; self.loginItem.target = self; [menu addItem:self.loginItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *copy = [[NSMenuItem alloc] initWithTitle:@"复制诊断信息" action:@selector(copyDiagnostics:) keyEquivalent:@""]; copy.target = self; [menu addItem:copy];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"退出鼠标电量" action:@selector(terminate:) keyEquivalent:@"q"]];
    return menu;
}

- (void)menuWillOpen:(NSMenu *)menu { [self updatePermission]; [self updateLogin]; [self updateDisplay]; }
- (void)log:(NSString *)line { [self.diagnostics addObject:[NSString stringWithFormat:@"[%@] %@", [self.dateFormatter stringFromDate:NSDate.date], line]]; if (self.diagnostics.count > 200) [self.diagnostics removeObjectAtIndex:0]; }

- (void)checkPermission {
    IOHIDAccessType access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    [self log:[NSString stringWithFormat:@"输入监控权限状态：%ld", (long)access]];
    if (access == kIOHIDAccessTypeUnknown) { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent); access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent); }
    [self updatePermission];
    if (access == kIOHIDAccessTypeGranted) { [self startManager]; return; }
    if (!self.showedPermissionAlert) { self.showedPermissionAlert = YES; dispatch_async(dispatch_get_main_queue(), ^{ NSAlert *alert = [NSAlert new]; alert.messageText = @"需要允许“输入监控”"; alert.informativeText = @"macOS 将 MC203 接收器的电量状态归入此权限。鼠标电量只读取指定的状态报告，不记录鼠标移动或按键。"; [alert addButtonWithTitle:@"打开系统设置"]; [alert addButtonWithTitle:@"稍后"]; if ([alert runModal] == NSAlertFirstButtonReturn) [self openSettings:nil]; }); }
    __weak typeof(self) weak = self;
    self.permissionTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted) { [t invalidate]; weak.permissionTimer = nil; [weak startManager]; } [weak updatePermission]; }];
}

- (void)updatePermission { IOHIDAccessType access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent); BOOL ok = access == kIOHIDAccessTypeGranted; self.permissionItem.title = ok ? @"输入监控权限：已允许" : @"输入监控权限：点此打开设置"; self.permissionItem.enabled = !ok; }
- (void)openSettings:(id)sender { [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]]; }

- (void)startManager {
    if (self.manager) return;
    self.manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *matches = @[@{ @kIOHIDVendorIDKey:@(kMC203Vendor), @kIOHIDProductIDKey:@(kMC203Receiver) }, @{ @kIOHIDVendorIDKey:@(kMC203Vendor), @kIOHIDProductIDKey:@(kMC203Wired) }];
    IOHIDManagerSetDeviceMatchingMultiple(self.manager, (__bridge CFArrayRef)matches);
    IOHIDManagerScheduleWithRunLoop(self.manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn r = IOHIDManagerOpen(self.manager, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) { [self log:[NSString stringWithFormat:@"打开 HID 管理器失败：0x%08X", r]]; CFRelease(self.manager); self.manager = NULL; return; }
    [self refresh:nil];
}

- (void)refresh:(id)sender {
    if (!self.manager) return;
    IOHIDDeviceRef found = NULL; CFSetRef set = IOHIDManagerCopyDevices(self.manager);
    for (id obj in (__bridge NSSet *)set) {
        IOHIDDeviceRef candidate = (__bridge IOHIDDeviceRef)obj;
        NSInteger vendor = HIDInteger(candidate, CFSTR(kIOHIDVendorIDKey));
        NSInteger product = HIDInteger(candidate, CFSTR(kIOHIDProductIDKey));
        NSInteger maxInput = HIDInteger(candidate, CFSTR(kIOHIDMaxInputReportSizeKey));
        NSInteger maxOutput = HIDInteger(candidate, CFSTR(kIOHIDMaxOutputReportSizeKey));
        // The receiver exposes ordinary mouse/keyboard collections as well as
        // its vendor status collection. Only the latter can exchange the
        // 17-byte report-8 battery packets.
        if (vendor == kMC203Vendor && (product == kMC203Receiver || product == kMC203Wired) && maxInput >= 17 && maxOutput >= 17) { found = candidate; break; }
    }
    if (set) CFRelease(set); self.connected = found != NULL; [self configureDevice:found]; if (_sessionReady) [self requestBattery]; [self updateDisplay];
}

- (void)configureDevice:(IOHIDDeviceRef)device {
    if (_device == device) return;
    [self.replyTimer invalidate]; [self.sessionTimer invalidate]; self.replyTimer = self.sessionTimer = nil; _sessionReady = NO; self.readable = NO; self.error = nil;
    if (_device) { [self sendSession:NO]; IOHIDDeviceClose(_device, kIOHIDOptionsTypeNone); CFRelease(_device); _device = NULL; }
    if (!device) { self.error = @"未连接"; return; }
    CFRetain(device); _device = device; IOReturn r = IOHIDDeviceOpen(_device, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) { self.error = [NSString stringWithFormat:@"无法打开（0x%08X）", r]; return; }
    IOHIDDeviceRegisterInputReportCallback(_device, _inputBuffer, sizeof(_inputBuffer), InputReport, (__bridge void *)self);
    [self log:[NSString stringWithFormat:@"MC203 状态通道已打开（%@）。", HIDInteger(device, CFSTR(kIOHIDProductIDKey)) == kMC203Wired ? @"USB 有线" : @"2.4G 接收器"]];
    if (![self sendSession:YES]) { _sessionReady = YES; return; }
    __weak typeof(self) weak = self; self.sessionTimer = [NSTimer scheduledTimerWithTimeInterval:.12 repeats:NO block:^(NSTimer *t) { AppDelegate *strong = weak; if (!strong) return; [strong sendOnline]; strong.sessionTimer = [NSTimer scheduledTimerWithTimeInterval:.15 repeats:NO block:^(NSTimer *u) { AppDelegate *inner = weak; if (!inner) return; inner.sessionTimer = nil; inner->_sessionReady = YES; [inner requestBattery]; }]; }];
}

- (BOOL)sendPacket:(uint8_t)command enabled:(BOOL)enabled label:(NSString *)label {
    if (!_device) return NO; uint8_t packet[17]; MC203Packet(command, enabled, packet); IOReturn r = IOHIDDeviceSetReport(_device, kIOHIDReportTypeOutput, 0x08, packet, sizeof(packet));
    [self log:r == kIOReturnSuccess ? [NSString stringWithFormat:@"MC203 %@：%@", label, HexBytes(packet, 17)] : [NSString stringWithFormat:@"MC203 %@失败：0x%08X", label, r]]; return r == kIOReturnSuccess;
}
- (BOOL)sendSession:(BOOL)connected { return [self sendPacket:0x02 enabled:connected label:connected ? @"原厂会话已开启" : @"原厂会话已关闭"]; }
- (BOOL)sendOnline { return [self sendPacket:0x03 enabled:NO label:@"在线状态查询已发送"]; }

- (void)requestBattery {
    if (!_device || !_sessionReady) return; [self.replyTimer invalidate];
    if (![self sendPacket:0x04 enabled:NO label:@"电量查询已发送"]) { self.readable = NO; self.error = @"查询发送失败"; [self updateDisplay]; return; }
    __weak typeof(self) weak = self; self.replyTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) { weak.readable = NO; weak.charging = weak.fullyCharged = NO; weak.error = @"本次查询未收到回复（可能休眠或离线）"; weak.replyTimer = nil; [weak log:@"MC203 查询超时：旧电量不再显示为当前电量。 "]; [weak updateDisplay]; }];
}

- (void)handleReport:(uint32_t)reportID bytes:(const uint8_t *)bytes length:(CFIndex)length result:(IOReturn)result {
    if (result != kIOReturnSuccess || reportID != 0x08 || length < 17 || bytes[0] != 0x08 || bytes[1] != 0x04 || PacketChecksum(bytes, 16) != bytes[16] || bytes[7] > 2) return;
    NSInteger mv = ((NSInteger)bytes[8] << 8) | bytes[9]; if (mv < 2500 || mv > 5000) return;
    [self.replyTimer invalidate]; self.replyTimer = nil; self.readable = YES; self.percentage = PercentageFromMillivolts(mv, bytes[7] == 1); self.millivolts = mv; self.charging = bytes[7] == 1; self.fullyCharged = bytes[7] == 2; self.updated = NSDate.date; self.error = nil;
    [self log:[NSString stringWithFormat:@"MC203 已解码：%ld%% / %ld mV / %@。", (long)self.percentage, (long)mv, self.charging ? @"充电中" : (self.fullyCharged ? @"已充满" : @"放电中")]]; [self updateDisplay];
}

- (NSAttributedString *)symbol:(NSString *)name green:(BOOL)green {
    NSImageSymbolConfiguration *c = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
    if (green) c = [c configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.systemGreenColor]]];
    NSImage *image = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:name] imageWithSymbolConfiguration:c]; image.template = !green; image.size = NSMakeSize(11, 14); NSTextAttachment *a = [NSTextAttachment new]; a.image = image; a.bounds = NSMakeRect(0, -2, 11, 14); return [NSAttributedString attributedStringWithAttachment:a];
}
- (NSString *)reading { if (self.readable) return [NSString stringWithFormat:@"%ld%%", (long)self.percentage]; return @"—"; }
- (void)updateDisplay {
    NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:15 weight:NSFontWeightMedium], NSForegroundColorAttributeName:NSColor.labelColor}; NSMutableAttributedString *title = [NSMutableAttributedString new]; [title appendAttributedString:[self symbol:@"computermouse" green:NO]]; [title appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" %@", self.reading] attributes:attrs]]; if (self.readable && self.charging) { [title appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:attrs]]; [title appendAttributedString:[self symbol:@"bolt.fill" green:YES]]; } self.statusItem.button.attributedTitle = title;
    NSString *detail = self.readable ? [NSString stringWithFormat:@"%ld%%%@ · %ld mV%@", (long)self.percentage, self.charging ? @"（充电中）" : (self.fullyCharged ? @"（已充满）" : @""), (long)self.millivolts, self.updated ? [NSString stringWithFormat:@" · %.0f 秒前更新", MAX(0, -self.updated.timeIntervalSinceNow)] : @""] : (self.connected ? (self.error ?: @"未能读取") : @"未连接"); self.batteryItem.title = [NSString stringWithFormat:@"MC203：%@", detail];
}

- (void)updateLogin { if (@available(macOS 13.0, *)) self.loginItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff; }
- (void)toggleLogin:(id)sender { if (@available(macOS 13.0, *)) { NSError *e = nil; SMAppService *s = SMAppService.mainAppService; BOOL ok = s.status == SMAppServiceStatusEnabled ? [s unregisterAndReturnError:&e] : [s registerAndReturnError:&e]; [self log:ok ? @"开机自动启动设置已更新。" : [NSString stringWithFormat:@"开机自动启动设置失败：%@", e.localizedDescription]]; [self updateLogin]; } }
- (void)copyDiagnostics:(id)sender { NSString *header = @"鼠标电量 1.0.8\\n说明：只记录 TAIDU MC203 的原厂电量状态报告，不记录鼠标移动、按键或其他输入。\\n\\n"; NSPasteboard *p = NSPasteboard.generalPasteboard; [p clearContents]; [p setString:[header stringByAppendingString:[self.diagnostics componentsJoinedByString:@"\\n"]] forType:NSPasteboardTypeString]; }
- (void)applicationWillTerminate:(NSNotification *)note { [self.replyTimer invalidate]; [self.sessionTimer invalidate]; [self.refreshTimer invalidate]; [self.permissionTimer invalidate]; if (_device) { [self sendSession:NO]; IOHIDDeviceClose(_device, kIOHIDOptionsTypeNone); CFRelease(_device); } if (self.manager) { IOHIDManagerClose(self.manager, kIOHIDOptionsTypeNone); IOHIDManagerUnscheduleFromRunLoop(self.manager, CFRunLoopGetMain(), kCFRunLoopCommonModes); CFRelease(self.manager); } }
@end

int main(void) { @autoreleasepool { NSApplication *app = NSApplication.sharedApplication; AppDelegate *delegate = [AppDelegate new]; app.delegate = delegate; [app run]; } return 0; }
