ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = 龙城军团 yougu3neigou

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LCJT
LCJT_FILES = LCJTTweak.x
LCJT_CFLAGS = -fobjc-arc -Wno-everything -Wno-unused-function
LCJT_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
LCJT_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
