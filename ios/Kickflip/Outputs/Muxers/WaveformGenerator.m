//
//  WebServer.m
//  Bunch
//
//  Created by John Wehr on 9/17/16.
//  Copyright © 2016 Facebook. All rights reserved.
//
// See https://github.com/rzurad/waveform
//

#import "WaveformGenerator.h"
#import "RCTLog.h"



#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>


// normalized version of the AVSampleFormat enum that doesn't care about planar vs interleaved
enum SampleFormat {
  SAMPLE_FORMAT_UINT8,
  SAMPLE_FORMAT_INT16,
  SAMPLE_FORMAT_INT32,
  SAMPLE_FORMAT_FLOAT,
  SAMPLE_FORMAT_DOUBLE
};

// struct to store the raw important data of an audio file pulled from ffmpeg
typedef struct AudioData {
  /*
   * The `samples` buffer is an interleaved buffer of all the raw samples from the audio file.
   * This is populated by calling `read_audio_data`
   *
   * Recall that audio data can be either planar (one buffer or "plane" for each channel) or
   * interleaved (one buffer for all channels: in a stereo file, the first sample for the left
   * channel is at index 0 with the first sample for the right channel at index 1, the second
   * sample for the left channel is at index 2 with the second sample for the right channel at
   * index 3, etc.).
   *
   * To make things easier, data read from ffmpeg is normalized to an interleaved buffer and
   * pointed to by `samples`.
   */
  uint8_t *samples;
  
  /*
   * The size of the `samples` buffer. Not known until after a call to `read_audio_data` or
   * `read_audio_metadata`
   */
  int size;
  
  /*
   * Length of audio file in seconds. Not known until after a call to `read_audio_data` or
   * `read_audio_metadata`
   *
   * This is calculated after reading all the raw samples from the audio file,
   * making it much more accurate than what the header or a bit rate based
   * guess
   */
  double duration;
  
  /*
   * sample rate of the audio file (44100, 48000, etc). Not known until after a call
   * to `read_audio_data` or `read_audio_metadata`
   */
  int sample_rate;
  
  /*
   * Number of bytes per sample. Use together with `size` and `format` to pull data from
   * the `samples` buffer
   */
  int sample_size;
  
  /*
   * Tells us the number format of the audio file
   */
  enum SampleFormat format;
  
  // how many channels does the audio file have? 1 (mono)? 2 (stereo)? ...
  int channels;
  
  /*
   * Format context from ffmpeg, which is the wrapper for the input audio file
   */
  AVFormatContext *format_context;
  
  /*
   * Codec context from ffmpeg. This is what gets us to all the raw
   * audio data.
   */
  AVCodecContext *decoder_context;
} AudioData;


// close and free ffmpeg structs
void cleanup(AVFormatContext *pFormatContext, AVCodecContext *pDecoderContext) {
  avcodec_close(pDecoderContext);
  avformat_close_input(&pFormatContext);
}



// free memory allocated by an AudioData struct
void free_audio_data(AudioData *data) {
  cleanup(data->format_context, data->decoder_context);
  
  if (data->samples != NULL) {
    free(data->samples);
  }
  
  free(data);
}



// get the sample at the given index out of the audio file data.
//
// NOTE: This function expects the caller to know what index to grab based on
// the data's sample size and channel count. It does not magic of its own.
double get_sample(AudioData *data, int index) {
  double value = 0.0;
  
  switch (data->format) {
    case SAMPLE_FORMAT_UINT8:
      value += data->samples[index];
      break;
    case SAMPLE_FORMAT_INT16:
      value += ((int16_t *) data->samples)[index];
      break;
    case SAMPLE_FORMAT_INT32:
      value += ((int32_t *) data->samples)[index];
      break;
    case SAMPLE_FORMAT_FLOAT:
      value += ((float *) data->samples)[index];
      break;
    case SAMPLE_FORMAT_DOUBLE:
      value += ((double *) data->samples)[index];
      break;
  }
  
  // if the value is over or under the floating point range (which it perfectly fine
  // according to ffmpeg), we need to truncate it to still be within our range of
  // -1.0 to 1.0, otherwise some of our latter math will have a bad case of
  // the segfault sads.
  if (data->format == SAMPLE_FORMAT_DOUBLE || data->format == SAMPLE_FORMAT_FLOAT) {
    if (value < -1.0) {
      value = -1.0;
    } else if (value > 1.0) {
      value = 1.0;
    }
  }
  
  return value;
}



