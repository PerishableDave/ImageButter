//
//  WebPDecodeOperation.m
//  ImageButter
//
//  Created by David Peredo on 8/4/16.
//  Copyright © 2016 Dollar Shave Club. All rights reserved.
//

#import "WebPDecodeOperation.h"

@implementation WebPDecodeOperationResult

@end

@interface WebPDecodeOperation ()

@property(nonatomic)BOOL decoding;
@property(nonatomic)NSData *data;
@property(nonatomic)WebPDecodeProgress progressCallback;

@end

@implementation WebPDecodeOperation

- (instancetype)initWithData:(NSData *)data result:(WebPDecodeOperationResult *)result {
    if (self = [super init]) {
        _data = data;
        _result = result;
    }
    return self;
}

- (instancetype)initWithData:(NSData *)data result:(WebPDecodeOperationResult *)result progress:(WebPDecodeProgress)progress {
    if (self = [super init]) {
        _data = data;
        _result = result;
        _progressCallback = progress;
    }
    return self;
}

- (void)start {
    if ([self isCancelled] || [self isFinished]) {
        return;
    }
    
    [self willChangeValueForKey:@"executing"];
    self.decoding = true;
    [self didChangeValueForKey:@"executing"];
    
    [self main];
    
    [self willChangeValueForKey:@"executing"];
    self.decoding = false;
    [self didChangeValueForKey:@"executing"];
    [self willChangeValueForKey:@"finished"];
    [self didChangeValueForKey:@"finished"];
}

- (void)main {
    self.result.image = [[WebPImage alloc] initWithData:self.data];
}

- (BOOL)isAsynchronous {
    return YES;
}

- (BOOL)isExecuting {
    return self.decoding;
}

- (BOOL)isFinished {
    return self.result.image != nil;
}

@end
