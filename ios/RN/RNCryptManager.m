//
//  RNCryptManager.m
//  CryptPic
//
//  Created by Rob Napier on 8/9/11.
//  Copyright (c) 2011 Rob Napier. All rights reserved.
//

#import "RNCryptManager.h"

// According to Apple documentaion, you can use a single buffer
// to do in-place encryption or decryption. This does not work
// in cases where you call CCCryptUpdate multiple times and you
// have padding enabled. radar://9930555
#define RNCRYPTMANAGER_USE_SAME_BUFFER 0

static const NSUInteger kMaxReadSize = 1024;

NSString * const
kRNCryptManagerErrorDomain = @"net.rncamera.RNCryptManager";

const CCAlgorithm kAlgorithm = kCCAlgorithmAES128;
const NSUInteger kAlgorithmKeySize = kCCKeySizeAES128;
const NSUInteger kAlgorithmBlockSize = kCCBlockSizeAES128;
const NSUInteger kAlgorithmIVSize = kCCBlockSizeAES128;
const NSUInteger kPBKDFSaltSize = 8;
const NSUInteger kPBKDFRounds = 10000;  // ~80ms on an iPhone 4

@interface NSOutputStream (Data)
- (BOOL)_CMwriteData:(NSData *)data error:(NSError **)error;
@end

@implementation NSOutputStream (Data)
- (BOOL)_CMwriteData:(NSData *)data error:(NSError **)error {
    // Writing 0 bytes will close the output stream.
    // This is an undocumented side-effect. radar://9930518
    if (data.length > 0) {
        NSInteger bytesWritten = [self write:data.bytes
                                   maxLength:data.length];
        if ( bytesWritten != data.length) {
            if (error) {
                *error = [self streamError];
            }
            return NO;
        }
    }
    return YES;
}

@end

@interface NSInputStream (Data)
- (BOOL)_CMgetData:(NSData **)data
         maxLength:(NSUInteger)maxLength
             error:(NSError **)error;
@end

@implementation NSInputStream (Data)

- (BOOL)_CMgetData:(NSData **)data
         maxLength:(NSUInteger)maxLength
             error:(NSError **)error {
    
    NSMutableData *buffer = [NSMutableData dataWithLength:maxLength];
    if ([self read:buffer.mutableBytes maxLength:maxLength] < 0) {
        if (error) {
            *error = [self streamError];
            return NO;
        }
    }
    
    *data = buffer;
    return YES;
}

@end

@implementation RNCryptManager

+ (BOOL)processResult:(CCCryptorStatus)result
                bytes:(uint8_t*)bytes
               length:(size_t)length
             toStream:(NSOutputStream *)outStream
                error:(NSError **)error {
    
    if (result != kCCSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:kRNCryptManagerErrorDomain
                                         code:result
                                     userInfo:nil];
        }
        // Don't assert here. It could just be a bad password
        NSLog(@"Could not process data: %d", result);
        return NO;
    }
    
    if (length > 0) {
        if ([outStream write:bytes maxLength:length] != length) {
            if (error) {
                *error = [outStream streamError];
            }
            return NO;
        }
    }
    return YES;
}

+ (BOOL)applyOperation:(CCOperation)operation
            fromStream:(NSInputStream *)inStream
              toStream:(NSOutputStream *)outStream
                   key:(NSData *)key
                 error:(NSError **)error {
    
    NSAssert([inStream streamStatus] != NSStreamStatusNotOpen,
             @"fromStream must be open");
    NSAssert([outStream streamStatus] != NSStreamStatusNotOpen,
             @"toStream must be open");
    
    // Create the cryptor
    CCCryptorRef cryptor = NULL;
    CCCryptorStatus result;
    result = CCCryptorCreate(operation,             // operation
                             kAlgorithm,            // algorithim
                             kCCOptionPKCS7Padding, // options
                             key.bytes,             // key
                             key.length,            // keylength
                             0,                     // IV
                             &cryptor);             // OUT cryptorRef
    
    if (result != kCCSuccess || cryptor == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:kRNCryptManagerErrorDomain
                                         code:result
                                     userInfo:nil];
        }
        NSAssert(NO, @"Could not create cryptor: %d", result);
        return NO;
    }
    
    // Calculate the buffer size and create the buffers.
    // The MAX() check isn't really necessary, but is a safety in
    // case RNCRYPTMANAGER_USE_SAME_BUFFER is enabled, since both
    // buffers will be the same. This just guarentees the the read
    // buffer will always be large enough, even during decryption.
    size_t
    dstBufferSize = MAX(CCCryptorGetOutputLength(cryptor, // cryptor
                                                 kMaxReadSize, // input length
                                                 true), // final
                        kMaxReadSize);
    
    NSMutableData *
    dstData = [NSMutableData dataWithLength:dstBufferSize];
    
    NSMutableData *
#if RNCRYPTMANAGER_USE_SAME_BUFFER
    srcData = dstData;
#else
    // See explanation at top of file
    srcData = [NSMutableData dataWithLength:kMaxReadSize];
#endif
    
    uint8_t *srcBytes = srcData.mutableBytes;
    uint8_t *dstBytes = dstData.mutableBytes;
    
    // Read and write the data in blocks
    ssize_t srcLength;
    size_t dstLength = 0;
    
    while ((srcLength = [inStream read:srcBytes
                             maxLength:kMaxReadSize]) > 0 ) {
        result = CCCryptorUpdate(cryptor,       // cryptor
                                 srcBytes,      // dataIn
                                 srcLength,     // dataInLength
                                 dstBytes,      // dataOut
                                 dstBufferSize, // dataOutAvailable
                                 &dstLength);   // dataOutMoved
        
        if (![self processResult:result
                           bytes:dstBytes
                          length:dstLength
                        toStream:outStream
                           error:error]) {
            CCCryptorRelease(cryptor);
            return NO;
        }
    }
    if (srcLength != 0) {
        if (error) {
            *error = [inStream streamError];
            return NO;
        }
    }
    
    // Write the final block
    result = CCCryptorFinal(cryptor,        // cryptor
                            dstBytes,       // dataOut
                            dstBufferSize,  // dataOutAvailable
                            &dstLength);    // dataOutMoved
    if (![self processResult:result
                       bytes:dstBytes
                      length:dstLength
                    toStream:outStream
                       error:error]) {
        CCCryptorRelease(cryptor);
        return NO;
    }
    
    CCCryptorRelease(cryptor);
    return YES;
}

+ (BOOL)encryptFromStream:(NSInputStream *)fromStream
                 toStream:(NSOutputStream *)toStream
                      key:(NSData *)key
                    error:(NSError **)error {
    return [self applyOperation:kCCEncrypt
                     fromStream:fromStream
                       toStream:toStream
                            key:key
                          error:error];
}

+ (BOOL)decryptFromStream:(NSInputStream *)fromStream
                 toStream:(NSOutputStream *)toStream
                      key:(NSData *)key
                    error:(NSError **)error {
    return [self applyOperation:kCCDecrypt
                     fromStream:fromStream
                       toStream:toStream
                            key:key
                          error:error];
}

@end
