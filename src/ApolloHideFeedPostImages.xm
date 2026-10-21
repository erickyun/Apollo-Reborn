// ApolloHideFeedPostImages.xm
//
// Collapses still-image, gallery and compact-thumbnail previews in the post
// feed WITHOUT changing RDKLink data. Opening the post uses
// CommentsHeaderCellNode, whose media layout remains untouched.
//
// Scope is explicit: LargePostCellNode marks its RichMediaNode and any
// crosspost media node before Texture measures them. A comments header or a
// share-as-image preview is never marked, so those still show images.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloState.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloTextureDecls.h"
#import "ApolloClasses.h"

static char kApolloFeedOnlyRichMediaKey;
static char kApolloCompactThumbOriginalSizeKey;
static char kApolloCompactThumbOriginalMaxSizeKey;

// Shared Texture layout specs must not be reused between parents; produce a
// fresh, zero-child vertical stack for each measure. Using the runtime Class
// avoids linking against Apollo's private Texture framework.
static id ApolloFeedEmptyImageSpec(void) {
    Class stackClass = ApolloClassASStackLayoutSpec;
    if (!stackClass) return nil;
    return [(id)stackClass stackLayoutSpecWithDirection:0
                                              spacing:0
                                       justifyContent:0
                                           alignItems:0
                                             children:@[]];
}

static void ApolloFeedMarkRichMedia(id richMediaNode) {
    if (!richMediaNode) return;
    objc_setAssociatedObject(richMediaNode, &kApolloFeedOnlyRichMediaKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloFeedMarkCellImages(id cell) {
    if (!cell) return;
    ApolloFeedMarkRichMedia(ApolloObjectIvar(cell, "richMediaNode"));
    id crosspost = ApolloObjectIvar(cell, "crosspostNode");
    if (crosspost) ApolloFeedMarkRichMedia(ApolloObjectIvar(crosspost, "richMediaNode"));
}

// Compress the compact thumbnail node itself as well as its layout spec:
// simply making an image transparent would leave the picture-size gutter.
// Save Texture's sizing inputs, so toggling the preference off can restore
// them without losing the user's original compact-post appearance.
@interface ASLayoutElementStyle (ApolloFeedPreviewSizing)
@property (nonatomic) CGSize preferredSize;
@property (nonatomic) CGSize maxSize;
@end

static void ApolloFeedSetCompactThumbSizing(id node, BOOL hidden) {
    ASLayoutElementStyle *style = ((ASDisplayNode *)node).style;
    if (!style) return;
    NSValue *originalSize = objc_getAssociatedObject(node, &kApolloCompactThumbOriginalSizeKey);
    NSValue *originalMax = objc_getAssociatedObject(node, &kApolloCompactThumbOriginalMaxSizeKey);
    if (hidden) {
        if (!originalSize) {
            objc_setAssociatedObject(node, &kApolloCompactThumbOriginalSizeKey,
                                     [NSValue valueWithCGSize:style.preferredSize], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(node, &kApolloCompactThumbOriginalMaxSizeKey,
                                     [NSValue valueWithCGSize:style.maxSize], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        style.preferredSize = CGSizeZero;
        style.maxSize = CGSizeZero;
    } else if (originalSize) {
        style.preferredSize = originalSize.CGSizeValue;
        if (originalMax) style.maxSize = originalMax.CGSizeValue;
    }
}

%hook _TtC6Apollo17LargePostCellNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    // Mark early: child RichMediaNode can measure off-main before didLoad.
    if (sHideFeedPostImages) ApolloFeedMarkCellImages(self);
    return %orig;
}

- (void)didLoad {
    %orig;
    if (sHideFeedPostImages) ApolloFeedMarkCellImages(self);
}

%end

%hook _TtC6Apollo13RichMediaNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    if (!sHideFeedPostImages ||
        ![objc_getAssociatedObject(self, &kApolloFeedOnlyRichMediaKey) boolValue] ||
        ApolloReadBoolIvar(self, "isShownInCommentsHeader", NO)) {
        return %orig;
    }

    // Hide still pictures, albums and linked image previews, but leave
    // feed video players and self-post text alone. Text-only RichMediaNodes
    // have no native image nodes, and embedded self-post hero thumbnails are
    // independently suppressed in ApolloFeedTextPostThumbnails.xm.
    id imageNode = ApolloObjectIvar(self, "thumbnailNode");
    id albumNode = ApolloObjectIvar(self, "albumThumbnailsNode");
    id videoNode = ApolloObjectIvar(self, "videoNode");
    if ((!imageNode && !albumNode) || videoNode) return %orig;

    id empty = ApolloFeedEmptyImageSpec();
    return empty ?: %orig;
}

%end

%hook _TtC6Apollo24CompactPostThumbnailNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloFeedSetCompactThumbSizing(self, sHideFeedPostImages);
    if (sHideFeedPostImages) {
        id empty = ApolloFeedEmptyImageSpec();
        if (empty) return empty;
    }
    return %orig;
}

%end
