.PHONY: install build test verify package release clean

install:
	npm ci
	python3 -m pip install -r requirements-dev.txt

build:
	npm run build

test: build
	npm test

verify: build
	npm run verify

package: build
	npm run package

release: build test verify package

clean:
	rm -rf dist/readable dist/minified
	rm -f dist/GPSQR-v*-SD-*.zip dist/SHA256SUMS
