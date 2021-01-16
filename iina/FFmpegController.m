//
//  FFmpegController.m
//  iina
//
//  Created by lhc on 9/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

#import "FFmpegController.h"
#import <Cocoa/Cocoa.h>

#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libswscale/swscale.h>
#import <libavutil/imgutils.h>
#import <libavutil/mastering_display_metadata.h>

#define THUMB_COUNT_DEFAULT 100
#define THUMB_WIDTH 120

#define CHECK_NOTNULL(ptr,msg) if (ptr == NULL) {\
NSLog(@"Error when getting thumbnails: %@", msg);\
return -1;\
}

#define CHECK_SUCCESS(ret,msg) if (ret < 0) {\
NSLog(@"Error when getting thumbnails: %@ (%d)", msg, ret);\
return -1;\
}

#define CHECK(ret,msg) if (!(ret)) {\
NSLog(@"Error when getting thumbnails: %@", msg);\
return -1;\
}

@implementation FFThumbnail

@end


@interface FFmpegController () {
  NSMutableArray<FFThumbnail *> *_thumbnails;
  NSMutableArray<FFThumbnail *> *_thumbnailPartialResult;
  NSMutableSet *_addedTimestamps;
  NSOperationQueue *_queue;
  double _timestamp;
}

- (int)getPeeksForFile:(NSString *)file thumbnailsWidth:(int)thumbnailsWidth;
- (void)saveThumbnail:(AVFrame *)pFrame width:(int)width height:(int)height index:(int)index realTime:(int)second forFile:(NSString *)file;

@end


@implementation FFmpegController

- (instancetype)init
{
  self = [super init];
  if (self) {
    self.thumbnailCount = THUMB_COUNT_DEFAULT;
    _thumbnails = [[NSMutableArray alloc] init];
    _thumbnailPartialResult = [[NSMutableArray alloc] init];
    _addedTimestamps = [[NSMutableSet alloc] init];
    _queue = [[NSOperationQueue alloc] init];
    _queue.maxConcurrentOperationCount = 1;
  }
  return self;
}


- (void)generateThumbnailForFile:(NSString *)file
                      thumbWidth:(int)thumbWidth
{
  [_queue cancelAllOperations];
  NSBlockOperation *op = [[NSBlockOperation alloc] init];
  __weak NSBlockOperation *weakOp = op;
  [op addExecutionBlock:^(){
    if ([weakOp isCancelled]) {
      return;
    }
    self->_timestamp = CACurrentMediaTime();
    int success = [self getPeeksForFile:file thumbnailsWidth:thumbWidth];
    if (self.delegate) {
      [self.delegate didGenerateThumbnails:[NSArray arrayWithArray:self->_thumbnails]
                                   forFile: file
                                 succeeded:(success < 0 ? NO : YES)];
    }
  }];
  [_queue addOperation:op];
}

// This one prints yellow text to stdout
static void NSPrint(NSString *format, ...)
 {
    va_list args;

    va_start(args, format);
    NSString *string  = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stdout, "\033[1;33m%s\033[0m\n", [string UTF8String]);

#if !__has_feature(objc_arc)
    [string release];
#endif
}

