//
//  FMVideoWriter.m
//  BroadcastUploadNew
//
//  Created by RICH on 2019/10/16.
//  Copyright © 2019 Anirban. All rights reserved.
//

#import "FMVideoWriter.h"
#import "FMVideoHelper.h"

@interface FMVideoWriter ()

@property (nonatomic, strong) AVAssetWriter                         *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput                    *assetWriterVideoInput;
@property (nonatomic, strong) AVAssetWriterInput                    *assetWriterAudioInput;
@property (nonatomic, strong) AVAssetWriterInput                    *assetWriterMicrophoneInput;

@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor  *assetWriterInputPixelBufferAdaptor;

@property (nonatomic, strong) dispatch_queue_t                      dispatchQueue;

@property (nonatomic, strong) NSDictionary *videoSettings;
@property (nonatomic, strong) NSDictionary *audioSettings;
@property (nonatomic, assign) FMVideoRecordOrientation deviceOrientation;
@property (nonatomic) BOOL firstSample;
@property (nonatomic, assign) BOOL isWriting;

@property (nonatomic, copy) NSString *videoTempPath; // 临时共享目录

@end

@implementation FMVideoWriter

- (id)initWithDispatchQueue:(dispatch_queue_t)dispatchQueue
              VideoSettings:(NSDictionary *)videoSettings
              audioSettings:(NSDictionary *)audioSettings
     RecordVideoOrientation:(FMVideoRecordOrientation)orientation
                 OutputPath:(NSString *)outputPath{
    self = [super init];
    if (self) {
        _videoSettings = videoSettings;
        _audioSettings = audioSettings;
        _dispatchQueue = dispatchQueue;
        _deviceOrientation = orientation;
        _videoTempPath = outputPath;
        
        _recordAudioMic = YES;
        _recordVideoSound = YES;
    }
    return self;
}

- (id)initWithDispatchQueue:(dispatch_queue_t)dispatchQueue
              VideoDefition:(FMVideoRecordDefinition)defition
     RecordVideoOrientation:(FMVideoRecordOrientation)orientation
                 OutputPath:(NSString *)outputPath
{
    self = [super init];
    if (self) {
        _videoSettings = [FMVideoHelper getVideoOutputSettingsWithVideoDefinition:defition];
        _audioSettings = [FMVideoHelper getAudioOutputSettings];
        _dispatchQueue = dispatchQueue;
        _deviceOrientation = orientation;
        _videoTempPath = outputPath;
        
        _recordAudioMic = YES;
        _recordVideoSound = YES;
    }
    return self;
}

- (void)startWritingWithError:(NSError *__autoreleasing *)error {
    
    dispatch_async(self.dispatchQueue, ^{

        // 录制缓存地址
        NSURL *url = [NSURL fileURLWithPath:self.videoTempPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        }
        self.assetWriter = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:error];
        
        if (!self.assetWriter || *error) {

            *error = FMVideoRecoderError(@"Could not create writer",FMVideoRecoderErrorFailedToCreatWriter);
            
            return;
        }
        
        self.assetWriterVideoInput = ({
            AVAssetWriterInput *writerInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:self.videoSettings];
            // yes指明输入应针对实时进行优化
            writerInput.expectsMediaDataInRealTime = YES;
            
            writerInput.transform = ({
                // 根据手机当前位置，旋转写入位置，以达到视频位置水平。
                CGAffineTransform transform;
                switch (self.deviceOrientation) {
                    case FMVideoRecordLandscapeOrientation:
                        transform = CGAffineTransformMakeRotation(-M_PI/2);
                        break;
                    default:
                        transform = CGAffineTransformIdentity;
                        break;
                }
                transform;
            });
            writerInput;
        
        });

        // 视频输出添加到写入者中
        if ([self.assetWriter canAddInput:self.assetWriterVideoInput]) {
            [self.assetWriter addInput:self.assetWriterVideoInput];
        } else {
            *error = FMVideoRecoderError(@"Failed to add writer video input.",FMVideoRecoderErrorFailedToAddVideoInputWriter);
            return;
        }
        
        // 音频输出
        self.assetWriterAudioInput = ({
            AVAssetWriterInput *writerInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:self.audioSettings];
            writerInput.expectsMediaDataInRealTime = YES;
            writerInput;
        });
        
        if ([self.assetWriter canAddInput:self.assetWriterAudioInput]) {
            [self.assetWriter addInput:self.assetWriterAudioInput];
        } else {
            *error = FMVideoRecoderError(@"Failed to add writer audio input.",FMVideoRecoderErrorFailedToAddAudioInputWriter);
            return;
        }
        
        // 麦克风输出
        self.assetWriterMicrophoneInput = ({
            AVAssetWriterInput *writerInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:self.audioSettings];
            writerInput.expectsMediaDataInRealTime = YES;
            writerInput;
        });
        
        if ([self.assetWriter canAddInput:self.assetWriterMicrophoneInput]) {
            [self.assetWriter addInput:self.assetWriterMicrophoneInput];
        } else {
            *error = FMVideoRecoderError(@"Failed to add writer MicroPhone input.",FMVideoRecoderErrorFailedToAddAudioInputWriter);
            return;
        }
        
        self.isWriting = NO;
    });
}

