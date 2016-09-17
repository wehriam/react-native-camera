//
//  KFRecorder.m
//  FFmpegEncoder
//
//  Created by Christopher Ballinger on 1/16/14.
//  Copyright (c) 2014 Christopher Ballinger. All rights reserved.
//

#import "KFRecorder.h"
#import "KFAACEncoder.h"
#import "KFH264Encoder.h"
#import "KFHLSMonitor.h"
#import "KFH264Encoder.h"
#import "KFHLSWriter.h"
#import "KFLog.h"
#import "KFS3Stream.h"
#import "KFFrame.h"
#import "KFVideoFrame.h"
#import "Endian.h"
#import <UIKit/UIKit.h>

@interface KFRecorder()
@property (nonatomic) double minBitrate;
@property (nonatomic) BOOL hasScreenshot;

@end

@implementation KFRecorder

- (id) initWithSession:(AVCaptureSession *)session{
    self = [super init];
    if (self) {
        _session = session;
        self.maxBitrate = 4096 * 1024; // 4 Mbps
        self.useAdaptiveBitrate = YES;
        NSLog(@"INITIALIZING");
        _minBitrate = 300 * 1024;
        [self setupVideoCapture];
        [self setupAudioCapture];
        [self setupEncoders];
    }
    return self;
}

- (AVCaptureDevice *)audioDevice
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
    if ([devices count] > 0)
        return [devices objectAtIndex:0];
    
    return nil;
}


- (void) setupHLSWriterWithEndpoint:(KFS3Stream*)endpoint {
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    NSString *folderName = endpoint.streamID;
    NSString *hlsDirectoryPath = [basePath stringByAppendingPathComponent:folderName];
    self.manifestPath = hlsDirectoryPath;
    [[NSFileManager defaultManager] createDirectoryAtPath:hlsDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    self.hlsWriter = [[KFHLSWriter alloc] initWithDirectoryPath:hlsDirectoryPath];
    [_hlsWriter addVideoStreamWithWidth:self.videoWidth height:self.videoHeight];
    [_hlsWriter addAudioStreamWithSampleRate:self.audioSampleRate];

}

- (void) setupEncoders {
    self.audioSampleRate = 44100;
    self.videoHeight = 1920;
    self.videoWidth = 1080;
    int audioBitrate = 128 * 1024; // 128 Kbps
    int maxBitrate = self.maxBitrate;
    int videoBitrate = maxBitrate - audioBitrate;
    _h264Encoder = [[KFH264Encoder alloc] initWithBitrate:videoBitrate width:self.videoWidth height:self.videoHeight];
    _h264Encoder.delegate = self;
    
    _aacEncoder = [[KFAACEncoder alloc] initWithBitrate:audioBitrate sampleRate:self.audioSampleRate channels:1];
    _aacEncoder.delegate = self;
    _aacEncoder.addADTSHeader = YES;
}

- (void) setupAudioCapture {
  
  /*
   * Create audio connection
   */
  _audioQueue = dispatch_queue_create("Audio Capture Queue", DISPATCH_QUEUE_SERIAL);
  _audioOutput = [[AVCaptureAudioDataOutput alloc] init];
  [_audioOutput setSampleBufferDelegate:self queue:_audioQueue];
  if ([_session canAddOutput:_audioOutput]) {
    [_session addOutput:_audioOutput];
  }
  
}

- (void) setupVideoCapture {
  // create an output for YUV output with self as delegate
  _videoQueue = dispatch_queue_create("Video Capture Queue", DISPATCH_QUEUE_SERIAL);
  _videoOutput = [[AVCaptureVideoDataOutput alloc] init];
  [_videoOutput setSampleBufferDelegate:self queue:_videoQueue];
  NSDictionary *captureSettings = @{(NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
  _videoOutput.videoSettings = captureSettings;
  _videoOutput.alwaysDiscardsLateVideoFrames = YES;
  if ([_session canAddOutput:_videoOutput]) {
    [_session addOutput:_videoOutput];
  }
}

#pragma mark KFEncoderDelegate method
- (void) encoder:(KFEncoder*)encoder encodedFrame:(KFFrame *)frame {
    if (encoder == _h264Encoder) {
        KFVideoFrame *videoFrame = (KFVideoFrame*)frame;
        [_hlsWriter processEncodedData:videoFrame.data presentationTimestamp:videoFrame.pts streamIndex:0 isKeyFrame:videoFrame.isKeyFrame];
    } else if (encoder == _aacEncoder) {
        [_hlsWriter processEncodedData:frame.data presentationTimestamp:frame.pts streamIndex:1 isKeyFrame:NO];
    }
}

#pragma mark AVCaptureOutputDelegate method
- (void) captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if (!_isRecording) {
        return;
    }
    // pass frame to encoders
    if (connection == _videoConnection) {
        if (!_hasScreenshot) {
            UIImage *image = [self imageFromSampleBuffer:sampleBuffer];
            NSString *path = [self.hlsWriter.directoryPath stringByAppendingPathComponent:@"thumb.jpg"];
            NSData *imageData = UIImageJPEGRepresentation(image, 0.7);
            [imageData writeToFile:path atomically:NO];
            _hasScreenshot = YES;
        }
        [_h264Encoder encodeSampleBuffer:sampleBuffer];
    } else if (connection == _audioConnection) {
        [_aacEncoder encodeSampleBuffer:sampleBuffer];
    }
}

// Create a UIImage from sample buffer data
- (UIImage *) imageFromSampleBuffer:(CMSampleBufferRef) sampleBuffer
{
    // Get a CMSampleBuffer's Core Video image buffer for the media data
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    // Lock the base address of the pixel buffer
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    // Get the number of bytes per row for the pixel buffer
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    
    // Get the number of bytes per row for the pixel buffer
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    // Get the pixel buffer width and height
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    // Create a device-dependent RGB color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    // Create a bitmap graphics context with the sample buffer data
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8,
                                                 bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    // Create a Quartz image from the pixel data in the bitmap graphics context
    CGImageRef quartzImage = CGBitmapContextCreateImage(context);
    // Unlock the pixel buffer
    CVPixelBufferUnlockBaseAddress(imageBuffer,0);
    
    // Free up the context and color space
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    // Create an image object from the Quartz image
    UIImage *image = [UIImage imageWithCGImage:quartzImage];
    
    // Release the Quartz image
    CGImageRelease(quartzImage);
    
    return (image);
}


- (void) startRecording:(AVCaptureVideoOrientation)orientation awsDictionary:(NSDictionary *)awsDictionary  {
    NSLog(@"AWS: %@", awsDictionary);
    _videoConnection = [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
    [_videoConnection setVideoOrientation:orientation];
    _audioConnection = [_audioOutput connectionWithMediaType:AVMediaTypeAudio];
    NSError *error;
    KFS3Stream *s3Endpoint = [MTLJSONAdapter modelOfClass:[KFS3Stream class] fromJSONDictionary:awsDictionary error:&error];
    self.stream = s3Endpoint;
    s3Endpoint.streamState = KFStreamStateStreaming;
    [self setupHLSWriterWithEndpoint:s3Endpoint];
    [[KFHLSMonitor sharedMonitor] startMonitoringFolderPath:_hlsWriter.directoryPath endpoint:s3Endpoint delegate:self];
    [_hlsWriter prepareForWriting:&error];
    if (error) {
        DDLogError(@"Error preparing for writing: %@", error);
    }
    self.isRecording = YES;
    self.startDate = [NSDate date];
    if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidStartRecording:error:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate recorderDidStartRecording:self error:nil];
        });
    }
}