// get the min and max values a sample can have given the format and put them
// into the min and max out parameters
void get_format_range(enum SampleFormat format, int *min, int *max) {
  int size;
  
  // figure out the range of sample values we're dealing with
  switch (format) {
    case SAMPLE_FORMAT_FLOAT:
    case SAMPLE_FORMAT_DOUBLE:
      // floats and doubles have a range of -1.0 to 1.0
      // NOTE: It is entirely possible for a sample to go beyond this range. Any value outside
      // is considered beyond full volume. Be aware of this when doing math with sample values.
      *min = -1;
      *max = 1;
      
      break;
    case SAMPLE_FORMAT_UINT8:
      *min = 0;
      *max = 255;
      
      break;
    default:
      // we're dealing with integers, so the range of samples is going to be the min/max values
      // of signed integers of either 16 or 32 bit (24 bit formats get converted to 32 bit at
      // the AVFrame level):
      //  -32,768/32,767, or -2,147,483,648/2,147,483,647
      size = format == SAMPLE_FORMAT_INT16 ? 2 : 4;
      *min = pow(2, size * 8) / -2;
      *max = pow(2, size * 8) / 2 - 1;
  }
}



/*
 * Take an ffmpeg AVFormatContext and AVCodecContext struct and create and AudioData struct
 * that we can easily work with
 */
AudioData *create_audio_data_struct(AVFormatContext *pFormatContext, AVCodecContext *pDecoderContext) {
  // Make the AudioData object we'll be returning
  AudioData *data = malloc(sizeof(AudioData));
  data->format_context = pFormatContext;
  data->decoder_context = pDecoderContext;
  data->format = pDecoderContext->sample_fmt;
  data->sample_size = (int) av_get_bytes_per_sample(pDecoderContext->sample_fmt); // *byte* depth
  data->channels = pDecoderContext->channels;
  data->samples = NULL;
  
  // normalize the sample format to an enum that's less verbose than AVSampleFormat.
  // We won't care about planar/interleaved
  switch (pDecoderContext->sample_fmt) {
    case AV_SAMPLE_FMT_U8:
    case AV_SAMPLE_FMT_U8P:
      data->format = SAMPLE_FORMAT_UINT8;
      break;
    case AV_SAMPLE_FMT_S16:
    case AV_SAMPLE_FMT_S16P:
      data->format = SAMPLE_FORMAT_INT16;
      break;
    case AV_SAMPLE_FMT_S32:
    case AV_SAMPLE_FMT_S32P:
      data->format = SAMPLE_FORMAT_INT32;
      break;
    case AV_SAMPLE_FMT_FLT:
    case AV_SAMPLE_FMT_FLTP:
      data->format = SAMPLE_FORMAT_FLOAT;
      break;
    case AV_SAMPLE_FMT_DBL:
    case AV_SAMPLE_FMT_DBLP:
      data->format = SAMPLE_FORMAT_DOUBLE;
      break;
    default:
      NSLog(@"Bad format: %s\n", av_get_sample_fmt_name(pDecoderContext->sample_fmt));
      free_audio_data(data);
      return NULL;
  }
  
  return data;
}



/*
 * Iterate through the audio file, converting all compressed samples into raw samples.
 * This will populate all of the fields on the data struct, with the exception of
 * the `samples` buffer if `populate_sample_buffer` is set to 0
 */