- (void)writeVideoBuffer:(CMSampleBufferRef)sampleBuffer bufferType:(RPSampleBufferType)bufferType error:(NSError *__autoreleasing *)error
API_AVAILABLE(ios(10.0)){
    @autoreleasepool {
        CFRetain(sampleBuffer);
        dispatch_async(_dispatchQueue, ^{
            @synchronized(self) {
            if (!CMSampleBufferDataIsReady(sampleBuffer)) {
                CFRelease(sampleBuffer);
                return;
            }
            
            if (self.assetWriter.status == AVAssetWriterStatusUnknown && !self.isWriting) {
                [self.assetWriter startWriting];
                [self.assetWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
                self.isWriting = YES;
                 NSLog(@"屏幕录制开启session 视频处");
            }
            if (self.assetWriter.status == AVAssetWriterStatusFailed) {
                NSLog(@"屏幕录制AVAssetWriterStatusFailed error :%@", self.assetWriter.error);
                CFRelease(sampleBuffer);
                return;
            }
            if (self.assetWriter.status == AVAssetWriterStatusCompleted) {
                NSLog(@"屏幕录制AVAssetWriterStatus Completed");
            }
            
            if (bufferType == RPSampleBufferTypeVideo) {
                if ([self.assetWriterVideoInput isReadyForMoreMediaData]) {
                    if (![self.assetWriterVideoInput appendSampleBuffer:sampleBuffer]) {
                          *error = FMVideoRecoderError(@"Failed to Appending Video Buffer", FMVideoRecoderErrorFailedToAppendVideoBuffer);

                    }
                    NSLog(@"write video Buffer");
                 }
            }else if (bufferType == RPSampleBufferTypeAudioMic) {
                    
                if (self.isWriting && [self.assetWriterMicrophoneInput isReadyForMoreMediaData]  && self.recordAudioMic) {
                    // 直接将音频通过默认参数写入到 mp4 中去
                    if (![self.assetWriterMicrophoneInput appendSampleBuffer:sampleBuffer]) {
                        
                        *error = FMVideoRecoderError(@"Failed to Appending audio Buffer", FMVideoRecoderErrorFailedToAppendAudioBuffer);
                    }
                    NSLog(@"write micphone Buffer");
                }
            }else if (bufferType == RPSampleBufferTypeAudioApp) {
                    
                if (self.isWriting && [self.assetWriterAudioInput isReadyForMoreMediaData] && self.recordVideoSound) {
                    // 直接将音频通过默认参数写入到 mp4 中去
                    if (![self.assetWriterAudioInput appendSampleBuffer:sampleBuffer]) {
                        
                        *error = FMVideoRecoderError(@"Failed to Appending audio Buffer", FMVideoRecoderErrorFailedToAppendAudioBuffer);
                    }
                    NSLog(@"write audio Buffer");
                }
            }
            CFRelease(sampleBuffer);
            }
        });
    }
}


- (void)stopWritingWithError:(NSError *__autoreleasing *)error {
    
    self.isWriting = NO;
    if (self.assetWriter && self.assetWriter.status != AVAssetWriterStatusCompleted && self.assetWriter.status != AVAssetWriterStatusUnknown) {
        [self.assetWriterVideoInput markAsFinished];
        [self.assetWriterAudioInput markAsFinished];
        [self.assetWriterMicrophoneInput markAsFinished];
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated"
        //这里是弃用的方法
        [self.assetWriter finishWriting];
        #pragma clang diagnostic pop
         *error = self.assetWriter.error;
        if (self.delegate && [self.delegate respondsToSelector:@selector(videoWriter:didOutputVideoAtPath:)]) {
            [self.delegate videoWriter:self didOutputVideoAtPath:[NSURL fileURLWithPath:self.videoTempPath]];
        }
    }
}


@end
