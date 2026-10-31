#import "DiaPatches.h"

// Button hooks are added per class as buttons appear, so the count isn't fixed. Running out must stop here:
// a hook that silently didn't land leaves its callers asking DPOriginalIMP for an original it never stored.
typedef struct { Class cls; SEL sel; IMP replacement, original; const char *name; } DPOriginal;
static DPOriginal DPOriginals[256];
static int DPOriginalCount;

void DPHookFunction(Class cls, SEL sel, IMP replacement, const char *name) {
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) return;
    for (int i = 0; i < DPOriginalCount; i++) {
        DPOriginal hook = DPOriginals[i];
        if (hook.sel != sel || strcmp(hook.name, name)) continue;
        // Two functions with one name on one selector would share their originals.
        if (hook.replacement != replacement) abort();
        // Already runs for cls, here or in a superclass. A second copy would look itself up and call itself.
        for (Class c = cls; c; c = class_getSuperclass(c)) if (c == hook.cls) return;
    }
    if (DPOriginalCount == 256) abort();
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
    DPOriginals[DPOriginalCount++] = (DPOriginal){cls, sel, replacement, original, name};
}

IMP DPOriginalIMP(id object, SEL sel, const char *name) {
    for (Class c = object_getClass(object); c; c = class_getSuperclass(c))
        for (int i = 0; i < DPOriginalCount; i++)
            if (DPOriginals[i].cls == c && DPOriginals[i].sel == sel && !strcmp(DPOriginals[i].name, name)) return DPOriginals[i].original;
    abort();
}
