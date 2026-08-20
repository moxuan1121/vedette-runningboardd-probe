export ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide
export DEBUG = 0
export FINALPACKAGE = 1
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = runningboardd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Vedette
Vedette_FILES = Vedette.xm VDTProcessManager.mm VDTShared.mm
Vedette_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += vedetteprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
