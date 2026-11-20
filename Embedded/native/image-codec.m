#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <node_api.h>
#import <math.h>

// ImageIO applies EXIF orientation when creating the thumbnail. Drawing into a
// fresh sRGB bitmap strips source metadata and preserves transparent pixels.
napi_value image_codec(napi_env env, napi_callback_info info) {
    @autoreleasepool {
        size_t argc = 4, length;
        napi_value args[4], result, value;
        void *bytes;
        uint32_t maxSide, maxPixels, maxBytes;
        if (napi_get_cb_info(env, info, &argc, args, NULL, NULL) != napi_ok || argc != 4 ||
            napi_get_buffer_info(env, args[0], &bytes, &length) != napi_ok ||
            napi_get_value_uint32(env, args[1], &maxSide) != napi_ok ||
            napi_get_value_uint32(env, args[2], &maxPixels) != napi_ok ||
            napi_get_value_uint32(env, args[3], &maxBytes) != napi_ok) {
            napi_throw_type_error(env, NULL, "invalid image arguments");
            return NULL;
        }
        NSData *input = [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:NO];
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)input, NULL);
        NSDictionary *props = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
        NSString *uti = source ? (__bridge NSString *)CGImageSourceGetType(source) : nil;
        NSString *mime = uti ? @{@"public.png": @"image/png", @"public.jpeg": @"image/jpeg",
                                  @"org.webmproject.webp": @"image/webp", @"com.compuserve.gif": @"image/gif"}[uti] : nil;
        unsigned w = [props[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntValue];
        unsigned h = [props[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntValue];
        if (!mime || !w || !h || CGImageSourceGetStatus(source) != kCGImageStatusComplete) {
            if (source) CFRelease(source);
            napi_throw_error(env, "INVALID_IMAGE", "Incomplete or unsupported image");
            return NULL;
        }
        BOOL alpha = [props[(__bridge NSString *)kCGImagePropertyHasAlpha] boolValue];
        if ([props[(__bridge NSString *)kCGImagePropertyOrientation] unsignedIntValue] >= 5) {
            unsigned swap = w; w = h; h = swap;
        }
        napi_create_object(env, &result);
        if (maxSide && maxPixels) {
            double scale = MIN(1., MIN((double)maxSide / MAX(w,h), sqrt((double)maxPixels / ((double)w*h))));
            NSDictionary *options = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(MAX(1, floor(MAX(w,h)*scale)))};
            CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
            if (thumbnail && CGImageSourceGetStatusAtIndex(source, 0) == kCGImageStatusComplete) {
                w = (unsigned)CGImageGetWidth(thumbnail);
                h = (unsigned)CGImageGetHeight(thumbnail);
                CGImageAlphaInfo a = CGImageGetAlphaInfo(thumbnail);
                alpha = a == kCGImageAlphaPremultipliedFirst || a == kCGImageAlphaPremultipliedLast ||
                        a == kCGImageAlphaFirst || a == kCGImageAlphaLast || a == kCGImageAlphaOnly;
            } else {
                if (thumbnail) CGImageRelease(thumbnail);
                CFRelease(source);
                napi_throw_error(env, "INVALID_IMAGE", "Unable to decode image");
                return NULL;
            }
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef bitmap = CGBitmapContextCreate(NULL, w, h, 8, 0, space,
                (CGBitmapInfo)(alpha ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNoneSkipLast));
            CGColorSpaceRelease(space);
            CGImageRef image = NULL;
            if (bitmap) {
                CGContextDrawImage(bitmap, CGRectMake(0,0,w,h), thumbnail);
                image = CGBitmapContextCreateImage(bitmap);
                CGContextRelease(bitmap);
            }
            CGImageRelease(thumbnail);
            NSMutableData *encoded = nil;
            if (image) {
                for (NSNumber *quality in @[@0.90, @0.75, @0.55, @0.35]) {
                    NSMutableData *candidate = [NSMutableData data];
                    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)candidate,
                        alpha ? CFSTR("public.png") : CFSTR("public.jpeg"), 1, NULL);
                    if (!dst) break;
                    CGImageDestinationAddImage(dst, image, (__bridge CFDictionaryRef)@{
                        (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: quality});
                    BOOL success = CGImageDestinationFinalize(dst);
                    CFRelease(dst);
                    if (!success) break;
                    if (!encoded || candidate.length < encoded.length) encoded = candidate;
                    if (alpha || encoded.length <= maxBytes) break;
                }
                CGImageRelease(image);
            }
            if (!encoded) {
                CFRelease(source);
                napi_throw_error(env, "ATTACHMENT_WRITE_FAILED", "Unable to encode image");
                return NULL;
            }
            mime = alpha ? @"image/png" : @"image/jpeg";
            napi_create_buffer_copy(env, encoded.length, encoded.bytes, NULL, &value);
            napi_set_named_property(env, result, "data", value);
        }
        CFRelease(source);
        napi_create_string_utf8(env, mime.UTF8String, NAPI_AUTO_LENGTH, &value);
        napi_set_named_property(env, result, "mediaType", value);
        napi_create_uint32(env, w, &value); napi_set_named_property(env, result, "width", value);
        napi_create_uint32(env, h, &value); napi_set_named_property(env, result, "height", value);
        napi_get_boolean(env, alpha, &value); napi_set_named_property(env, result, "hasAlpha", value);
        return result;
    }
}