- (int)getPeeksForFile:(NSString *)file
       thumbnailsWidth:(int)thumbnailsWidth
{
  int i, ret;

  char *cFilename = strdup(file.fileSystemRepresentation);
  [_thumbnails removeAllObjects];
  [_thumbnailPartialResult removeAllObjects];
  [_addedTimestamps removeAllObjects];

  // Register all formats and codecs. mpv should have already called it.
  // av_register_all();

  // Open video file
  AVFormatContext *pFormatCtx = NULL;
  ret = avformat_open_input(&pFormatCtx, cFilename, NULL, NULL);
  free(cFilename);
  CHECK_SUCCESS(ret, @"Cannot open video")

  // Find stream information
  ret = avformat_find_stream_info(pFormatCtx, NULL);
  CHECK_SUCCESS(ret, @"Cannot get stream info")

  // Find the first video stream
  int videoStream = -1;
  for (i = 0; i < pFormatCtx->nb_streams; i++)
    if (pFormatCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      videoStream = i;
      break;
    }
  CHECK_SUCCESS(videoStream, @"No video stream")

  // Get the codec context for the video stream
  AVStream *pVideoStream = pFormatCtx->streams[videoStream];
  AVRational videoAvgFrameRate = pVideoStream->avg_frame_rate;

  // Check whether the denominator (AVRational.den) is zero to prevent division-by-zero
  if (videoAvgFrameRate.den == 0 || av_q2d(videoAvgFrameRate) == 0) {
    NSLog(@"Avg frame rate = 0, ignore");
    return -1;
  }

  // Find the decoder for the video stream
  AVCodec *pCodec = avcodec_find_decoder(pVideoStream->codecpar->codec_id);
  CHECK_NOTNULL(pCodec, @"Unsupported codec")

  // Open codec
  AVCodecContext *pCodecCtx = avcodec_alloc_context3(pCodec);
  AVDictionary *optionsDict = NULL;

  avcodec_parameters_to_context(pCodecCtx, pVideoStream->codecpar);
  pCodecCtx->time_base = pVideoStream->time_base;

  if (pCodecCtx->pix_fmt < 0 || pCodecCtx->pix_fmt >= AV_PIX_FMT_NB) {
    avcodec_free_context(&pCodecCtx);
    avformat_close_input(&pFormatCtx);
    NSLog(@"Error when getting thumbnails: Pixel format is null");
    return -1;
  }
  
  ret = avcodec_open2(pCodecCtx, pCodec, &optionsDict);
  CHECK_SUCCESS(ret, @"Cannot open codec")

  // Allocate video frame
  AVFrame *pFrame = av_frame_alloc();
  CHECK_NOTNULL(pFrame, @"Cannot alloc video frame")

  // Allocate the output frame
  // We need to convert the video frame to RGBA to satisfy CGImage's data format
  int thumbWidth = thumbnailsWidth;
  int thumbHeight = (float)thumbWidth / ((float)pCodecCtx->width / pCodecCtx->height);

  AVFrame *pFrameRGB = av_frame_alloc();
  CHECK_NOTNULL(pFrameRGB, @"Cannot alloc RGBA frame")

  pFrameRGB->width = thumbWidth;
  pFrameRGB->height = thumbHeight;
  pFrameRGB->format = AV_PIX_FMT_RGBA;

  // Determine required buffer size and allocate buffer
  int size = av_image_get_buffer_size(pFrameRGB->format, thumbWidth, thumbHeight, 1);
  uint8_t *pFrameRGBBuffer = (uint8_t *)av_malloc(size);

  // Assign appropriate parts of buffer to image planes in pFrameRGB
  ret = av_image_fill_arrays(pFrameRGB->data,
                             pFrameRGB->linesize,
                             pFrameRGBBuffer,
                             pFrameRGB->format,
                             pFrameRGB->width,
                             pFrameRGB->height, 1);
  CHECK_SUCCESS(ret, @"Cannot fill data for RGBA frame")

  // Create a sws context for converting color space and resizing
  CHECK(pCodecCtx->pix_fmt != AV_PIX_FMT_NONE, @"Pixel format is none")
  struct SwsContext *sws_ctx = sws_getContext(pCodecCtx->width, pCodecCtx->height, pCodecCtx->pix_fmt,
                                              pFrameRGB->width, pFrameRGB->height, pFrameRGB->format,
                                              SWS_BILINEAR,
                                              NULL, NULL, NULL);

  // Get duration and interval
  int64_t duration = av_rescale_q(pFormatCtx->duration, AV_TIME_BASE_Q, pVideoStream->time_base);
  double interval = duration / (double)self.thumbnailCount;
  double timebaseDouble = av_q2d(pVideoStream->time_base);
  AVPacket packet;

  // For each preview point
  for (i = 0; i <= self.thumbnailCount; i++) {
    int64_t seek_pos = interval * i + pVideoStream->start_time;

    avcodec_flush_buffers(pCodecCtx);

    // Seek to time point
    // avformat_seek_file(pFormatCtx, videoStream, seek_pos-interval, seek_pos, seek_pos+interval, 0);
    ret = av_seek_frame(pFormatCtx, videoStream, seek_pos, AVSEEK_FLAG_BACKWARD);
    CHECK_SUCCESS(ret, @"Cannot seek")

    avcodec_flush_buffers(pCodecCtx);

    // Read and decode frame
    while(av_read_frame(pFormatCtx, &packet) >= 0) {

      // Make sure it's video stream
      if (packet.stream_index == videoStream) {

        // Decode video frame
        if (avcodec_send_packet(pCodecCtx, &packet) < 0)
          break;

        ret = avcodec_receive_frame(pCodecCtx, pFrame);
        if (ret < 0) {  // something happened
          if (ret == AVERROR(EAGAIN))  // input not ready, retry
            continue;
          else
            break;
        }

        // Check if duplicated
        NSNumber *currentTimeStamp = @(pFrame->best_effort_timestamp);
        if ([_addedTimestamps containsObject:currentTimeStamp]) {
          double currentTime = CACurrentMediaTime();
          if (currentTime - _timestamp > 1) {
            if (self.delegate) {
              [self.delegate didUpdateThumbnails:NULL forFile: file withProgress: i];
              _timestamp = currentTime;
            }
          }
          break;
        } else {
          [_addedTimestamps addObject:currentTimeStamp];
        }

        // Convert the frame to RGBA
        ret = sws_scale(sws_ctx,
                        (const uint8_t* const *)pFrame->data,
                        pFrame->linesize,
                        0,
                        pCodecCtx->height,
                        pFrameRGB->data,
                        pFrameRGB->linesize);
        CHECK_SUCCESS(ret, @"Cannot convert frame")
        
        // Save the frame to disk
        [self saveThumbnail:pFrameRGB
                      width:pFrameRGB->width
                     height:pFrameRGB->height
                      index:i
                   realTime:(pFrame->best_effort_timestamp * timebaseDouble)
                    forFile:file];
        break;
      }

      // Free the packet
      av_packet_unref(&packet);
    }
  }

  // Free the RGB image
  av_free(pFrameRGBBuffer);
  av_free(pFrameRGB);
  // Free the YUV frame
  av_free(pFrame);

  // Close the codec
  avcodec_close(pCodecCtx);
  // Close the video file
  avformat_close_input(&pFormatCtx);

  // NSLog(@"Thumbnails generated.");
  return 0;
}



