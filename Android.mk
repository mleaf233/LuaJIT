LOCAL_PATH:= $(call my-dir)

# libluajit.a 由 build_android.ps1 生成，已把 module/lovely 的 Rust 目标文件合并进去，
# 所以 ljamalg.o 引用的 lovely_init / lovely_apply_patches 在同一个归档内即可解析，
# 不需要额外的 liblovely 静态库，也就不存在两个静态库互相引用的顺序问题。
include $(CLEAR_VARS)
LOCAL_MODULE := libluajit
LOCAL_SRC_FILES := android/$(TARGET_ARCH_ABI)/libluajit.a
LOCAL_EXPORT_C_INCLUDES := ${LOCAL_PATH}/src ${LOCAL_PATH}/android/$(TARGET_ARCH_ABI)
include $(PREBUILT_STATIC_LIBRARY)
