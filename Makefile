SHELL := /bin/bash

# We should probably do this the "Android way" (would also help with getting it on FDroid):
#  - https://developer.android.com/studio/projects/gradle-external-native-builds
#  - https://developer.android.com/ndk/guides/android_mk

RELEASE_TYPE = $(shell test -n "$$RELEASE" && $$RELEASE && echo 'release' || echo 'debug')
RELEASE_TYPE_UNSIGNED = $(shell test -n "$$RELEASE" && $$RELEASE && echo 'release-unsigned' || echo 'debug')
RELEASE_TYPE_CAPS = $(shell test -n "$$RELEASE" && $$RELEASE && echo 'Release' || echo 'Debug')
HAS_SECRETS = $(shell test -n "$$JKS_KEYPASS" && echo 'true' || echo 'false')

APKDIR = mobile/build/outputs/apk
AABDIR = mobile/build/outputs/bundle

WEBUI_SRCDIR := aw-server-rust/aw-webui
WEBUI_DISTDIR := $(WEBUI_SRCDIR)/dist

# NOTE: you have to download bundletool manually and set this path
#		https://github.com/google/bundletool/releases
BUNDLETOOL := java -jar ~/Downloads/bundletool-all-1.15.5.jar

# Main targets
all: aw-server-rust metadata
build: all
metadata: fastlane/metadata/android/en-US/images/icon.png

# builds an app bundle, puts it in dist
build-bundle: dist/aw-android.aab

# builds a complete, signed apk, puts it in dist
build-apk: dist/aw-android.apk

# Attempts at working with bundletool to build device-specific APKs
# See: https://github.com/ActivityWatch/aw-android/issues/61
dist/aw-android.apks:
	rm -rf dist/aw-android.apks
	$(BUNDLETOOL) \
		build-apks --bundle=dist/aw-android.aab --output=dist/aw-android.apks

# Extracts device-specific APKs from the apks bundle
build-device-specific-apks:
	# TODO: add arm(7), x86, x86_64
	$(BUNDLETOOL) \
		extract-apks \
		--apks=dist/aw-android.apks \
		--output-dir=dist/splits/arm64 \
		--device-spec=scripts/device-arm64.json

# Useful for inspecting the contents of the apks
unzip-apks: dist/aw-android.apks
	rm -rf dist/apks
	unzip -o dist/aw-android.apks -d dist/apks

# builds debug and test apks (unsigned)
build-apk-debug: $(APKDIR)/debug/mobile-debug.apk $(APKDIR)/androidTest/debug/mobile-debug-androidTest.apk
	mkdir -p dist
	cp -r $(APKDIR) dist

# Test targets
test: test-unit

test-unit:
	./gradlew test

test-e2e:
	./gradlew connectedAndroidTest --stacktrace

test-e2e-screenshot-only:
	@# To only run screenshot test:
	./gradlew connectedAndroidTest \
		-Pandroid.testInstrumentationRunnerArguments.class=net.activitywatch.android.ScreenshotTest

test-e2e-adb:
	@# Requires that you have a device connected with the necessary APKs installed
	@# Alternative to using gradle, if you don't want to rebuild.
	@#
	@# To list instrumentation tests, run:
	@# adb shell pm list instrumentation
	@#
	@# Run only screenshot test, for now
	adb shell am instrument -w \
		-e class net.activitywatch.android.ScreenshotTest
		net.activitywatch.android.debug.test/androidx.test.runner.AndroidJUnitRunner

install-apk-debug: $(APKDIR)/debug/mobile-debug.apk
	adb install $(APKDIR)/debug/mobile-debug.apk
	adb install $(APKDIR)/debug/mobile-debug-androidTest.apk

# APK targets
$(APKDIR)/$(RELEASE_TYPE)/mobile-$(RELEASE_TYPE_UNSIGNED).apk:
	TERM=xterm ./gradlew assemble$(RELEASE_TYPE_CAPS)
	tree $(APKDIR)

$(APKDIR)/androidTest/$(RELEASE_TYPE)/mobile-$(RELEASE_TYPE)-androidTest.apk:
	TERM=xterm ./gradlew assembleAndroidTest
	tree $(APKDIR)

# App bundle targets
$(AABDIR)/$(RELEASE_TYPE)/mobile-$(RELEASE_TYPE).aab:
	TERM=xterm ./gradlew bundle$(RELEASE_TYPE_CAPS)
	tree $(AABDIR)

# Signed release bundle
dist/aw-android.aab: $(AABDIR)/$(RELEASE_TYPE)/mobile-$(RELEASE_TYPE).aab
	mkdir -p dist
	@# Only sign if we have key secrets set ($JKS_KEYPASS and $JKS_STOREPASS)
ifneq ($(HAS_SECRETS), true)
	@echo "No key secrets set, not signing"
	cp $< $@
else
	./scripts/sign_apk.sh $< $@
endif

# Signed release APK
dist/aw-android.apk: $(APKDIR)/$(RELEASE_TYPE)/mobile-$(RELEASE_TYPE_UNSIGNED).apk
	mkdir -p dist
	@# Only sign if we have key secrets set ($JKS_KEYPASS and $JKS_STOREPASS)
ifneq ($(HAS_SECRETS), true)
	@echo "No key secrets set, not signing"
	cp $< $@
else
	./scripts/sign_apk.sh $< $@
endif

# for mobile-debug.apk and mobile-debug-androidTest.apk
dist/$(RELEASE_TYPE)/%: $(APKDIR)/$(RELEASE_TYPE)/%
	mkdir -p dist
	cp $< $@

# All native entry points use the Gradle packaging build, including SQLCipher/E2EE.
export ON_ANDROID := -- --android
.PHONY: aw-server-rust
aw-server-rust: $(WEBUI_DISTDIR)
	./gradlew :mobile:buildRust $(GRADLE_ARGS)

# aw-webui
.PHONY: $(WEBUI_DISTDIR)
$(WEBUI_DISTDIR):
	# Ideally this sub-Makefile should not rebuild unless files have changed
	# Don't run if SKIP_WEBUI is set
	if [ "$$SKIP_WEBUI" == "true" ]; then \
		echo "Skipping aw-webui build, as SKIP_WEBUI is set"; \
	else \
		echo "Building aw-webui"; \
		make --directory=aw-server-rust/aw-webui build; \
	fi

clean:
	rm -rf mobile/src/main/assets/webui
	rm -rf mobile/src/main/jniLibs

.PHONY: fastlane/metadata/android/en-US/images/icon.png
fastlane/metadata/android/en-US/images/icon.png: aw-server-rust/aw-webui/static/peakactivity.svg
	magick $< -resize 75% -gravity center -background white -extent 512x512 $@
