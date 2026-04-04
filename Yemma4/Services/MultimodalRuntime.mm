#import "MultimodalRuntime.h"

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#include <algorithm>
#include <memory>
#include <vector>

#ifdef DEBUG
#undef DEBUG
#endif

#include "../ThirdParty/llama_mtmd/clip.cpp"
#include "../ThirdParty/llama_mtmd/mtmd-image.cpp"
#include "../ThirdParty/llama_mtmd/mtmd-audio.cpp"
#include "../ThirdParty/llama_mtmd/mtmd.cpp"
#include "../ThirdParty/llama_mtmd/models/cogvlm.cpp"
#include "../ThirdParty/llama_mtmd/models/conformer.cpp"
#include "../ThirdParty/llama_mtmd/models/deepseekocr.cpp"
#include "../ThirdParty/llama_mtmd/models/gemma4v.cpp"
#include "../ThirdParty/llama_mtmd/models/glm4v.cpp"
#include "../ThirdParty/llama_mtmd/models/internvl.cpp"
#include "../ThirdParty/llama_mtmd/models/kimik25.cpp"
#include "../ThirdParty/llama_mtmd/models/kimivl.cpp"
#include "../ThirdParty/llama_mtmd/models/llama4.cpp"
#include "../ThirdParty/llama_mtmd/models/llava.cpp"
#include "../ThirdParty/llama_mtmd/models/minicpmv.cpp"
#include "../ThirdParty/llama_mtmd/models/mobilenetv5.cpp"
#include "../ThirdParty/llama_mtmd/models/nemotron-v2-vl.cpp"
#include "../ThirdParty/llama_mtmd/models/paddleocr.cpp"
#include "../ThirdParty/llama_mtmd/models/pixtral.cpp"
#include "../ThirdParty/llama_mtmd/models/qwen2vl.cpp"
#include "../ThirdParty/llama_mtmd/models/qwen3vl.cpp"
#include "../ThirdParty/llama_mtmd/models/siglip.cpp"
#include "../ThirdParty/llama_mtmd/models/whisper-enc.cpp"
#include "../ThirdParty/llama_mtmd/models/youtuvl.cpp"

#ifdef MTMD_INTERNAL_HEADER
#undef MTMD_INTERNAL_HEADER
#endif

#include "../ThirdParty/llama_mtmd/mtmd-helper.cpp"

static NSString * const YemmaMultimodalErrorDomain = @"com.avmillabs.yemma4.multimodal";

typedef NS_ENUM(NSInteger, YemmaMultimodalErrorCode) {
    YemmaMultimodalErrorCodeInitializationFailed = 1,
    YemmaMultimodalErrorCodeImageLoadFailed = 2,
    YemmaMultimodalErrorCodeTokenizationFailed = 3,
    YemmaMultimodalErrorCodePromptTooLong = 4,
    YemmaMultimodalErrorCodeEvaluationFailed = 5,
};

