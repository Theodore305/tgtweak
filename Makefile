TARGET := iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Telegram

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TelegramCallTweak
TelegramCallTweak_FILES = Tweak.mm
TelegramCallTweak_FRAMEWORKS = UIKit AVFoundation CoreMedia
TelegramCallTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# the tweak doesn't use Substrate APIs: drop unused dylib dependencies so it injects cleanly via Sideloadly
TelegramCallTweak_LDFLAGS = -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk
