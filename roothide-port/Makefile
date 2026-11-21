TARGET ?= iphone:clang:16.5:15.0
ARCHS ?= arm64 arm64e
FINALPACKAGE ?= 1
PACKAGE_VERSION ?= 0.2.2-rc.3+ios24.12+roothide1
THEOS_PACKAGE_SCHEME ?= roothide
THEOS_PLATFORM_DEB_COMPRESSION_TYPE ?= gzip
THEOS_LAYOUT_DIR ?= $(THEOS_PROJECT_DIR)/layout
# GNU dpkg writes all archive entries as root:wheel while preserving setuid bits.
# This avoids depending on host fakeroot metadata for privileged helpers.
_THEOS_PLATFORM_DPKG_DEB := $(CURDIR)/dpkg-root-owner

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
else
$(error roothide-port requires THEOS_PACKAGE_SCHEME=roothide)
endif

include $(THEOS)/makefiles/common.mk

TOOL_NAME = DSHNativeApp dsh-app-helper DSHLauncher node mcp-logreader
LIBRARY_NAME = dsh-ios-control dsh-ios-hud

CORE_DIR = $(THEOS_PROJECT_DIR)/../phone-bridge/native/core
NATIVE_UI_DIR = $(THEOS_PROJECT_DIR)/../app-bundle/native-ui
HELPER_DIR = $(THEOS_PROJECT_DIR)/../app-bundle/helper-src
LAUNCHER_DIR = $(THEOS_PROJECT_DIR)/../app-bundle/launcher-src
HUD_DIR = $(THEOS_PROJECT_DIR)/../phone-bridge/native/hud
LOGREADER_DIR = $(THEOS_PROJECT_DIR)/../phone-bridge/native/tools/mcp-logreader

# Standalone executable targets. The prepared payload supplies Info.plist/assets;
# Theos stages only these replacement Mach-O files at their final logical paths.
DSHNativeApp_FILES = $(NATIVE_UI_DIR)/DSHAppDelegate.m $(NATIVE_UI_DIR)/DSHRootVC.m $(NATIVE_UI_DIR)/DSHSettingsVC.m $(NATIVE_UI_DIR)/DSHWebVC.m $(NATIVE_UI_DIR)/DSHRHWebEndpoint.m $(NATIVE_UI_DIR)/main.m
DSHNativeApp_INSTALL_PATH = /Applications/DSH.app
DSHNativeApp_ARCHS = arm64
DSHNativeApp_FRAMEWORKS = UIKit Foundation WebKit SafariServices QuartzCore
DSHNativeApp_LDFLAGS += -lroothide
DSHNativeApp_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/DSHRH-App.entitlements.plist

DSHLauncher_FILES = $(LAUNCHER_DIR)/DSHLauncher.c
DSHLauncher_INSTALL_PATH = /Applications/DSH.app
DSHLauncher_ARCHS = arm64
DSHLauncher_LDFLAGS += -lroothide
DSHLauncher_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/DSHRH-Base.entitlements.plist

# setuid bit is applied by finalize_stage.py after staging; source accepts no args.
dsh-app-helper_FILES = $(HELPER_DIR)/dsh-app-helper.c
dsh-app-helper_INSTALL_PATH = /usr/bin
dsh-app-helper_ARCHS = arm64
dsh-app-helper_LDFLAGS += -lroothide
dsh-app-helper_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/DSHRH-Helper.entitlements.plist

# The original Node binary is kept as node-real by prepare_payload.py. This
# target is intentionally named node so its staged path replaces only the wrapper.
node_FILES = $(THEOS_PROJECT_DIR)/native/DSHRoothideNode.c
node_INSTALL_PATH = /usr/lib/dsh/bin
node_ARCHS = arm64
node_LDFLAGS += -lroothide
node_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/DSHRH-Base.entitlements.plist

mcp-logreader_FILES = $(LOGREADER_DIR)/main.m
mcp-logreader_INSTALL_PATH = /usr/bin
mcp-logreader_ARCHS = arm64
mcp-logreader_FRAMEWORKS = Foundation CoreFoundation
mcp-logreader_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/DSHRH-Logreader.entitlements.plist

# SpringBoard provider: both slices are required by the Roothide injector.
dsh-ios-control_FILES = $(wildcard $(CORE_DIR)/*.m)
dsh-ios-control_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
dsh-ios-control_FRAMEWORKS = UIKit Foundation IOKit CoreGraphics QuartzCore MobileCoreServices AVFoundation Security Vision
# Retain warnings for upstream legacy UIKit fallbacks and optional diagnostic
# helper functions. Other warnings/errors keep Theos's strict defaults.
dsh-ios-control_CFLAGS += -DMCP_ROOTHIDE=1 -iquote$(CORE_DIR) -Wno-error=deprecated-declarations -Wno-error=unused-function
dsh-ios-control_LDFLAGS += -lroothide

dsh-ios-hud_FILES = $(HUD_DIR)/HUDOverlay.m
dsh-ios-hud_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
dsh-ios-hud_FRAMEWORKS = UIKit Foundation QuartzCore
dsh-ios-hud_CFLAGS += -Wno-error=deprecated-declarations

ADDITIONAL_OBJCFLAGS += -fobjc-arc

# Theos package() rebuilds stage before running before-package. The finalizer
# depends on that stage target, so it runs only after layout and native files land.
ifneq ($(strip $(DSH_ROOTHIDE_STAGE_HOOK)),)
.PHONY: dsh-roothide-finalize-stage
dsh-roothide-finalize-stage: stage
	@$(DSH_ROOTHIDE_STAGE_HOOK) "$(THEOS_STAGING_DIR)"
before-package:: dsh-roothide-finalize-stage
endif

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/library.mk
