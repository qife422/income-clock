// Read/select existing keyboard input sources using public Carbon TIS only.
// No source enable/disable/install/remove or direct preference writes.
#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

// Read-only context: no activation, focus mutation, permission prompt or field values.
static NSDictionary *FocusContext(void) {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSMutableDictionary *record = [@{@"frontPID": @(front.processIdentifier),
        @"frontBundle": front.bundleIdentifier ?: @"", @"axTrusted": @(AXIsProcessTrusted())} mutableCopy];
    AXUIElementRef app = AXUIElementCreateApplication(front.processIdentifier);
    AXUIElementSetMessagingTimeout(app, 0.15);
    CFTypeRef focused = NULL;
    AXError error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused);
    record[@"focusError"] = @(error);
    if (focused && CFGetTypeID(focused) == AXUIElementGetTypeID()) {
        for (NSString *attribute in @[@"AXRole", @"AXSubrole", @"AXIdentifier"]) {
            CFTypeRef value = NULL;
            AXError result = AXUIElementCopyAttributeValue((AXUIElementRef)focused, (__bridge CFStringRef)attribute, &value);
            record[[attribute stringByAppendingString:@"Error"]] = @(result);
            if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
                NSString *text = (__bridge NSString *)value;
                record[attribute] = [text substringToIndex:MIN(text.length, 160)];
            }
            if (value) CFRelease(value);
        }
    }
    if (focused) CFRelease(focused);
    CFRelease(app);
    return record;
}

static BOOL TargetIdentifierAllowed(NSString *identifier) {
    return [identifier isEqualToString:@"com.apple.keylayout.ABC"] ||
           [identifier isEqualToString:@"com.apple.keylayout.US"];
}

static NSString *TextProperty(TISInputSourceRef source, CFStringRef key) {
    if (!source) return nil;
    CFTypeRef value = TISGetInputSourceProperty(source, key);
    return value && CFGetTypeID(value) == CFStringGetTypeID() ? (__bridge NSString *)value : nil;
}
static BOOL BoolProperty(TISInputSourceRef source, CFStringRef key) {
    if (!source) return NO;
    CFTypeRef value = TISGetInputSourceProperty(source, key);
    return value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
}
static BOOL ValidIdentifier(NSString *value) {
    return value.length > 0 && value.length <= 512 &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static NSString *CurrentIdentifier(void) {
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    NSString *identifier = [TextProperty(source, kTISPropertyInputSourceID) copy];
    if (source) CFRelease(source);
    return identifier;
}
// A retained unique enabled/selectable keyboard source, or NULL. includeAllInstalled
// is deliberately false; never enable a source to make a lookup succeed.
static TISInputSourceRef CopyAvailableSource(NSString *identifier) {
    NSDictionary *filter = @{
        (__bridge NSString *)kTISPropertyInputSourceID: identifier,
        (__bridge NSString *)kTISPropertyInputSourceCategory: (__bridge NSString *)kTISCategoryKeyboardInputSource
    };
    CFArrayRef sources = TISCreateInputSourceList((__bridge CFDictionaryRef)filter, false);
    if (!sources) return NULL;
    TISInputSourceRef found = NULL;
    CFIndex matches = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(sources); i++) {
        TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(sources, i);
        if ([TextProperty(source, kTISPropertyInputSourceID) isEqualToString:identifier] &&
            BoolProperty(source, kTISPropertyInputSourceIsEnabled) &&
            BoolProperty(source, kTISPropertyInputSourceIsSelectCapable)) {
            matches++;
            found = source;
        }
    }
    TISInputSourceRef result = matches == 1 ? (TISInputSourceRef)CFRetain(found) : NULL;
    CFRelease(sources);
    return result;
}
static int Emit(NSDictionary *record, int code) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:&error];
    if (!data || data.length > 8192) return 70;
    NSFileHandle *output = NSFileHandle.fileHandleWithStandardOutput;
    [output writeData:data];
    [output writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    return code;
}
static int SelectAndVerify(NSString *target, NSString *expectedBefore, BOOL requireASCII) {
    NSString *before = CurrentIdentifier();
    if (!ValidIdentifier(before) || (expectedBefore && ![before isEqualToString:expectedBefore])) {
        return Emit(@{@"ok": @NO, @"error": @"current-source-changed-before-selection",
                      @"beforeID": before ?: @"", @"targetID": target}, 3);
    }
    TISInputSourceRef source = CopyAvailableSource(target);
    if (!source) return Emit(@{@"ok": @NO, @"error": @"source-not-uniquely-enabled-and-selectable",
                               @"beforeID": before, @"targetID": target}, 4);
    if (requireASCII && !BoolProperty(source, kTISPropertyInputSourceIsASCIICapable)) {
        CFRelease(source);
        return Emit(@{@"ok": @NO, @"error": @"target-is-not-ascii-capable", @"targetID": target}, 4);
    }
    OSStatus status = [before isEqualToString:target] ? noErr : TISSelectInputSource(source);
    CFRelease(source);
    NSString *after = CurrentIdentifier();
    // One selection call; bounded observation only, never repeated mutation.
    for (int i = 0; status == noErr && ![after isEqualToString:target] && i < 40; i++) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        after = CurrentIdentifier();
    }
    BOOL verified = status == noErr && [after isEqualToString:target];
    return Emit(@{@"ok": @(verified), @"beforeID": before, @"targetID": target,
                  @"afterID": after ?: @"", @"osStatus": @(status),
                  @"selectionCalled": @(![before isEqualToString:target])}, verified ? 0 : 5);
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 64;
        NSString *operation = [NSString stringWithUTF8String:argv[1]];
        if ([operation isEqualToString:@"snapshot"] && argc == 3) {
            NSString *target = [NSString stringWithUTF8String:argv[2]];
            if (!TargetIdentifierAllowed(target)) return 64;
            NSString *current = CurrentIdentifier();
            if (!ValidIdentifier(current)) return Emit(@{@"ok": @NO, @"error": @"current-source-id-unavailable"}, 2);
            TISInputSourceRef original = CopyAvailableSource(current);
            TISInputSourceRef requested = CopyAvailableSource(target);
            BOOL originalAvailable = original != NULL;
            BOOL targetAvailable = requested && BoolProperty(requested, kTISPropertyInputSourceIsASCIICapable);
            if (original) CFRelease(original);
            if (requested) CFRelease(requested);
            return Emit(@{@"ok": @YES, @"currentID": current, @"originalAvailable": @(originalAvailable),
                          @"targetID": target, @"targetAvailable": @(targetAvailable),
                          @"context": FocusContext()}, 0);
        }
        if ([operation isEqualToString:@"select"] && argc == 4) {
            NSString *target = [NSString stringWithUTF8String:argv[2]];
            NSString *expectedOriginal = [NSString stringWithUTF8String:argv[3]];
            if (!TargetIdentifierAllowed(target) || !ValidIdentifier(expectedOriginal)) return 64;
            return SelectAndVerify(target, expectedOriginal, YES);
        }
        if ([operation isEqualToString:@"restore"] && argc == 3) {
            NSString *original = [NSString stringWithUTF8String:argv[2]];
            if (!ValidIdentifier(original)) return 64;
            // The original may be an IME; never demand ASCII when restoring it.
            return SelectAndVerify(original, nil, NO);
        }
        return 64;
    }
}