static void read_raw_audio_data(AudioData *data, int populate_sample_buffer) {
  // Packets will contain chucks of compressed audio data read from the audio file.
  AVPacket packet;
  
  // Frames will contain the raw uncompressed audio data read from a packet
  AVFrame *pFrame = NULL;
  
  // how long in seconds is the audio file?
  
  double duration = data->format_context->duration / (double) AV_TIME_BASE;
  int raw_sample_rate = 0;
  
  // is the audio interleaved or planar?
  int is_planar = av_sample_fmt_is_planar(data->decoder_context->sample_fmt);
  
  // running total of how much data has been converted to raw and copied into the AudioData
  // `samples` buffer. This will eventually be `data->size`
  int total_size = 0;
  
  av_init_packet(&packet);
  
  if (!(pFrame = avcodec_alloc_frame())) {
    NSLog(@"Could not allocate AVFrame\n");
    free_audio_data(data);
    return;
  }
  
  int allocated_buffer_size = 0;
  
  // guess how much memory we'll need for samples.
  if (populate_sample_buffer) {
    allocated_buffer_size = (data->format_context->bit_rate / 8) * duration;
    data->samples = malloc(sizeof(uint8_t) * allocated_buffer_size);
  }
  
  // Loop through the entire audio file by reading a compressed packet of the stream
  // into the uncomrpressed frame struct and copy it into a buffer.
  // It's important to remember that in this context, even though the actual format might
  // be 16 bit or 24 bit or float with x number of channels, while we're copying things,
  // we are only dealing with an array of 8 bit integers.
  //
  // It's up to anything using the AudioData struct to know how to properly read the data
  // inside `samples`
  while (av_read_frame(data->format_context, &packet) == 0) {
    // some audio formats might not contain an entire raw frame in a single compressed packet.
    // If this is the case, then decode_audio4 will tell us that it didn't get all of the
    // raw frame via this out argument.
    int frame_finished = 0;
    
    // Use the decoder to populate the raw frame with data from the compressed packet.
    if (avcodec_decode_audio4(data->decoder_context, pFrame, &frame_finished, &packet) < 0) {
      // unable to decode this packet. continue on to the next packet
      NSLog(@"UNABLE TO DECODE PACKET");
      continue;
    }
    
    // did we get an entire raw frame from the packet?
    if (frame_finished) {
      // Find the size of all pFrame->extended_data in bytes. Remember, this will be:
      // data_size = pFrame->nb_samples * pFrame->channels * bytes_per_sample
      int data_size = av_samples_get_buffer_size(
                                                 is_planar ? &pFrame->linesize[0] : NULL,
                                                 data->channels,
                                                 pFrame->nb_samples,
                                                 data->decoder_context->sample_fmt,
                                                 1
                                                 );
      
      if (raw_sample_rate == 0) {
        raw_sample_rate = pFrame->sample_rate;
      }
      
      // if we don't have enough space in our copy buffer, expand it
      if (populate_sample_buffer && total_size + data_size > allocated_buffer_size) {
        allocated_buffer_size = allocated_buffer_size * 1.25;
        data->samples = realloc(data->samples, allocated_buffer_size);
      }
      
      if (is_planar) {
        // normalize all planes into the interleaved sample buffer
        int i = 0;
        int c = 0;
        
        // data_size is total data overall for all planes.
        // iterate through extended_data and copy each sample into `samples` while
        // interleaving each channel (copy sample one from left, then right. copy sample
        // two from left, then right, etc.)
        for (; i < data_size / data->channels; i += data->sample_size) {
          for (c = 0; c < data->channels; c++) {
            if (populate_sample_buffer) {
              memcpy(data->samples + total_size, pFrame->extended_data[c] + i, data->sample_size);
            }
            
            total_size += data->sample_size;
          }
        }
      } else {
        // source file is already interleaved. just copy the raw data from the frame into
        // the `samples` buffer.
        if (populate_sample_buffer) {
          memcpy(data->samples + total_size, pFrame->extended_data[0], data_size);
        }
        
        total_size += data_size;
      }
    }
    
    // Packets must be freed, otherwise you'll have a fix a hole where the rain gets in
    // (and keep your mind from wandering...)
    av_free_packet(&packet);
  }
  
  data->size = total_size;
  data->sample_rate = raw_sample_rate;
  
  if (total_size == 0) {
    // not a single packet could be read.
    return;
  }
  
  data->duration = (data->size * 8.0) / (raw_sample_rate * data->sample_size * 8.0 * data->channels);
}



/*
 * Take the given AudioData struct and convert all the compressed data
 * into the raw interleaved sample buffer.
 *
 * This function also calculates and populates the metadata information from
 * `read_audio_metadata`.
 */
void read_audio_data(AudioData *data) {
  read_raw_audio_data(data, 1);
}

/*
 * Take the given AudioData struct and calculate all of the properties
 * without doing any of the memory operations on the raw sample data.
 *
 * This is so we can get accurate metadata about the file (which we can't
 * really do for all formats unless we look at the raw data underneith, hence
 * why somethings ffmpeg isn't entirely accurate with duration via ffprobe)
 * without the overhead of image drawing.
 *
 * NOTE: data->samples will still not be valid after calling this function.
 * If you care about this information but also want data->samples to be
 * populated, use `read_audio_data` instead
 */
void read_audio_metadata(AudioData *data) {
  read_raw_audio_data(data, 0);
}

