# xcui-http: drive any iOS app's UI over HTTP, through XCUITest.
#
#   make project   generate XCUIHTTP.xcodeproj (needs: brew install xcodegen)
#   make build     build the runner for the Simulator
#   make install   install the `xcui-http` CLI to $(PREFIX)/bin
#
# Then: xcui-http start --app <bundle id>  (xcui-http help for the rest)

PROJECT ?= XCUIHTTP.xcodeproj
DERIVED ?= build
PREFIX  ?= $(HOME)/.local

.PHONY: project build install clean distclean

project:
	xcodegen generate

build: project
	xcodebuild build-for-testing -project $(PROJECT) -scheme XCUIHTTP \
	  -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED) \
	  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES

# xcui-http finds project.yml through its build path, so keep this checkout where it is
# (or set XCUIHTTP_ROOT).
install:
	swift build -c release
	install -d $(PREFIX)/bin
	install .build/release/xcui-http $(PREFIX)/bin/xcui-http

clean:
	rm -rf $(DERIVED) .build

distclean: clean
	rm -rf $(PROJECT)