static NSError * YemmaMakeMultimodalError(YemmaMultimodalErrorCode code, NSString * description) {
    return [NSError errorWithDomain:YemmaMultimodalErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static int YemmaRecommendedThreadCount(void) {
    return std::max(1, (int) [NSProcessInfo processInfo].activeProcessorCount - 2);
}

struct YemmaBitmapDeleter {
    void operator()(mtmd_bitmap * bitmap) const {
        if (bitmap != nullptr) {
            mtmd_bitmap_free(bitmap);
        }
    }
};

using YemmaBitmapPtr = std::unique_ptr<mtmd_bitmap, YemmaBitmapDeleter>;

@implementation YemmaPromptImageInput

- (instancetype)initWithIdentifier:(NSString *)identifier
                          filePath:(NSString *)filePath {
    self = [super init];
    if (self != nil) {
        _identifier = [identifier copy];
        _filePath = [filePath copy];
    }
    return self;
}

@end

@implementation YemmaMultimodalRuntime {
    mtmd_context * _context;
}

- (nullable instancetype)initWithMMProjPath:(NSString *)mmprojPath
                                      model:(void *)model
                                      error:(NSError * _Nullable __autoreleasing *)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    mtmd_context_params params = mtmd_context_params_default();
#if TARGET_OS_SIMULATOR
    params.use_gpu = false;
#else
    params.use_gpu = true;
#endif
    params.print_timings = false;
    params.n_threads = YemmaRecommendedThreadCount();
    params.warmup = true;

    _context = mtmd_init_from_file(
        mmprojPath.fileSystemRepresentation,
        static_cast<const llama_model *>(model),
        params
    );

    if (_context == nullptr) {
        if (error != nullptr) {
            *error = YemmaMakeMultimodalError(
                YemmaMultimodalErrorCodeInitializationFailed,
                [NSString stringWithFormat:@"Failed to initialize the multimodal projector at %@.", mmprojPath]
            );
        }
        return nil;
    }

    return self;
}

- (void)dealloc {
    if (_context != nullptr) {
        mtmd_free(_context);
        _context = nullptr;
    }
}

- (BOOL)supportsVision {
    return _context != nullptr && mtmd_support_vision(_context);
}

- (BOOL)evaluatePrompt:(NSString *)prompt
                images:(NSArray<YemmaPromptImageInput *> *)images
               context:(void *)context
   promptPositionLimit:(int32_t)promptPositionLimit
      promptTokenCount:(int32_t * _Nullable)promptTokenCount
   promptPositionCount:(int32_t * _Nullable)promptPositionCount
                 nPast:(int32_t)nPast
                nBatch:(int32_t)nBatch
              newNPast:(int32_t * _Nullable)newNPast
                 error:(NSError * _Nullable __autoreleasing *)error {
    if (_context == nullptr) {
        if (error != nullptr) {
            *error = YemmaMakeMultimodalError(
                YemmaMultimodalErrorCodeInitializationFailed,
                @"The multimodal runtime is not initialized."
            );
        }
        return NO;
    }

    std::vector<YemmaBitmapPtr> bitmaps;
    bitmaps.reserve(images.count);

    for (YemmaPromptImageInput * image in images) {
        NSData * data = [NSData dataWithContentsOfFile:image.filePath options:NSDataReadingMappedIfSafe error:nil];
        if (data.length == 0) {
            if (error != nullptr) {
                *error = YemmaMakeMultimodalError(
                    YemmaMultimodalErrorCodeImageLoadFailed,
                    [NSString stringWithFormat:@"Failed to read the image attachment at %@.", image.filePath]
                );
            }
            return NO;
        }

        mtmd_bitmap * bitmap = mtmd_helper_bitmap_init_from_buf(
            _context,
            static_cast<const unsigned char *>(data.bytes),
            data.length
        );
        if (bitmap == nullptr) {
            if (error != nullptr) {
                *error = YemmaMakeMultimodalError(
                    YemmaMultimodalErrorCodeImageLoadFailed,
                    [NSString stringWithFormat:@"Failed to decode the image attachment at %@.", image.filePath]
                );
            }
            return NO;
        }

        mtmd_bitmap_set_id(bitmap, image.identifier.UTF8String);
        bitmaps.emplace_back(bitmap);
    }

    std::vector<const mtmd_bitmap *> bitmapPointers;
    bitmapPointers.reserve(bitmaps.size());
    for (const YemmaBitmapPtr & bitmap : bitmaps) {
        bitmapPointers.push_back(bitmap.get());
    }

    std::unique_ptr<mtmd_input_chunks, void (*)(mtmd_input_chunks *)> chunks(
        mtmd_input_chunks_init(),
        mtmd_input_chunks_free
    );
    if (chunks == nullptr) {
        if (error != nullptr) {
            *error = YemmaMakeMultimodalError(
                YemmaMultimodalErrorCodeTokenizationFailed,
                @"Failed to allocate multimodal prompt chunks."
            );
        }
        return NO;
    }

    mtmd_input_text inputText = {
        .text = prompt.UTF8String,
        .add_special = true,
        .parse_special = true,
    };

    const mtmd_bitmap ** bitmapArray = bitmapPointers.empty() ? nullptr : bitmapPointers.data();
    const int32_t tokenizeStatus = mtmd_tokenize(
        _context,
        chunks.get(),
        &inputText,
        bitmapArray,
        bitmapPointers.size()
    );

    if (tokenizeStatus != 0) {
        if (error != nullptr) {
            NSString * description = tokenizeStatus == 1
                ? @"The number of attached images did not match the prompt markers."
                : @"The multimodal prompt could not be tokenized.";
            *error = YemmaMakeMultimodalError(YemmaMultimodalErrorCodeTokenizationFailed, description);
        }
        return NO;
    }

    const int32_t tokenCount = (int32_t) mtmd_helper_get_n_tokens(chunks.get());
    const int32_t positionCount = (int32_t) mtmd_helper_get_n_pos(chunks.get());

    if (promptTokenCount != nullptr) {
        *promptTokenCount = tokenCount;
    }
    if (promptPositionCount != nullptr) {
        *promptPositionCount = positionCount;
    }

    if (promptPositionLimit > 0 && nPast + positionCount > promptPositionLimit) {
        if (error != nullptr) {
            *error = YemmaMakeMultimodalError(
                YemmaMultimodalErrorCodePromptTooLong,
                [NSString stringWithFormat:
                    @"This conversation is too long for the model context (%d positions, limit %d). Start a new chat or shorten your message.",
                    nPast + positionCount,
                    promptPositionLimit]
            );
        }
        return NO;
    }

    llama_pos computedNewPast = nPast;
    const int32_t evalStatus = mtmd_helper_eval_chunks(
        _context,
        static_cast<llama_context *>(context),
        chunks.get(),
        nPast,
        0,
        nBatch,
        true,
        &computedNewPast
    );

    if (evalStatus != 0) {
        if (error != nullptr) {
            *error = YemmaMakeMultimodalError(
                YemmaMultimodalErrorCodeEvaluationFailed,
                [NSString stringWithFormat:@"Multimodal prompt evaluation failed with status %d.", evalStatus]
            );
        }
        return NO;
    }

    if (newNPast != nullptr) {
        *newNPast = computedNewPast;
    }

    return YES;
}

@end