- (void) stopRecording {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        //[_session stopRunning];
        self.isRecording = NO;
        self.finishDate = [NSDate date];
        NSError *error = nil;
        [_hlsWriter finishWriting:&error];
        if (error) {
            DDLogError(@"Error stop recording: %@", error);
        }
        if ([self.stream isKindOfClass:[KFS3Stream class]]) {
            [[KFHLSMonitor sharedMonitor] finishUploadingContentsAtFolderPath:_hlsWriter.directoryPath endpoint:(KFS3Stream*)self.stream];
        }
        if (self.delegate && [self.delegate respondsToSelector:@selector(recorderDidFinishRecording:error:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate recorderDidFinishRecording:self error:error];
            });
        }
    });
}

- (void) uploader:(KFHLSUploader *)uploader didUploadSegmentAtURL:(NSURL *)segmentURL uploadSpeed:(double)uploadSpeed numberOfQueuedSegments:(NSUInteger)numberOfQueuedSegments {
    DDLogInfo(@"Uploaded segment %@ @ %f KB/s, numberOfQueuedSegments %d", segmentURL, uploadSpeed, numberOfQueuedSegments);
    if (self.useAdaptiveBitrate) {
        double currentUploadBitrate = uploadSpeed * 8 * 1024; // bps
        double maxBitrate = self.maxBitrate;

        double newBitrate = currentUploadBitrate * 0.75;
        if (newBitrate > maxBitrate) {
            newBitrate = maxBitrate;
        }
        if (newBitrate < _minBitrate) {
            newBitrate = _minBitrate;
        }
        double newVideoBitrate = newBitrate - self.aacEncoder.bitrate;
        self.h264Encoder.bitrate = newVideoBitrate;
    }
}

- (void) uploader:(KFHLSUploader *)uploader liveManifestReadyAtURL:(NSURL *)manifestURL {
    if (self.delegate && [self.delegate respondsToSelector:@selector(recorder:streamReadyAtURL:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate recorder:self streamReadyAtURL:manifestURL];
        });
    }
    DDLogVerbose(@"Manifest ready at URL: %@", manifestURL);
}




@end
