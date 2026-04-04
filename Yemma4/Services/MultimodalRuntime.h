#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YemmaPromptImageInput : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *filePath;

- (instancetype)initWithIdentifier:(NSString *)identifier
                          filePath:(NSString *)filePath NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface YemmaMultimodalRuntime : NSObject

@property (nonatomic, readonly) BOOL supportsVision;

- (nullable instancetype)initWithMMProjPath:(NSString *)mmprojPath
                                      model:(void *)model
                                      error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (BOOL)evaluatePrompt:(NSString *)prompt
                images:(NSArray<YemmaPromptImageInput *> *)images
               context:(void *)context
   promptPositionLimit:(int32_t)promptPositionLimit
      promptTokenCount:(int32_t * _Nullable)promptTokenCount
   promptPositionCount:(int32_t * _Nullable)promptPositionCount
                 nPast:(int32_t)nPast
                nBatch:(int32_t)nBatch
              newNPast:(int32_t * _Nullable)newNPast
                 error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
