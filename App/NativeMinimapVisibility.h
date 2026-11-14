#import <TargetConditionals.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#if TARGET_OS_SIMULATOR
static BOOL RPSFixtureMinimapVisible=YES;
static BOOL RPSNativeMinimapVisible(void) {return RPSFixtureMinimapVisible;}
#elif defined(__arm64__) && !TARGET_OS_SIMULATOR
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <QuartzCore/QuartzCore.h>

typedef void *(*RPSManagedGetter)(void *);
typedef bool (*RPSManagedPredicate)(void *);
typedef struct {float red,green,blue,alpha;} RPSUnityColor;

static uintptr_t RPSMinimapMethod(uintptr_t image,NSDictionary *functions,NSString *name) {
    return image+[functions[name] unsignedLongLongValue];
}

static BOOL RPSVisibleCanvasGroups(uintptr_t image,NSDictionary *functions,int32_t groupIndex,void *graphic) {
    void *(*typeHandle)(int32_t)=(void *(*)(int32_t))(RPSMinimapMethod(image,functions,@"typeHandle"));
    RPSManagedGetter typeObject=(RPSManagedGetter)(RPSMinimapMethod(image,functions,@"typeObject"));
    void *canvasGroupType=typeObject(typeHandle(groupIndex));
    if(!canvasGroupType) return NO;
    RPSManagedGetter transform=(RPSManagedGetter)(RPSMinimapMethod(image,functions,@"transform"));
    RPSManagedGetter parent=(RPSManagedGetter)(RPSMinimapMethod(image,functions,@"parent"));
    void *(*component)(void *,void *)=(void *(*)(void *,void *))(RPSMinimapMethod(image,functions,@"component"));
    RPSManagedPredicate enabled=(RPSManagedPredicate)(RPSMinimapMethod(image,functions,@"enabled"));
    float (*groupAlpha)(void *)=(float (*)(void *))(RPSMinimapMethod(image,functions,@"groupAlpha"));
    RPSManagedPredicate ignoreParentGroups=(RPSManagedPredicate)(RPSMinimapMethod(image,functions,@"ignoreParentGroups"));
    float alpha=1;
    for(void *node=transform(graphic);node;node=parent(node)){
        void *group=component(node,canvasGroupType);
        if(!group || !enabled(group)) continue;
        alpha*=groupAlpha(group);
        if(alpha<=.01f) return NO;
        if(ignoreParentGroups(group)) break;
    }
    return alpha>.01f;
}

// The signed app bundle supplies the method locations for its exact game image.
// The public simulator fixture has no game image or bindings.
static uintptr_t RPSVerifiedMinimapImage(NSUUID *version,NSDictionary *functions) {
    const struct mach_header_64 *image=(const struct mach_header_64 *)_dyld_get_image_header(0);
    if(!version || !image || image->magic!=MH_MAGIC_64 || image->sizeofcmds>131072) return 0;
    uuid_t expectedUUID;
    [version getUUIDBytes:expectedUUID];
    BOOL matched=NO;
    uint64_t textSize=0;
    const uint8_t *cursor=(const uint8_t *)(image+1),*end=cursor+image->sizeofcmds;
    for(uint32_t i=0;i<image->ncmds && end-cursor>=sizeof(struct load_command);i++){
        const struct load_command *load=(const struct load_command *)cursor;
        if(load->cmdsize<sizeof(*load) || load->cmdsize>end-cursor) return 0;
        if(load->cmd==LC_UUID && load->cmdsize==sizeof(struct uuid_command)){
            const struct uuid_command *identity=(const struct uuid_command *)load;
            matched=memcmp(identity->uuid,expectedUUID,sizeof(expectedUUID))==0;
        }else if(load->cmd==LC_SEGMENT_64 && load->cmdsize>=sizeof(struct segment_command_64)){
            const struct segment_command_64 *segment=(const struct segment_command_64 *)load;
            if(memcmp(segment->segname,"__TEXT",7)==0 && segment->fileoff==0) textSize=segment->filesize;
        }
        cursor+=load->cmdsize;
    }
    if(!matched || !textSize) return 0;
    for(NSString *key in @[@"findByID",@"typeHandle",@"typeObject",@"findObject",@"instanceID",@"enabled",@"background",@"renderer",@"culled",@"renderColor",@"transform",@"parent",@"component",@"groupAlpha",@"ignoreParentGroups"]){
        NSNumber *method=functions[key];
        if(![method isKindOfClass:NSNumber.class]) return 0;
        uint64_t offset=method.unsignedLongLongValue;
        if(offset<sizeof(*image)+image->sizeofcmds || offset>=textSize || offset%4!=0) return 0;
    }
    return (uintptr_t)image;
}

