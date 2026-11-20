#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <node_api.h>

// Each logical credential document has its own keychain item. Node supplies
// the sandbox-relative path so reinstalling an update cannot change its name.
static NSString *const kDocuments = @"dsh-local.embedded.credentials";
static NSString *const kFormerDocuments = @"dsh-go-local.embedded.credentials";

// Moves one item kept under a service name from before the rename; the old item goes only once
// the new one is written.
static void adopt_former(NSString *formerService, NSString *service, NSString *account, CFStringRef accessible) {
    NSDictionary *old = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:formerService, (__bridge id)kSecAttrAccount:account};
    NSMutableDictionary *lookup = [old mutableCopy];
    lookup[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef value = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)lookup, &value) != errSecSuccess) return;
    NSData *data = CFBridgingRelease(value);
    NSDictionary *add = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:service, (__bridge id)kSecAttrAccount:account,
        (__bridge id)kSecValueData:data, (__bridge id)kSecAttrAccessible:(__bridge id)accessible};
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (status == errSecSuccess || status == errSecDuplicateItem) SecItemDelete((__bridge CFDictionaryRef)old);
}

napi_value credential_document(napi_env env, napi_callback_info info) {
    napi_value args[2], result;
    size_t count = 2, length = 0;
    napi_get_cb_info(env, info, &count, args, NULL, NULL);
    if (count < 1 || napi_get_value_string_utf8(env, args[0], NULL, 0, &length) != napi_ok || length > 4096) {
        napi_throw_type_error(env, NULL, "invalid credential store name");
        return NULL;
    }
    NSMutableData *name = [NSMutableData dataWithLength:length + 1];
    napi_get_value_string_utf8(env, args[0], name.mutableBytes, name.length, NULL);
    NSString *account = [[NSString alloc] initWithBytes:name.bytes length:length encoding:NSUTF8StringEncoding];
    adopt_former(kFormerDocuments, kDocuments, account, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
    NSMutableDictionary *query = [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:kDocuments, (__bridge id)kSecAttrAccount:account} mutableCopy];
    OSStatus status;
    if (count == 1) {
        query[(__bridge id)kSecReturnData] = @YES;
        CFTypeRef value = NULL;
        status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &value);
        NSData *data = CFBridgingRelease(value);
        if (status == errSecItemNotFound) { napi_get_undefined(env, &result); return result; }
        if (status == errSecSuccess) {
            napi_create_string_utf8(env, data.bytes, data.length, &result);
            return result;
        }
    } else {
        if (napi_get_value_string_utf8(env, args[1], NULL, 0, &length) != napi_ok) {
            napi_throw_type_error(env, NULL, "invalid credential document");
            return NULL;
        }
        NSMutableData *data = [NSMutableData dataWithLength:length + 1];
        napi_get_value_string_utf8(env, args[1], data.mutableBytes, data.length, NULL);
        data.length = length;
        NSDictionary *update = @{(__bridge id)kSecValueData:data,
            (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
        status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
        if (status == errSecItemNotFound) {
            [query addEntriesFromDictionary:update];
            status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        }
        if (status == errSecSuccess) { napi_get_undefined(env, &result); return result; }
    }
    napi_throw_error(env, "EKEYCHAIN", [NSString stringWithFormat:@"credential store unavailable (%d)", (int)status].UTF8String);
    return NULL;
}

// The app's own keychain service (`Vault` in the app), which also moves its former items over.
napi_value account_token(napi_env env, napi_callback_info info) {
    adopt_former(@"dsh-go-local", @"dsh-local", @"deepseek-platform-account", kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"dsh-local", (__bridge id)kSecAttrAccount:@"deepseek-platform-account",
        (__bridge id)kSecReturnData:@YES};
    CFTypeRef item = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &item);
    NSData *data = CFBridgingRelease(item);
    napi_value token;
    if (status == errSecItemNotFound || (status == errSecSuccess && !data.length)) napi_get_undefined(env, &token);
    else if (status == errSecSuccess) napi_create_string_utf8(env, data.bytes, data.length, &token);
    else { napi_throw_error(env, "EKEYCHAIN", "account credential unavailable"); return NULL; }
    return token;
}
