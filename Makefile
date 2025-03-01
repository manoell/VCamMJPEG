TARGET := iphone:clang:14.5:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

TWEAK_NAME = VCamMJPEG

VCamMJPEG_FILES = Tweak.xm logger.m
VCamMJPEG_CFLAGS = -fobjc-arc
VCamMJPEG_FRAMEWORKS = UIKit AVFoundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
