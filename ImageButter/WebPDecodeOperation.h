//
//  WebPDecodeOperation.h
//  ImageButter
//
//  Created by David Peredo on 8/4/16.
//  Copyright © 2016 Dollar Shave Club. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "WebPImage.h"

@interface WebPDecodeOperationResult : NSObject

@property(nonatomic)WebPImage *image;

@end

@interface WebPDecodeOperation : NSOperation

@property(nonatomic)WebPDecodeOperationResult *result;

- (instancetype)initWithData:(NSData *)data result:(WebPDecodeOperationResult *)result;
- (instancetype)initWithData:(NSData *)data result:(WebPDecodeOperationResult *)result progress:(WebPDecodeProgress)progress;

@end
