// ApolloHideFeedPostImages.xm
//
// Text-only feed mode: collapses images, galleries, videos and link preview
// cards, including compact thumbnails, WITHOUT changing RDKLink data.
// The author/title/meta nodes live outside RichMediaNode. When a text post
// includes a selfPostPreviewNode, retain that text node in the feed layout.
// Opening a post uses CommentsHeaderCellNode, whose media stays untouched.
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
#import "Tweak.h" // RDKLink.selfPost

static char kApolloFeedOnlyRichMediaKey;
static char kApolloCompactThumbOriginalSizeKey;
static char kApolloCompactThumbOriginalMaxSizeKey;

// Only add genuine self-post text content as a child. Media and link-card
// children are excluded from the resulting layout spec entirely, so no
// picture/video placeholder height survives in the feed. Creating a new
// Texture spec for each measurement avoids shared-layout-tree ownership.
static id ApolloFeedTextOnlySpec(id textPreviewNode) {
    Class stackClass = ApolloClassASStackLayoutSpec;
    if (!stackClass) return nil;
    NSArray *children = textPreviewNode ? @[ textPreviewNode ] : @[];
    return [(id)stackClass stackLayoutSpecWithDirection:0
                                              spacing:0
                                       justifyContent:0
                                           alignItems:0
                                             children:children];
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

// First layout may construct the rich media after the parent marking pass.
// The ancestor check covers that path without affecting the comments header
// or the separate Save as Image preview node tree.
static BOOL ApolloFeedMediaBelongsToLargePostCell(id node) {
    if ([objc_getAssociatedObject(node, &kApolloFeedOnlyRichMediaKey) boolValue]) return YES;
    id parent = ((ASDisplayNode *)node).supernode;
    for (NSUInteger depth = 0; parent && depth < 12; depth++) {
        if (ApolloClassLargePostCellNode &&
            [parent isKindOfClass:ApolloClassLargePostCellNode]) return YES;
        parent = ((ASDisplayNode *)parent).supernode;
    }
    return NO;
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
    id spec = %orig;
    if (sHideFeedPostImages) ApolloFeedMarkCellImages(self);
    return spec;
}

- (void)didLoad {
    %orig;
    if (sHideFeedPostImages) ApolloFeedMarkCellImages(self);
}

%end

%hook _TtC6Apollo13RichMediaNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    if (!sHideFeedPostImages ||
        !ApolloFeedMediaBelongsToLargePostCell(self) ||
        ApolloReadBoolIvar(self, "isShownInCommentsHeader", NO)) {
        return %orig;
    }

    // For image, gallery, video and external-link posts, all of this
    // RichMediaNode is presentation media (the post's title and vote/comment
    // text are sibling nodes in the LargePostCellNode). Removing the children
    // hides both the visible preview and its reserved height.
    //
    // For text/self posts, selfPostPreviewNode is the readable body excerpt,
    // and MUST be preserved even when the same RichMediaNode also owns an
    // embedded-image hero, a video or linkButtonNode.
    RDKLink *link = (RDKLink *)ApolloObjectIvar(self, "link");
    id bodyText = (link && link.selfPost)
        ? ApolloObjectIvar(self, "selfPostPreviewNode") : nil;
    id textOnly = ApolloFeedTextOnlySpec(bodyText);
    return textOnly ?: %orig;
}

%end

%hook _TtC6Apollo24CompactPostThumbnailNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    ApolloFeedSetCompactThumbSizing(self, sHideFeedPostImages);
    if (sHideFeedPostImages) {
        id empty = ApolloFeedTextOnlySpec(nil);
        if (empty) return empty;
    }
    return %orig;
}

%end
