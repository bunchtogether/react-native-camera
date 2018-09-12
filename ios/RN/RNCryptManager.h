//
//  RNCryptManager.h
//
//
//  Originally created by Rob Napier on 8/9/11.
//  Copyright (c) 2011 Rob Napier. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonKeyDerivation.h>

extern NSString * const kRNCryptManagerErrorDomain;

@interface RNCryptManager : NSObject

+ (BOOL)encryptFromStream:(NSInputStream *)fromStream
                 toStream:(NSOutputStream *)toStream
                      key:(NSData *)key
                    error:(NSError **)error;

+ (BOOL)decryptFromStream:(NSInputStream *)fromStream
                 toStream:(NSOutputStream *)toStream
                      key:(NSData *)key
                    error:(NSError **)error;

@end
