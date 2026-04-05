#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Callback block invoked for each streamed response chunk.
/// @param chunk  The text fragment. May be empty on the final call.
/// @param done   YES when generation is complete or cancelled.
/// @param error  Non-nil if generation failed.
typedef void (^LiteRTLMStreamCallback)(NSString *chunk, BOOL done, NSError * _Nullable error);

/// Objective-C++ bridge to the LiteRT-LM inference SDK.
///
/// Models the LiteRT-LM Conversation API:
/// - One heavyweight ``Engine`` per loaded model.
/// - Lightweight ``Conversation`` objects per session.
/// - ``SendMessageAsync`` for streaming multimodal content.
///
/// Current implementation is a **stub** that mirrors the real API shape
/// but returns simulated responses. Each method marked with
/// ``// TODO: Replace with real LiteRT-LM SDK calls`` is a placeholder
/// for the actual SDK integration once the iOS C++ headers ship.
///
/// Thread-safety: all public methods are safe to call from any thread.
/// The bridge serialises access internally.
@interface LiteRTLMBridge : NSObject

/// Whether the engine is loaded and ready for inference.
@property (nonatomic, readonly) BOOL isEngineReady;

/// Whether a conversation session is currently active.
@property (nonatomic, readonly) BOOL hasActiveConversation;

#pragma mark - Engine lifecycle

/// Create the inference engine from a model file on disk.
/// @param modelPath  Absolute path to the ``.task`` / ``.tflite`` model file.
/// @param error      Populated on failure.
/// @return YES on success.
- (BOOL)createEngineWithModelPath:(NSString *)modelPath
                            error:(NSError * _Nullable * _Nullable)error;

/// Tear down the engine and release all resources.
- (void)destroyEngine;

#pragma mark - Conversation management

/// Create a new conversation session from the current engine.
/// Resets any prior conversation state.
/// @param error  Populated on failure (e.g. engine not loaded).
/// @return YES on success.
- (BOOL)createConversation:(NSError * _Nullable * _Nullable)error;

/// Reset the current conversation without destroying the engine.
- (void)resetConversation;

#pragma mark - Multimodal generation

/// Send a multimodal message (text + optional image) and stream the response.
///
/// Models the LiteRT-LM ``SendMessageAsync`` pattern with ordered content
/// parts: an image file part followed by a text part.
///
/// @param prompt     The user's text prompt.
/// @param imagePath  Absolute path to a JPEG/PNG image file (may be nil for text-only).
/// @param callback   Invoked on a background queue for each streamed chunk.
///                   The final invocation has ``done == YES``.
- (void)sendMessage:(NSString *)prompt
          imagePath:(nullable NSString *)imagePath
           callback:(LiteRTLMStreamCallback)callback;

/// Best-effort cancellation of the current generation.
///
/// Sets an internal flag that the generation loop checks between chunks.
/// Late chunks that arrive after cancel may still be delivered.
///
/// **Limitation:** The current LiteRT-LM C++ API does not expose a native
/// cancel primitive. This implementation uses a fence flag; the generation
/// callback will receive ``done == YES`` once the flag is observed, but
/// the underlying computation may continue briefly until the next yield
/// point. Do not rely on instant cancellation for safety-critical paths.
- (void)cancelGeneration;

@end

/// Error domain for LiteRTLMBridge errors.
FOUNDATION_EXPORT NSString * const LiteRTLMBridgeErrorDomain;

typedef NS_ENUM(NSInteger, LiteRTLMBridgeErrorCode) {
    LiteRTLMBridgeErrorCodeEngineCreationFailed = 1,
    LiteRTLMBridgeErrorCodeEngineNotReady       = 2,
    LiteRTLMBridgeErrorCodeConversationFailed   = 3,
    LiteRTLMBridgeErrorCodeImageLoadFailed      = 4,
    LiteRTLMBridgeErrorCodeGenerationFailed     = 5,
    LiteRTLMBridgeErrorCodeCancelled            = 6,
};

NS_ASSUME_NONNULL_END
