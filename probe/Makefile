export ARCHS = arm64e
export THEOS_PACKAGE_SCHEME = roothide
export DEBUG = 0
export FINALPACKAGE = 1

TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = runningboardd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VedetteProbe
VedetteProbe_FILES = VedetteProbe.mm
VedetteProbe_CFLAGS = -fobjc-arc
VedetteProbe_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