static BOOL RPSNativeMinimapVisible(void) {
    if(!NSThread.isMainThread) return NO;
    static uintptr_t image;
    static NSDictionary *bindings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url=[NSBundle.mainBundle URLForResource:@"RuntimeIntegration" withExtension:@"plist"];
        NSDictionary *config=url ? [NSDictionary dictionaryWithContentsOfURL:url] : nil;
        id candidate=config[@"NativeMinimapVisibility"];
        if(![candidate isKindOfClass:NSDictionary.class]) return;
        bindings=candidate;
        id uuid=bindings[@"imageUUID"],functions=bindings[@"methodOffsets"];
        NSUInteger mapType=[bindings[@"minimapType"] unsignedIntegerValue];
        NSUInteger groupType=[bindings[@"canvasGroupType"] unsignedIntegerValue];
        if([uuid isKindOfClass:NSString.class] && [functions isKindOfClass:NSDictionary.class] &&
            mapType>0 && mapType<1000000 && groupType>0 && groupType<1000000)
            image=RPSVerifiedMinimapImage([[NSUUID alloc] initWithUUIDString:uuid],functions);
    });
    if(!image) return NO;

    NSDictionary *functions=bindings[@"methodOffsets"];
    int32_t mapType=[bindings[@"minimapType"] intValue];
    // Keep only Unity's instance ID. Scene unloads can destroy the managed view.
    static int32_t minimapID;
    static const void *minimapClass;
    static CFTimeInterval nextSearch;
    void *(*findByID)(int32_t)=(void *(*)(int32_t))(RPSMinimapMethod(image,functions,@"findByID"));
    void *minimap=minimapID ? findByID(minimapID) : NULL;
    if(!minimap || *(void **)minimap!=minimapClass){
        minimapID=0;
        CFTimeInterval now=CACurrentMediaTime();
        if(now<nextSearch) return NO;
        nextSearch=now+.15;
        void *(*typeHandle)(int32_t)=(void *(*)(int32_t))(RPSMinimapMethod(image,functions,@"typeHandle"));
        RPSManagedGetter typeObject=(RPSManagedGetter)(RPSMinimapMethod(image,functions,@"typeObject"));
        RPSManagedGetter findObject=(RPSManagedGetter)(RPSMinimapMethod(image,functions,@"findObject"));
        int32_t (*instanceID)(void *)=(int32_t (*)(void *))(RPSMinimapMethod(image,functions,@"instanceID"));
        void *type=typeObject(typeHandle(mapType));
        if(!type || !(minimap=findObject(type))) return NO;
        minimapClass=*(void **)minimap;
        minimapID=instanceID(minimap);
    }

    RPSManagedPredicate enabled=(RPSManagedPredicate)(RPSMinimapMethod(image,functions,@"enabled"));
    if(!enabled(minimap)) return NO;
    RPSManagedGetter background=(RPSManagedGetter)(RPSMinimapMethod(image,functions,@"background")); // get_imgMiniBack
    void *graphic=background(minimap);
    if(!graphic || !enabled(graphic)) return NO;
    RPSManagedGetter rendererForGraphic=(RPSManagedGetter)(RPSMinimapMethod(image,functions,@"renderer"));
    void *renderer=rendererForGraphic(graphic);
    RPSManagedPredicate culled=(RPSManagedPredicate)(RPSMinimapMethod(image,functions,@"culled"));
    RPSUnityColor (*renderColor)(void *)=(RPSUnityColor (*)(void *))(RPSMinimapMethod(image,functions,@"renderColor"));
    return renderer && !culled(renderer) && renderColor(renderer).alpha>.01f && RPSVisibleCanvasGroups(image,functions,[bindings[@"canvasGroupType"] intValue],graphic);
}
#else
static BOOL RPSNativeMinimapVisible(void) {return NO;}
#endif