// HDR
// Backward conversion from primaries metadata to color space is taken from here
// https://github.com/rigaya/NVEnc/issues/51#issuecomment-392572746
// Also from File__Analyze_Streams.cpp in MediaInfo

struct masteringdisplaycolorvolume_values
{
    int Code; //ISO code
    double Values[8]; // G, B, R, W pairs (x values then y values)
};
static const int MasteringDisplayColorVolume_Values_Size=4;
static const struct masteringdisplaycolorvolume_values MasteringDisplayColorVolume_Values[] =
{
    { 1, {15000, 30000,  7500,  3000, 32000, 16500, 15635, 16450}}, // BT.709
    { 9, { 8500, 39850,  6550,  2300, 35400, 14600, 15635, 16450}}, // BT.2020
    {11, {13250, 34500,  7500,  3000, 34000, 16000, 15700, 17550}}, // DCI P3
    {12, {13250 /*green_x*/, 34500 /*green_y*/,  7500 /*blue_x*/,  3000 /*blue_y*/, 34000 /*red_x*/, 16000 /*red_y*/, /* whitepoint_x */ 15635, /* whitepoint_y */ 16450}}, // Display P3
};


// HDR
+ (int)getPrimariesForFile:(NSString *)file
{
  int i, ret, thumbnailWidth=120;

  char *cFilename = strdup(file.fileSystemRepresentation);

  NSLog(@"#### Getting HDR color space information for video...");

  // Register all formats and codecs. mpv should have already called it.
  // av_register_all();

  // Open video file
  AVFormatContext *pFormatCtx = NULL;
  ret = avformat_open_input(&pFormatCtx, cFilename, NULL, NULL);
  free(cFilename);
  CHECK_SUCCESS(ret, @"Cannot open video")

  // Find stream information
  ret = avformat_find_stream_info(pFormatCtx, NULL);
  CHECK_SUCCESS(ret, @"Cannot get stream info")

  // Find the first video stream
  int videoStream = -1;
  for (i = 0; i < pFormatCtx->nb_streams; i++)
    if (pFormatCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      videoStream = i;
      break;
    }
  CHECK_SUCCESS(videoStream, @"No video stream")

  // Get the codec context for the video stream
  AVStream *pVideoStream = pFormatCtx->streams[videoStream];
  AVRational videoAvgFrameRate = pVideoStream->avg_frame_rate;

  // Check whether the denominator (AVRational.den) is zero to prevent division-by-zero
  if (videoAvgFrameRate.den == 0 || av_q2d(videoAvgFrameRate) == 0) {
    NSLog(@"Avg frame rate = 0, ignore");
    return -1;
  }

  // Find the decoder for the video stream
  AVCodec *pCodec = avcodec_find_decoder(pVideoStream->codecpar->codec_id);
  CHECK_NOTNULL(pCodec, @"Unsupported codec")
  

  // Open codec
  AVCodecContext *pCodecCtx = avcodec_alloc_context3(pCodec);
  AVDictionary *optionsDict = NULL;

  avcodec_parameters_to_context(pCodecCtx, pVideoStream->codecpar);
  pCodecCtx->time_base = pVideoStream->time_base;

  if (pCodecCtx->color_primaries != AVCOL_PRI_BT2020 && pCodecCtx->color_primaries != AVCOL_PRI_BT709)
  {
    avcodec_free_context(&pCodecCtx);
    avformat_close_input(&pFormatCtx);
    NSLog(@"Not HDR");
    return -1;
  }

  if (pCodecCtx->pix_fmt < 0 || pCodecCtx->pix_fmt >= AV_PIX_FMT_NB) {
    avcodec_free_context(&pCodecCtx);
    avformat_close_input(&pFormatCtx);
    NSLog(@"Error when getting thumbnails: Pixel format is null");
    return -1;
  }
  
  ret = avcodec_open2(pCodecCtx, pCodec, &optionsDict);
  CHECK_SUCCESS(ret, @"Cannot open codec")

  // Allocate video frame
  AVFrame *pFrame = av_frame_alloc();
  CHECK_NOTNULL(pFrame, @"Cannot alloc video frame")

  // Allocate the output frame
  // We need to convert the video frame to RGBA to satisfy CGImage's data format
  int thumbWidth = 120;
  int thumbHeight = (float)thumbWidth / ((float)pCodecCtx->width / pCodecCtx->height);

  AVFrame *pFrameRGB = av_frame_alloc();
  CHECK_NOTNULL(pFrameRGB, @"Cannot alloc RGBA frame")

  pFrameRGB->width = thumbWidth;
  pFrameRGB->height = thumbHeight;
  pFrameRGB->format = AV_PIX_FMT_RGBA;

  // Determine required buffer size and allocate buffer
  int size = av_image_get_buffer_size(pFrameRGB->format, thumbWidth, thumbHeight, 1);
  uint8_t *pFrameRGBBuffer = (uint8_t *)av_malloc(size);

  // Assign appropriate parts of buffer to image planes in pFrameRGB
  ret = av_image_fill_arrays(pFrameRGB->data,
                             pFrameRGB->linesize,
                             pFrameRGBBuffer,
                             pFrameRGB->format,
                             pFrameRGB->width,
                             pFrameRGB->height, 1);
  CHECK_SUCCESS(ret, @"Cannot fill data for RGBA frame")

  // Create a sws context for converting color space and resizing
  CHECK(pCodecCtx->pix_fmt != AV_PIX_FMT_NONE, @"Pixel format is none")
  struct SwsContext *sws_ctx = sws_getContext(pCodecCtx->width, pCodecCtx->height, pCodecCtx->pix_fmt,
                                              pFrameRGB->width, pFrameRGB->height, pFrameRGB->format,
                                              SWS_BILINEAR,
                                              NULL, NULL, NULL);

  // Get duration and interval
  int64_t duration = av_rescale_q(pFormatCtx->duration, AV_TIME_BASE_Q, pVideoStream->time_base);
  double interval = duration / 1000;
  double timebaseDouble = av_q2d(pVideoStream->time_base);
  AVPacket packet;
  
  i = 0;

  int64_t seek_pos = interval * i + pVideoStream->start_time;

  avcodec_flush_buffers(pCodecCtx);

  // Seek to time point
  // avformat_seek_file(pFormatCtx, videoStream, seek_pos-interval, seek_pos, seek_pos+interval, 0);
  ret = av_seek_frame(pFormatCtx, videoStream, seek_pos, AVSEEK_FLAG_BACKWARD);
  CHECK_SUCCESS(ret, @"Cannot seek")

  avcodec_flush_buffers(pCodecCtx);
  
  bool done = false;
  int Code = -1;

  // Read and decode first frame
  while(av_read_frame(pFormatCtx, &packet) >= 0) {
    // Make sure it's video stream
    if (packet.stream_index == videoStream) {

      // Decode video frame
      if (avcodec_send_packet(pCodecCtx, &packet) < 0)
      {
        break;
      }
      
      ret = avcodec_receive_frame(pCodecCtx, pFrame);
      if (ret < 0) {  // something happened
        if (ret == AVERROR(EAGAIN))  // input not ready, retry
        {
          continue;
        }
        else
          break;
      }
      
      done = true;
      
      AVFrameSideData *sidedata =  (AVFrameSideData *)av_frame_get_side_data(pFrame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
      CHECK_NOTNULL(sidedata, @"NO SIDEDATA DETECTED");

      AVMasteringDisplayMetadata *metadata3 = (AVMasteringDisplayMetadata *)sidedata->data;
      CHECK_NOTNULL(metadata3, @"NO AVMasteringDisplayMetadata DETECTED");
      
      if (metadata3->has_primaries)
      {
        for (int i=0; i<MasteringDisplayColorVolume_Values_Size; i++)
        {

          Code=MasteringDisplayColorVolume_Values[i].Code;
          int j = 0;

          // +/- 0.0005 (3 digits after comma)
        // Green
          if (metadata3->display_primaries[1][0].num<MasteringDisplayColorVolume_Values[i].Values[0*2+j]-25 || (metadata3->display_primaries[1][0].num>=MasteringDisplayColorVolume_Values[i].Values[0*2+j]+25))
              Code= -1;
        // Blue
          if (metadata3->display_primaries[2][0].num<MasteringDisplayColorVolume_Values[i].Values[1*2+j]-25 || (metadata3->display_primaries[2][0].num>=MasteringDisplayColorVolume_Values[i].Values[1*2+j]+25))
              Code= -1;
        // Red
          if (metadata3->display_primaries[0][0].num<MasteringDisplayColorVolume_Values[i].Values[2*2+j]-25 || (metadata3->display_primaries[0][0].num>=MasteringDisplayColorVolume_Values[i].Values[2*2+j]+25))
              Code= -1;
                    
          // +/- 0.00005 (4 digits after comma)
          if (metadata3->white_point[0].num<MasteringDisplayColorVolume_Values[i].Values[3*2+j]-2 || (metadata3->white_point[0].num>=MasteringDisplayColorVolume_Values[i].Values[3*2+j]+3))
              Code= -1;

            if (Code>0)
            {
              NSLog(@"####### Found primaries with code %d",Code);
              break;
            }
        }

      }
      
      if (done)
        break;
    }

    // Free the packet
    av_packet_unref(&packet);
    if (done)
      break;
  }

  // Free the RGB image
  av_free(pFrameRGBBuffer);
  av_free(pFrameRGB);
  // Free the YUV frame
  av_free(pFrame);

  // Close the codec
  avcodec_close(pCodecCtx);
  // Close the video file
  avformat_close_input(&pFormatCtx);

  // NSLog(@"Thumbnails generated.");
  return Code;
}


- (void)saveThumbnail:(AVFrame *)pFrame width:(int)width height:(int)height index:(int)index realTime:(int)second forFile: (NSString *)file
{
  // Create CGImage
  CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
  
  CGContextRef cgContext = CGBitmapContextCreate(pFrame->data[0],  // it's converted to RGBA so could be used directly
                                                 width, height,
                                                 8,  // 8 bit per component
                                                 width * 4,  // 4 bytes(rgba) per pixel
                                                 rgb,
                                                 kCGImageAlphaPremultipliedLast);
  CGImageRef cgImage = CGBitmapContextCreateImage(cgContext);

  // Create NSImage
  NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size: NSZeroSize];
  
  // Free resources
  CFRelease(rgb);
  CFRelease(cgContext);
  CFRelease(cgImage);
  
  // Add to list
  FFThumbnail *tb = [[FFThumbnail alloc] init];
  tb.image = image;
  tb.realTime = second;
  [_thumbnails addObject:tb];
  [_thumbnailPartialResult addObject:tb];
  // Post update notification
  double currentTime = CACurrentMediaTime();
  if (currentTime - _timestamp >= 0.2) {  // min notification interval: 0.2s
    if (_thumbnailPartialResult.count >= 10 || (currentTime - _timestamp >= 1 && _thumbnailPartialResult.count > 0)) {
      if (self.delegate) {
        [self.delegate didUpdateThumbnails:[NSArray arrayWithArray:_thumbnailPartialResult]
                                   forFile: file
                              withProgress: index];
      }
      [_thumbnailPartialResult removeAllObjects];
      _timestamp = currentTime;
    }
  }
}