NSMutableArray *draw_combined_waveform(AudioData *data) {

    int width = 2 * (int)(data->format_context->duration / (double) AV_TIME_BASE);
  
    NSMutableArray *values = [NSMutableArray  arrayWithCapacity:width];
  
    // figure out the min and max ranges of samples, based on bit depth and format
    int sample_min;
    int sample_max;
    
    get_format_range(data->format, &sample_min, &sample_max);
    
    uint32_t sample_range = sample_max - sample_min; // total range of values a sample can have
    int sample_count = data->size / data->sample_size; // how many samples are there total?
  
    NSLog(@"SAMPLE COUNT: %d DURATION:%d ", sample_count, width / 2);
  
    int samples_per_pixel = sample_count / width; // how many samples fit in a column of pixels?
    
    // multipliers used to produce averages while iterating through samples.
    double channel_average_multiplier = 1.0 / data->channels;

    int track_height = 100;
    
    // for each column of pixels in the final output image
    int x;
    for (x = 0; x < width; ++x) {
        // find the average sample value, the minimum sample value, and the maximum
        // sample value within the the range of samples that fit within this column of pixels
        double min = sample_max;
        double max = sample_min;
        
        //for each "sample", which is really a sample for each channel,
        //reduce the samples * channels value to a single value that is
        //the average of the samples for each channel.
        int i;
        for (i = 0; i < samples_per_pixel; i += data->channels) {
            double value = 0;
            
            int c;
            for (c = 0; c < data->channels; ++c) {
                int index = x * samples_per_pixel + i + c;
                
                value += get_sample(data, index) * channel_average_multiplier;
            }
            
            if (value < min) {
                min = value;
            }
            
            if (value > max) {
                max = value;
            }
        }
        
        // calculate the y pixel values that represent the waveform for this column of pixels.
        // they are subtracted from last_y to flip the waveform image, putting positive
        // numbers above the center of waveform and negative numbers below.
        int y_max = track_height - ((min - sample_min) * track_height / sample_range);
        int y_min = track_height - ((max - sample_min) * track_height / sample_range);
      
        [values addObject:[NSNumber numberWithInt:y_max - y_min]];
    }
    return values;
}


@implementation WaveformGenerator

+ (void)initialize {
  av_register_all();
  avcodec_register_all();
}

+ (NSString *)generate:(NSString *)sourceFilename {
  
  NSLog(@"Generating waveform for %@", sourceFilename);
  
  int width = 256; // default width of the generated png image
  int height = -1; // default height of the generated png image
  int track_height = 100; // default height of each track
  int monofy = 1; // should we reduce everything into one waveform
  int metadata = 0; // should we just spit out metadata and not draw an image
  const char *pFilePath = [sourceFilename UTF8String]; // audio input file path

  AVFormatContext *pFormatContext = NULL; // Container for the audio file
  AVCodecContext *pDecoderContext = NULL; // Container for the stream's codec
  AVCodec *pDecoder = NULL; // actual codec for the stream
  int stream_index = 0; // which audio stream should be looked at
  
  // open the audio file
  if (avformat_open_input(&pFormatContext, pFilePath, NULL, NULL) < 0) {
    NSLog(@"Cannot open input file.\n");
    return nil;
  }
  
  // Tell ffmpeg to read the file header and scan some of the data to determine
  // everything it can about the format of the file
  if (avformat_find_stream_info(pFormatContext, NULL) < 0) {
    NSLog(@"Cannot find stream information.\n");
    return nil;
  }
  
  // find the audio stream we probably care about.
  // For audio files, there will most likely be only one stream.
  stream_index = av_find_best_stream(pFormatContext, AVMEDIA_TYPE_AUDIO, -1, -1, &pDecoder, 0);
  
  if (stream_index < 0) {
    NSLog(@"Unable to find audio stream in file.\n");
    return nil;
  }
  
  // now that we have a stream, get the codec for the given stream
  pDecoderContext = pFormatContext->streams[stream_index]->codec;
  
  av_opt_set_int(pDecoderContext, "refcounted_frames", 1, 0);
  
  // open the decoder for this audio stream
  if (avcodec_open2(pDecoderContext, pDecoder, NULL) < 0) {
    NSLog(@"Cannot open audio decoder.");
    return nil;
  }
  
  AudioData *data = create_audio_data_struct(pFormatContext, pDecoderContext);
  
  if (data == NULL) {
    NSLog(@"Cannot run audio decoder.");
    return nil;
  }

  // fetch the raw data and the metadata
  read_audio_data(data);
  
  if (data->size == 0) {
    NSLog(@"Cannot run audio decoder.");
    return nil;
  }
    
  NSMutableArray *values = draw_combined_waveform(data);
    
  free_audio_data(data);

  NSError *writeError;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:values options:NSJSONWritingPrettyPrinted error:&writeError];
  NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
  
  if(writeError != nil) {
    RCTLogInfo(@"Unable to serialize JSON");
    return nil;
  }
  
  return jsonString;
  
}


@end;