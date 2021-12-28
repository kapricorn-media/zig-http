#include <Foundation/Foundation.h>
#include <Security/Security.h>

int getRootCaCerts(void* userData, void (*callback)(void* userData, const unsigned char* bytes, size_t length))
{
    // Load keychain
    SecKeychainRef keychain;
    if (SecKeychainOpen("/System/Library/Keychains/SystemRootCertificates.keychain", &keychain) != errSecSuccess) {
        return 1;
    }

    // Search for certificates
    CFMutableDictionaryRef search = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    CFDictionarySetValue(search, kSecClass, kSecClassCertificate);
    CFDictionarySetValue(search, kSecMatchLimit, kSecMatchLimitAll);
    CFDictionarySetValue(search, kSecReturnRef, kCFBooleanTrue);
    CFDictionarySetValue(search, kSecMatchSearchList, CFArrayCreate(NULL, (const void **)&keychain, 1, NULL));

    CFArrayRef result;
    if (SecItemCopyMatching(search, (CFTypeRef *)&result) == errSecSuccess) {
        CFIndex n = CFArrayGetCount(result);
        for (CFIndex i = 0; i < n; i++) {
            SecCertificateRef item = (SecCertificateRef)CFArrayGetValueAtIndex(result, i);

            // Get certificate in DER format
            CFDataRef data = SecCertificateCopyData(item);
            if (data) {
                const unsigned char* bytes = (unsigned char*)CFDataGetBytePtr(data);
                const size_t length = CFDataGetLength(data);
                callback(userData, bytes, length);
                CFRelease(data);
            }
        }
    }

    CFRelease(keychain);

    return 0;
}