//void my_log_callback(void *ptr, int level, const char *fmt, va_list vargs)
//{
//    vprintf(fmt, vargs);
//}

+ (NSDictionary *)getColorSpaceMetadataForFile:(nonnull NSString *)file
{
  int ret;
  int64_t duration;
  
  char *cFilename = strdup(file.fileSystemRepresentation);

  AVFormatContext *pFormatCtx = NULL;
  ret = avformat_open_input(&pFormatCtx, cFilename, NULL, NULL);
  free(cFilename);
  if (ret < 0) return NULL;
  

  NSMutableDictionary *info = [[NSMutableDictionary alloc] init];
    
  ret = avformat_find_stream_info(pFormatCtx, NULL);

  int bestVideoStream = av_find_best_stream(pFormatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  int videoStream = bestVideoStream;

  // Get the codec context for the video stream
  AVStream *pVideoStream = pFormatCtx->streams[videoStream];
  AVRational videoAvgFrameRate = pVideoStream->avg_frame_rate;

  // Find the decoder for the video stream
  AVCodec *pCodec = avcodec_find_decoder(pVideoStream->codecpar->codec_id);
//  CHECK_NOTNULL(pCodec, @"Unsupported codec")

  // Open codec
  AVCodecContext *pCodecCtx = avcodec_alloc_context3(pCodec);
  AVDictionary *optionsDict = NULL;

  avcodec_parameters_to_context(pCodecCtx, pVideoStream->codecpar);
  // color_trc must be converted to mpv format, for example
  // AVCOL_TRC_SMPTE2084 && AVCOL_TRC_SMPTEST2084 means PQ
  //  ????? bt.1886 =
  //  ITU-R BT.1886 curve (assuming infinite contrast)
  //  ??? linear
  //  Linear light output
  //  ???? gamma1.8
  //  Pure power curve (gamma 1.8), also used for Apple RGB
  //  ???? gamma2.0
  //  Pure power curve (gamma 2.0)
  //  ???? gamma2.4
  //  Pure power curve (gamma 2.4)
  //  ???? gamma2.6
  //  Pure power curve (gamma 2.6)
  //  ???? prophoto
  //  ProPhoto RGB (ROMM)
  //  ???? v-log
  //  Panasonic V-Log (VARICAM) curve
  //  s-log1
  //  Sony S-Log1 curve
  //  s-log2
  
  switch (pVideoStream->codecpar->color_trc)
  {
    // IEC 61966-2-4 (sRGB)
    case AVCOL_TRC_IEC61966_2_1: info[@"color-trc"] = @"srgb";
      break;
    // Pure power curve (gamma 2.2)
    case AVCOL_TRC_GAMMA22: info[@"color-trc"] = @"gamma2.2";
      break;
    // Pure power curve (gamma 2.8), also used for BT.470-BG
    case AVCOL_TRC_GAMMA28: info[@"color-trc"] = @"gamma2.8";
      break;
    // ITU-R BT.2100 HLG (Hybrid Log-gamma) curve, aka ARIB STD-B67
    case AVCOL_TRC_ARIB_STD_B67: info[@"color-trc"] = @"hlg";
      break;
    // ITU-R BT.2100 PQ (Perceptual quantizer) curve, aka SMPTE ST2084
    // assuming that AVCOL_TRC_SMPTEST2084 and AVCOL_TRC_SMPTE2084 have same value
    case AVCOL_TRC_SMPTE2084: info[@"color-trc"] = @"pq";
      break;
    default: info[@"color-trc"] = @"?";
      break;
  }

  int code = [FFmpegController getPrimariesForFile:file];
  
  
  // By default we set DCI P3 as it is stated in Apple docs to be the default color space
  info[@"primaries"] = @"dcip3";
  
  switch (code)
  {
    case 1: info[@"primaries"] = @"bt709"; break;
    case 9: info[@"primaries"] = @"bt2020"; break;
    case 11: info[@"primaries"] = @"dcip3"; break;
    case 12: info[@"primaries"] = @"displayp3"; break;
    default: break;
  }

  
  avformat_close_input(&pFormatCtx);
  avformat_free_context(pFormatCtx);
  
  NSPrint(@"HDR primaries=%@ color-trc=%@",info[@"primaries"],info[@"color-trc"]);

  return info;

}

+ (NSDictionary *)probeVideoInfoForFile:(nonnull NSString *)file
{
  int ret;
  int64_t duration;

  char *cFilename = strdup(file.fileSystemRepresentation);

  AVFormatContext *pFormatCtx = NULL;
  ret = avformat_open_input(&pFormatCtx, cFilename, NULL, NULL);
  free(cFilename);
  if (ret < 0) return NULL;

  duration = pFormatCtx->duration;
  if (duration <= 0) {
    ret = avformat_find_stream_info(pFormatCtx, NULL);
    if (ret < 0)
      duration = -1;
    else
      duration = pFormatCtx->duration;
  }

  NSMutableDictionary *info = [[NSMutableDictionary alloc] init];
  info[@"@iina_duration"] = duration == -1 ? [NSNumber numberWithInt:-1] : [NSNumber numberWithDouble:(double)duration / AV_TIME_BASE];
  AVDictionaryEntry *tag = NULL;
  while ((tag = av_dict_get(pFormatCtx->metadata, "", tag, AV_DICT_IGNORE_SUFFIX)))
    info[[NSString stringWithCString:tag->key encoding:NSUTF8StringEncoding]] = [NSString stringWithCString:tag->value encoding:NSUTF8StringEncoding];

  avformat_close_input(&pFormatCtx);
  avformat_free_context(pFormatCtx);

  return info;
}

@end
